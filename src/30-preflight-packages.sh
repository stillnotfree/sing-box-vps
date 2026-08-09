show_plan() {
  local plan_admin="${ADMIN_USER:-<interactive>}"
  local plan_ip="${SERVER_IPV4:-<interactive>}"
  local plan_domain="${TLS_DOMAIN:-<interactive>}"
  local plan_target="${REALITY_TARGET:-<explicit choice required>}"
  local plan_emoji="${COUNTRY_EMOJI:-<interactive>}"
  local plan_fingerprint="${CLIENT_FINGERPRINT:-$DEFAULT_CLIENT_FINGERPRINT}"
  local plan_hy2_obfs="${HY2_OBFS_MODE:-$DEFAULT_HY2_OBFS_MODE}"
  local plan_ssh_port="${SSH_PORT:-22}"
  print_title "VPN installer ${SCRIPT_VERSION}"
  cat <<EOF
  System       Debian 13 / Ubuntu 24.04 or 26.04, amd64
  Server       ${plan_ip}
  Admin        ${plan_admin}
  SSH          TCP/${plan_ssh_port}, key-only after first admin login
  Core         latest supported sing-box (${SING_BOX_MIN_VERSION} <= version < ${SING_BOX_MAX_EXCLUSIVE})
  Protocols    VLESS + REALITY + Vision (TCP/443)
               Hysteria2 + TLS (UDP/443, obfs: ${plan_hy2_obfs})
  TLS domain   ${plan_domain}
  REALITY      ${plan_target}
  Fingerprint  ${plan_fingerprint}
  Labels       ${plan_emoji} Reality / ${plan_emoji} Hysteria2
  Subscription private HTTPS URL per client on TCP/${SUBSCRIPTION_PORT}
  Security     nftables, SSH hardening, automatic security updates
  Tuning       BBR + fq when supported, conservative QUIC buffers

The installer validates the host, DNS, target, ports, certificates and
generated configuration. Existing valid state is reused on a repeated run.
No web panel, Docker, telemetry, statistics or access logging is installed.
EOF
}

preflight_os() {
  [[ -r /etc/os-release ]] || die '/etc/os-release is missing.'
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
  case "${OS_ID}:${OS_VERSION}" in
    debian:13|ubuntu:24.04|ubuntu:26.04)
      ;;
    *)
      die "Unsupported operating system: ${OS_PRETTY_NAME}. Supported: Debian 13, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS."
      ;;
  esac
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die 'This installer supports only the amd64 package architecture.'
  [[ "$(uname -m)" == "x86_64" ]] || die 'Unexpected kernel architecture; expected x86_64.'
  log "Operating system compatibility: ${OS_PRETTY_NAME} / amd64."
}

preflight_hardware_and_runtime() {
  local mem_kib min_mem_kib min_mem_label cpu_count virtualization pid_one
  local epoch ntp_state boot_uptime

  [[ -r /proc/1/comm ]] || die 'Unable to inspect the init process through /proc/1/comm.'
  pid_one="$(</proc/1/comm)"
  pid_one="${pid_one//[[:space:]]/}"
  [[ "$pid_one" == "systemd" && -d /run/systemd/system ]] || \
    die 'A real systemd boot is required; containers without systemd and WSL are unsupported.'

  mem_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine installed memory.'
  # Providers commonly market a VM as 1 GB while the guest sees slightly less
  # after firmware and hypervisor reservations. Keep the public requirement at
  # 1 GB without rejecting a normal 1 GB plan for a small reporting difference.
  min_mem_kib=921600
  min_mem_label='900 MiB visible (a 1 GB VPS plan)'
  (( mem_kib >= min_mem_kib )) || \
    die "Insufficient RAM for ${OS_PRETTY_NAME}: found $((mem_kib / 1024)) MiB, require at least ${min_mem_label}."

  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    die 'No online CPU was detected.'
  fi
  [[ -r /proc/sys/kernel/random/uuid ]] || die 'Kernel UUID entropy source is unavailable.'
  [[ -w /etc && -w /var && -w /tmp ]] || die 'The installer requires writable /etc, /var, and /tmp filesystems.'

  epoch="$(date +%s 2>/dev/null || true)"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]] || (( epoch < 1704067200 || epoch > 4102444800 )); then
    die 'System clock is implausible; correct date/time before TLS and ACME operations.'
  fi
  ntp_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$ntp_state" != "yes" ]]; then
    boot_uptime="$(cut -d ' ' -f 1 /proc/uptime 2>/dev/null || true)"
    boot_uptime="${boot_uptime%%.*}"
    if [[ "$boot_uptime" =~ ^[0-9]+$ ]] && (( boot_uptime < NTP_BOOT_GRACE_SECONDS )); then
      log 'NTP synchronization is still pending during the initial boot grace period.'
    else
      warn 'System clock is not currently reported as NTP-synchronized.'
    fi
  fi

  virtualization="$(systemd-detect-virt 2>/dev/null || true)"
  virtualization="${virtualization:-none}"
  log "Runtime compatibility: CPU=${cpu_count}, RAM=$((mem_kib / 1024)) MiB, kernel=$(uname -r), virtualization=${virtualization}, systemd=yes."
}

preflight_public_ip() {
  local addresses
  addresses="$(ip -4 address show)"
  if grep -Fq "${SERVER_IPV4}/" <<<"$addresses"; then
    log "Configured public IPv4 ${SERVER_IPV4} is present on a local interface."
  else
    warn "IPv4 ${SERVER_IPV4} is not present on a local interface; continuing for a possible provider-managed 1:1 NAT setup. DNS and ACME validation must still reach this VPS."
  fi
}

port_is_listening() {
  local protocol="$1"
  local port="$2"
  if [[ "$protocol" == "tcp" ]]; then
    ss -H -lntp | awk -v port="$port" '$4 ~ (":" port "$") { print }'
  else
    ss -H -lnup | awk -v port="$port" '$4 ~ (":" port "$") { print }'
  fi
}

preflight_ports() {
  local listeners
  listeners="$(port_is_listening tcp 443 || true)"
  if [[ -n "$listeners" && "$listeners" != *sing-box* ]]; then
    printf '%s\n' "$listeners" >&2
    die 'TCP/443 is already occupied by another process.'
  fi

  listeners="$(port_is_listening udp 443 || true)"
  if [[ -n "$listeners" && "$listeners" != *sing-box* ]]; then
    printf '%s\n' "$listeners" >&2
    die 'UDP/443 is already occupied by another process.'
  fi

  listeners="$(port_is_listening tcp "$SUBSCRIPTION_PORT" || true)"
  if [[ -n "$listeners" && ( "$listeners" != *nginx* || ! -f "$NGINX_SITE" ) ]]; then
    printf '%s\n' "$listeners" >&2
    die "TCP/${SUBSCRIPTION_PORT} is occupied by an unmanaged process."
  fi
}

preflight_disk() {
  local available_kib total_kib
  available_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  total_kib="$(df -Pk / | awk 'NR==2 {print $2}')"
  [[ "$available_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine free disk space.'
  [[ "$total_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine root filesystem size.'
  (( available_kib >= 2500000 )) || die 'At least 2.5 GiB of free disk space is required.'
  log "Storage compatibility: root filesystem total=$((total_kib / 1024)) MiB, free=$((available_kib / 1024)) MiB."
}

compatibility_check() {
  require_root
  CURRENT_STEP='read-only compatibility check'
  require_command dpkg
  require_command ss
  require_command systemctl
  require_command systemd-detect-virt
  require_command timedatectl

  preflight_os
  preflight_hardware_and_runtime
  preflight_disk
  preflight_ports

  printf '\nCompatibility check: PASS\n'
  printf 'Supported host: %s / amd64\n' "$OS_PRETTY_NAME"
  printf 'TCP/443 and UDP/443: available or already owned by sing-box\n'
  printf 'TCP/%s: available or already owned by nginx\n' "$SUBSCRIPTION_PORT"
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
     grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    printf 'BBR: available\n'
  else
    printf 'BBR: not currently available (optional; installation can use the kernel default)\n'
  fi
  printf 'No packages, services, accounts, firewall rules, or configuration files were changed.\n'
}

preflight_key() {
  local key_file
  while true; do
    key_file="$(mktemp)"
    printf '%s\n' "$ADMIN_PUBLIC_KEY" >"$key_file"
    if ssh-keygen -l -f "$key_file" >/dev/null 2>&1; then
      rm -f -- "$key_file"
      return
    fi
    rm -f -- "$key_file"
    if ! interactive_stdin; then
      die 'The supplied admin public key is invalid.'
    fi
    warn 'The supplied OpenSSH public key is invalid. Paste the complete public-key line again.'
    ADMIN_PUBLIC_KEY=""
    prompt_value ADMIN_PUBLIC_KEY '[Step 2 / 10] OpenSSH public key (one line)' '' public_key_text_is_valid
  done
}

install_base_packages() {
  log 'Refreshing Debian package metadata.'
  apt-get update
  log 'Installing the reviewed dependency set.'
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${BASE_PACKAGES[@]}"
  # Debian/Ubuntu may start the packaged default HTTP site immediately. Keep
  # nginx stopped until the certificate and restricted subscription site exist.
  systemctl disable --now nginx.service >/dev/null 2>&1 || true
}

configure_sing_box_repository() {
  local key_candidate source_candidate
  install -d -o root -g root -m 0755 /etc/apt/keyrings
  key_candidate="$(mktemp)"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 3 --connect-timeout 20 --output "$key_candidate" "$SAGERNET_KEY_URL"
  grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$key_candidate" || die 'The SagerNet repository key is malformed.'
  gpg --batch --show-keys "$key_candidate" >/dev/null 2>&1 || \
    die 'The SagerNet repository key is not a valid OpenPGP public key.'
  write_atomic "$SAGERNET_KEY_FILE" root root 0644 "$key_candidate"
  rm -f -- "$key_candidate"

  source_candidate="$(mktemp)"
  cat >"$source_candidate" <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: ${SAGERNET_KEY_FILE}
EOF
  write_atomic "$SAGERNET_SOURCE_FILE" root root 0644 "$source_candidate"
  rm -f -- "$source_candidate"
}

sing_box_candidate_version() {
  # Consume the complete apt-cache stream. With pipefail enabled, exiting awk
  # after the first match can send SIGPIPE to apt-cache and turn a successful
  # lookup into exit status 141 on hosts with a sufficiently large policy list.
  apt-cache policy sing-box | awk '
    /^[[:space:]]*Candidate:/ && !found {
      candidate=$2
      found=1
    }
    END {
      if (found) print candidate
    }
  '
}

cleanup_apt_download_dir() {
  [[ -n "$APT_DOWNLOAD_DIR" ]] || return 0
  case "$APT_DOWNLOAD_DIR" in
    "${APT_DOWNLOAD_ROOT}"/download.*)
      rm -rf -- "$APT_DOWNLOAD_DIR"
      ;;
    *)
      warn "Refusing to remove unexpected APT download directory: ${APT_DOWNLOAD_DIR}"
      ;;
  esac
  APT_DOWNLOAD_DIR=""
}

prepare_apt_download_dir() {
  id _apt >/dev/null 2>&1 || die 'The required APT sandbox account _apt is unavailable.'
  cleanup_apt_download_dir
  # The parent is traversable but not listable. Each unpredictable child is
  # private to _apt, so apt-get can retain its sandbox without a 0777 staging
  # directory or an unsandboxed-root fallback.
  install -d -o root -g root -m 0711 "$APT_DOWNLOAD_ROOT"
  APT_DOWNLOAD_DIR="$(mktemp -d "${APT_DOWNLOAD_ROOT}/download.XXXXXX")"
  chown _apt:root "$APT_DOWNLOAD_DIR"
  chmod 0700 "$APT_DOWNLOAD_DIR"
}

download_sing_box_package() {
  local version="$1" output_variable="$2" package
  prepare_apt_download_dir
  (
    cd "$APT_DOWNLOAD_DIR"
    apt-get download "sing-box=${version}" >/dev/null
  )
  package="$(find "$APT_DOWNLOAD_DIR" -maxdepth 1 -type f -name 'sing-box_*.deb' -print -quit)"
  [[ -n "$package" ]] || die "Could not download sing-box ${version}."
  chown root:root "$package"
  chmod 0600 "$package"
  [[ "$(dpkg-deb -f "$package" Package)" == "sing-box" ]] || die 'Downloaded package name is not sing-box.'
  [[ "$(dpkg-deb -f "$package" Version)" == "$version" ]] || die 'Downloaded sing-box version does not match APT metadata.'
  printf -v "$output_variable" '%s' "$package"
}

archive_sing_box_package() {
  local package="$1" version architecture destination
  version="$(dpkg-deb -f "$package" Version)"
  architecture="$(dpkg-deb -f "$package" Architecture)"
  install -d -o root -g root -m 0700 "$PACKAGE_CACHE_DIR"
  destination="${PACKAGE_CACHE_DIR}/sing-box_${version}_${architecture}.deb"
  install -o root -g root -m 0600 "$package" "${destination}.new"
  mv -f -- "${destination}.new" "$destination"
  printf '%s\n' "$destination"
}

find_cached_sing_box_package() {
  local version="$1" package
  while IFS= read -r -d '' package; do
    if [[ "$(dpkg-deb -f "$package" Version 2>/dev/null || true)" == "$version" ]]; then
      printf '%s\n' "$package"
      return 0
    fi
  done < <(find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name 'sing-box_*.deb' -print0 2>/dev/null)
  return 1
}

prune_sing_box_packages() {
  local -a packages=()
  local index package
  while IFS= read -r package; do
    packages+=("$package")
  done < <(find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name 'sing-box_*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  for (( index=2; index<${#packages[@]}; index++ )); do
    rm -f -- "${packages[$index]}"
  done
}

install_sing_box() {
  local candidate package_path installed_version
  configure_sing_box_repository
  apt-get update
  candidate="$(sing_box_candidate_version)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die 'No stable sing-box candidate is available from the official repository.'
  require_supported_sing_box_version "$candidate"

  installed_version="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  if [[ "$installed_version" == "$candidate" ]]; then
    require_supported_sing_box_version "$installed_version"
    if ! find_cached_sing_box_package "$installed_version" >/dev/null; then
      download_sing_box_package "$candidate" package_path
      archive_sing_box_package "$package_path" >/dev/null
      cleanup_apt_download_dir
    fi
    apt-mark hold sing-box >/dev/null
    log "Verified existing stable sing-box ${installed_version}; reusing it."
    return
  fi

  download_sing_box_package "$candidate" package_path
  package_path="$(archive_sing_box_package "$package_path")"
  cleanup_apt_download_dir

  apt-mark unhold sing-box >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages \
    "sing-box=${candidate}"
  installed_version="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  [[ "$installed_version" == "$candidate" ]] || die "Unexpected installed sing-box version: ${installed_version:-missing}"
  apt-mark hold sing-box >/dev/null
  log "Installed and held stable sing-box ${installed_version}; use 'vpn update' for reviewed updates."
}
