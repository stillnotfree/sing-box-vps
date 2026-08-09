path_has_symlink_component() {
  local path="$1" current="/" component
  local -a components=()
  [[ "$path" == /* ]] || return 0
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current%/}/${component}"
    [[ -L "$current" ]] && return 0
  done
  return 1
}

create_admin_account() {
  local user_home user_shell primary_group sudoers_stage account_password
  local authorized_keys group_list created_account=0

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    log "Creating administrative user ${ADMIN_USER}."
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
    created_account=1
  else
    log "Administrative user ${ADMIN_USER} already exists; validating and reusing it."
  fi

  user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  user_shell="$(getent passwd "$ADMIN_USER" | cut -d: -f7)"
  [[ -n "$user_home" && -d "$user_home" ]] || die "Home directory for ${ADMIN_USER} is unavailable."
  path_has_symlink_component "$user_home" && \
    die "Home path for ${ADMIN_USER} contains a symbolic link: ${user_home}"
  [[ "$user_shell" != */nologin && "$user_shell" != */false ]] || \
    die "Existing account ${ADMIN_USER} has a non-login shell (${user_shell})."
  primary_group="$(id -gn "$ADMIN_USER")"
  [[ -n "$primary_group" ]] || die "Primary group for ${ADMIN_USER} is unavailable."

  group_list="$(id -nG "$ADMIN_USER" | tr ' ' '\n')"
  if ! grep -Fxq sudo <<<"$group_list"; then
    usermod --append --groups sudo "$ADMIN_USER"
  fi

  [[ ! -L "${user_home}/.ssh" ]] || die "${user_home}/.ssh must not be a symbolic link."
  install -d -o "$ADMIN_USER" -g "$primary_group" -m 0700 "${user_home}/.ssh"
  path_has_symlink_component "${user_home}/.ssh" && \
    die "${user_home}/.ssh contains a symbolic-link path component."
  authorized_keys="${user_home}/.ssh/authorized_keys"
  [[ ! -L "$authorized_keys" ]] || die "${authorized_keys} must not be a symbolic link."
  [[ ! -L "${authorized_keys}.new" ]] || die "${authorized_keys}.new must not be a symbolic link."
  [[ ! -e "$authorized_keys" || -f "$authorized_keys" ]] || \
    die "${authorized_keys} exists but is not a regular file."
  if [[ -f "$authorized_keys" ]]; then
    install -o "$ADMIN_USER" -g "$primary_group" -m 0600 \
      "$authorized_keys" "${authorized_keys}.new"
  else
    install -o "$ADMIN_USER" -g "$primary_group" -m 0600 /dev/null "${authorized_keys}.new"
  fi
  if ! grep -Fxq -- "$ADMIN_PUBLIC_KEY" "${authorized_keys}.new"; then
    printf '%s\n' "$ADMIN_PUBLIC_KEY" >>"${authorized_keys}.new"
  fi
  mv -f -- "${authorized_keys}.new" "$authorized_keys"

  sudoers_stage="$(mktemp)"
  printf '%s\n' "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" >"$sudoers_stage"
  chmod 0440 "$sudoers_stage"
  visudo -cf "$sudoers_stage" >/dev/null
  if [[ -e "/etc/sudoers.d/90-${ADMIN_USER}" ]]; then
    visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}" >/dev/null || \
      die "Existing sudoers file for ${ADMIN_USER} is invalid."
    cmp -s "$sudoers_stage" "/etc/sudoers.d/90-${ADMIN_USER}" || \
      die "Existing sudoers file /etc/sudoers.d/90-${ADMIN_USER} conflicts with this installer."
  else
    install -o root -g root -m 0440 "$sudoers_stage" "/etc/sudoers.d/90-${ADMIN_USER}"
  fi
  rm -f -- "$sudoers_stage"
  sudo -u "$ADMIN_USER" sudo -n /bin/true || \
    die "Passwordless sudo validation failed for ${ADMIN_USER}; automatic first-login finalization would not be reliable."

  if (( created_account == 1 )); then
    # Keep the PAM account usable for public-key SSH while making its password
    # unknown and computationally infeasible to guess. The value is never logged
    # or stored outside /etc/shadow and global SSH password auth is disabled later.
    account_password="$(openssl rand -base64 48)"
    printf '%s:%s\n' "$ADMIN_USER" "$account_password" | chpasswd
    unset account_password
    log "Installed public-key account ${ADMIN_USER}; no usable password was disclosed."
  else
    log "Verified administrative account ${ADMIN_USER}; its existing password state was not changed."
  fi
}

configure_swap() {
  local swap_type created_swap=0 staged_swap="/swapfile.new"
  if [[ -n "$(swapon --noheadings --show=NAME 2>/dev/null)" ]]; then
    log 'Swap already exists; leaving it unchanged.'
    return
  fi

  if [[ ! -e /swapfile ]]; then
    log 'Creating a 1 GiB swap file.'
    rm -f -- "$staged_swap"
    if ! fallocate -l 1G "$staged_swap"; then
      rm -f -- "$staged_swap"
      dd if=/dev/zero of="$staged_swap" bs=1M count=1024 status=progress
    fi
    chmod 0600 "$staged_swap"
    if ! mkswap "$staged_swap" >/dev/null; then
      rm -f -- "$staged_swap"
      warn 'Could not format the optional swap file; continuing without swap.'
      return
    fi
    mv -f -- "$staged_swap" /swapfile
    created_swap=1
  else
    [[ -f /swapfile ]] || die '/swapfile exists but is not a regular file.'
    swap_type="$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)"
    [[ "$swap_type" == "swap" ]] || die '/swapfile already exists and is not a recognized swap file.'
  fi
  chmod 0600 /swapfile
  if ! swapon /swapfile; then
    if (( created_swap == 1 )); then
      rm -f -- /swapfile
    fi
    warn 'Could not activate the optional swap file; continuing without swap. Some COW filesystems and VPS kernels do not support ordinary swap files.'
    return
  fi
  grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || \
    printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
}

configure_bbr_if_available() {
  local available modules_candidate sysctl_candidate
  if ! modprobe tcp_bbr 2>/dev/null; then
    warn 'tcp_bbr module is unavailable; retaining CUBIC + fq_codel.'
    return
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    warn 'Kernel did not expose BBR after module load; retaining existing congestion control.'
    return
  fi

  log 'Enabling BBR and making fq the default qdisc for new/recreated interfaces.'
  modules_candidate="$(mktemp)"
  printf '%s\n' 'tcp_bbr' >"$modules_candidate"
  write_atomic /etc/modules-load.d/90-vpn-bbr.conf root root 0644 "$modules_candidate"
  rm -f -- "$modules_candidate"

  sysctl_candidate="$(mktemp)"
  cat >"$sysctl_candidate" <<'EOF'
# VPN setup: only the reviewed TCP settings. No buffer or MTU tuning.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  write_atomic /etc/sysctl.d/90-vpn-network.conf root root 0644 "$sysctl_candidate"
  rm -f -- "$sysctl_candidate"
  sysctl -p /etc/sysctl.d/90-vpn-network.conf >/dev/null
}

configure_udp_buffer_ceilings() {
  local current_rmem current_wmem desired_rmem desired_wmem candidate
  current_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || true)"
  current_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || true)"
  [[ "$current_rmem" =~ ^[0-9]+$ && "$current_wmem" =~ ^[0-9]+$ ]] || \
    die 'Unable to read the current UDP socket-buffer ceilings.'

  desired_rmem="$current_rmem"
  desired_wmem="$current_wmem"
  (( desired_rmem >= UDP_BUFFER_MAX )) || desired_rmem="$UDP_BUFFER_MAX"
  (( desired_wmem >= UDP_BUFFER_MAX )) || desired_wmem="$UDP_BUFFER_MAX"

  candidate="$(mktemp)"
  cat >"$candidate" <<EOF
# VPN setup: conservative QUIC/Hysteria2 socket-buffer ceilings.
# These are maximums, not preallocated memory; higher existing values are preserved.
net.core.rmem_max = ${desired_rmem}
net.core.wmem_max = ${desired_wmem}
EOF
  write_atomic "$UDP_SYSCTL_FILE" root root 0644 "$candidate"
  sysctl -p "$UDP_SYSCTL_FILE" >/dev/null
  if (( current_rmem < UDP_BUFFER_MAX || current_wmem < UDP_BUFFER_MAX )); then
    log "Raised lower UDP socket-buffer ceilings to ${UDP_BUFFER_MAX} bytes without reducing higher values."
  else
    log "Existing UDP socket-buffer ceilings already meet or exceed ${UDP_BUFFER_MAX} bytes; persisted them unchanged."
  fi
  rm -f -- "$candidate"
}

configure_journal_limits() {
  local candidate
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=30day
EOF
  install -d -o root -g root -m 0755 "$JOURNAL_DROPIN_DIR"
  write_atomic "$JOURNAL_DROPIN" root root 0644 "$candidate"
  rm -f -- "$candidate"
  systemctl restart systemd-journald.service
  systemctl is-active --quiet systemd-journald.service || die 'systemd-journald did not become active after applying limits.'
  log 'Limited persistent journal storage to 200 MiB with a 30-day retention ceiling.'
}

configure_unattended_upgrades() {
  local candidate
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
// VPN setup: security updates without automatic reboot.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  write_atomic /etc/apt/apt.conf.d/52-vpn-unattended-upgrades root root 0644 "$candidate"
  rm -f -- "$candidate"
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
}

verify_dns() {
  local resolver answer caa_status caa_output
  for resolver in 1.1.1.1 8.8.8.8; do
    answer="$(dig +short A "$TLS_DOMAIN" "@${resolver}" | sed '/^$/d')"
    if ! grep -Fxq "$SERVER_IPV4" <<<"$answer"; then
      printf 'Resolver %s returned:\n%s\n' "$resolver" "${answer:-<no A record>}" >&2
      die "${TLS_DOMAIN} must resolve directly to ${SERVER_IPV4} before installation; disable DNS-provider/CDN proxying for this record."
    fi

    caa_output="$(dig CAA "$TLS_DOMAIN" "@${resolver}" +noall +comments 2>&1 || true)"
    caa_status="$(awk '
      !found && match($0, /status: [A-Z]+,/) {
        value=substr($0, RSTART + 8, RLENGTH - 9)
        found=1
      }
      END { if (found) print value }
    ' <<<"$caa_output")"
    if [[ "$caa_status" != "NOERROR" ]]; then
      printf 'Resolver %s returned CAA status %s:\n%s\n' \
        "$resolver" "${caa_status:-unknown}" "$caa_output" >&2
      die "CAA lookup for ${TLS_DOMAIN} is unhealthy; fix DNS before requesting a certificate."
    fi
  done
  log "DNS A and CAA responses for ${TLS_DOMAIN} are healthy on both public resolvers."
}

verify_reality_target() {
  local tls_probe
  log "Checking TLS 1.3 reachability of the reviewed REALITY target ${REALITY_TARGET}."
  if ! tls_probe="$(timeout 15 openssl s_client \
    -connect "${REALITY_TARGET}:443" \
    -servername "$REALITY_TARGET" \
    -tls1_3 -alpn h2 -verify_return_error </dev/null 2>&1)"; then
    die "REALITY target ${REALITY_TARGET} did not pass the TLS 1.3 verification test."
  fi
  if ! grep -Eiq 'ALPN protocol:[[:space:]]*h2|ALPN[^[:alnum:]]+h2' <<<"$tls_probe"; then
    die "REALITY target ${REALITY_TARGET} did not negotiate HTTP/2 (ALPN h2)."
  fi
  log "REALITY target ${REALITY_TARGET} passed the basic certificate, TLS 1.3, and ALPN h2 checks."
}

capture_reality_target_audit_probe() {
  local target="$1" output status=0
  if output="$(timeout 12 openssl s_client \
    -connect "${target}:443" \
    -servername "$target" \
    -tls1_3 -alpn h2 -verify_return_error -msg -ign_eof \
    <<< $'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n' 2>&1)"; then
    :
  else
    status=$?
    if (( status != 124 )); then
      printf '%s\n' "$output" >&2
      return "$status"
    fi
  fi
  printf '%s\n' "$output"
}

audit_reality_target() {
  local target="${AUDIT_TARGET:-$REALITY_TARGET}" tls_probe ticket_count
  require_command openssl
  require_command timeout
  validate_domain "$target"

  log "Auditing REALITY target ${target} for post-handshake TLS 1.3 session tickets."
  if ! tls_probe="$(capture_reality_target_audit_probe "$target")"; then
    warn "REALITY target ${target} did not complete the audit TLS 1.3 probe."
    return 2
  fi
  if ! grep -Eiq 'ALPN protocol:[[:space:]]*h2|ALPN[^[:alnum:]]+h2' <<<"$tls_probe"; then
    warn "REALITY target ${target} did not negotiate HTTP/2 (ALPN h2)."
    return 2
  fi

  ticket_count="$(grep -Ec 'NewSessionTicket' <<<"$tls_probe" || true)"
  print_title 'REALITY target audit'
  printf 'Target: %s\n' "$target"
  printf 'TLS 1.3 certificate and ALPN h2: PASS\n'
  printf 'Post-handshake NewSessionTicket messages: %s\n' "$ticket_count"
  if (( ticket_count == 0 )); then
    printf 'Aparecium-class comparison signal: NOT OBSERVED\n'
    printf 'This lowers exposure to this specific active-probing method; it is not a general undetectability guarantee.\n'
    return
  fi

  printf 'Aparecium-class comparison signal: OBSERVED\n'
  warn 'This target exposes a post-handshake comparison signal that can make REALITY easier to distinguish during active probing.'
  printf 'Prefer a reviewed TLS 1.3/h2 target with no observed post-handshake tickets.\n'
  return 1
}

select_audited_reality_target_for_install() {
  local audit_status answer
  while true; do
    AUDIT_TARGET="$REALITY_TARGET"
    if audit_reality_target; then
      AUDIT_TARGET=""
      REALITY_TARGET_AUDITED=1
      return
    else
      audit_status=$?
    fi
    AUDIT_TARGET=""

    if (( ASSUME_YES == 1 )) || ! interactive_stdin; then
      if (( audit_status == 1 )); then
        die "REALITY target ${REALITY_TARGET} exposes the audited post-handshake comparison signal; rerun with a different --reality-target."
      fi
      die "REALITY target ${REALITY_TARGET} could not pass the TLS 1.3/h2 audit; rerun with a different --reality-target."
    fi

    if (( audit_status == 1 )); then
      printf 'The target is technically usable, but the audit found a post-handshake comparison signal.\n'
      printf 'Keep %s anyway, or choose another target now.\n' "$REALITY_TARGET"
      while true; do
        read -r -p 'Keep this target? [Y/n]: ' answer
        answer="${answer:-y}"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
          y|yes|keep)
            log "Keeping explicitly accepted REALITY target ${REALITY_TARGET} despite the audit warning."
            REALITY_TARGET_AUDITED=1
            return
            ;;
          n|no|new)
            REALITY_TARGET=""
            prompt_value REALITY_TARGET 'Replacement REALITY target' '' domain_is_valid
            break
            ;;
          *)
            warn 'Answer yes to keep this target or no to enter another one.'
            ;;
        esac
      done
    else
      warn "Choose another REALITY target; ${REALITY_TARGET} did not pass the TLS 1.3/h2 requirements."
      REALITY_TARGET=""
      prompt_value REALITY_TARGET 'Replacement REALITY target' '' domain_is_valid
    fi
  done
}

deploy_certificate() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]] || die 'Certificate files are unavailable.'
  install -d -o root -g sing-box -m 0750 "$CERT_DIR"
  install -o root -g sing-box -m 0640 "${live_dir}/fullchain.pem" "${CERT_DIR}/fullchain.pem.new"
  install -o root -g sing-box -m 0640 "${live_dir}/privkey.pem" "${CERT_DIR}/privkey.pem.new"
  mv -f -- "${CERT_DIR}/fullchain.pem.new" "${CERT_DIR}/fullchain.pem"
  mv -f -- "${CERT_DIR}/privkey.pem.new" "${CERT_DIR}/privkey.pem"
}

certificate_key_pair_matches() {
  local certificate="$1" private_key="$2" work
  [[ -r "$certificate" && -r "$private_key" ]] || return 1
  work="$(mktemp -d)"
  if ! openssl x509 -in "$certificate" -pubkey -noout >"${work}/certificate.pub" 2>/dev/null ||
     ! openssl pkey -pubin -in "${work}/certificate.pub" -outform DER >"${work}/certificate.der" 2>/dev/null ||
     ! openssl pkey -in "$private_key" -pubout -outform DER >"${work}/private-key.der" 2>/dev/null ||
     ! cmp -s "${work}/certificate.der" "${work}/private-key.der"; then
    rm -rf -- "$work"
    return 1
  fi
  rm -rf -- "$work"
}

render_certificate_hook() {
  local candidate="$1"
  cat >"$candidate" <<EOF
#!/bin/sh
set -eu
umask 077

live_dir='/etc/letsencrypt/live/${TLS_DOMAIN}'
cert_dir='${CERT_DIR}'
config_file='${CONFIG_FILE}'
service='sing-box.service'
nginx_service='nginx.service'
lock_file='${STATE_DIR}/certificate-deploy.lock'

if [ -n "\${RENEWED_LINEAGE:-}" ] && [ "\$RENEWED_LINEAGE" != "\$live_dir" ]; then
  exit 0
fi

exec 9>"\$lock_file"
flock -x 9
install -d -o root -g sing-box -m 0750 "\$cert_dir"
work_dir="\$(mktemp -d "\${cert_dir}/.renew.XXXXXX")"
had_previous=0
commit_active=0

cleanup() {
  status=\$?
  trap - EXIT HUP INT TERM
  if [ "\$commit_active" -eq 1 ]; then
    set +e
    restore_previous
    restore_status=\$?
    set -e
    [ "\$restore_status" -eq 0 ] || status=1
  fi
  rm -f -- "\${cert_dir}/fullchain.pem.new" "\${cert_dir}/privkey.pem.new" \
    "\${cert_dir}/fullchain.pem.restore" "\${cert_dir}/privkey.pem.restore"
  rm -rf -- "\$work_dir"
  exit "\$status"
}

restore_previous() {
  restore_failed=0
  if [ "\$had_previous" -eq 1 ]; then
    install -o root -g sing-box -m 0640 "\${work_dir}/previous-fullchain.pem" "\${cert_dir}/fullchain.pem.restore" || restore_failed=1
    install -o root -g sing-box -m 0640 "\${work_dir}/previous-privkey.pem" "\${cert_dir}/privkey.pem.restore" || restore_failed=1
    mv -f -- "\${cert_dir}/fullchain.pem.restore" "\${cert_dir}/fullchain.pem" || restore_failed=1
    mv -f -- "\${cert_dir}/privkey.pem.restore" "\${cert_dir}/privkey.pem" || restore_failed=1
    systemctl restart "\$service" >/dev/null 2>&1 || restore_failed=1
    systemctl reload-or-restart "\$nginx_service" >/dev/null 2>&1 || restore_failed=1
    systemctl is-active --quiet "\$nginx_service" || restore_failed=1
  else
    rm -f -- "\${cert_dir}/fullchain.pem" "\${cert_dir}/privkey.pem" || restore_failed=1
  fi
  return "\$restore_failed"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

install -o root -g root -m 0600 "\${live_dir}/fullchain.pem" "\${work_dir}/new-fullchain.pem"
install -o root -g root -m 0600 "\${live_dir}/privkey.pem" "\${work_dir}/new-privkey.pem"
openssl x509 -in "\${work_dir}/new-fullchain.pem" -noout -checkend 0
openssl x509 -in "\${work_dir}/new-fullchain.pem" -pubkey -noout >"\${work_dir}/certificate.pub"
openssl pkey -pubin -in "\${work_dir}/certificate.pub" -outform DER >"\${work_dir}/certificate.der"
openssl pkey -in "\${work_dir}/new-privkey.pem" -pubout -outform DER >"\${work_dir}/private-key.der"
cmp -s "\${work_dir}/certificate.der" "\${work_dir}/private-key.der"
nginx -t >/dev/null 2>&1

if [ -e "\${cert_dir}/fullchain.pem" ] || [ -e "\${cert_dir}/privkey.pem" ]; then
  [ -r "\${cert_dir}/fullchain.pem" ] && [ -r "\${cert_dir}/privkey.pem" ]
  install -o root -g root -m 0600 "\${cert_dir}/fullchain.pem" "\${work_dir}/previous-fullchain.pem"
  install -o root -g root -m 0600 "\${cert_dir}/privkey.pem" "\${work_dir}/previous-privkey.pem"
  had_previous=1
fi

install -o root -g sing-box -m 0640 "\${work_dir}/new-fullchain.pem" "\${cert_dir}/fullchain.pem.new"
install -o root -g sing-box -m 0640 "\${work_dir}/new-privkey.pem" "\${cert_dir}/privkey.pem.new"
commit_active=1
mv -f -- "\${cert_dir}/fullchain.pem.new" "\${cert_dir}/fullchain.pem"
mv -f -- "\${cert_dir}/privkey.pem.new" "\${cert_dir}/privkey.pem"

if ! sing-box check -c "\$config_file" >/dev/null 2>&1; then
  exit 1
fi
if ! systemctl reload-or-restart "\$service" || ! systemctl is-active --quiet "\$service"; then
  exit 1
fi
if ! systemctl reload "\$nginx_service" || ! systemctl is-active --quiet "\$nginx_service"; then
  exit 1
fi
commit_active=0
EOF
  sh -n "$candidate" || die 'Generated certificate deploy hook failed shell syntax validation.'
}

configure_certificate_hook() {
  local candidate
  install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  candidate="$(mktemp)"
  render_certificate_hook "$candidate"
  write_atomic "$CERT_HOOK" root root 0750 "$candidate"
  rm -f -- "$candidate"
}

verify_certificate_automation() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]] || die 'Live ACME certificate material is unavailable.'
  [[ -r "${CERT_DIR}/fullchain.pem" && -r "${CERT_DIR}/privkey.pem" ]] || die 'Deployed sing-box certificate material is unavailable.'
  [[ -f "$CERT_HOOK" && -x "$CERT_HOOK" ]] || die 'Certificate deploy hook is missing or not executable.'
  sh -n "$CERT_HOOK" || die 'Certificate deploy hook failed shell syntax validation.'
  systemctl is-enabled --quiet certbot.timer || die 'certbot.timer is not enabled.'
  systemctl is-active --quiet certbot.timer || die 'certbot.timer is not active.'
  nginx -t >/dev/null 2>&1 || die 'nginx rejects the subscription configuration.'
  systemctl is-active --quiet nginx.service || die 'nginx subscription service is inactive.'
  certificate_key_pair_matches "${live_dir}/fullchain.pem" "${live_dir}/privkey.pem" || die 'Live ACME certificate and private key do not match.'
  certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" || die 'Deployed certificate and private key do not match.'
  cmp -s "${live_dir}/fullchain.pem" "${CERT_DIR}/fullchain.pem" || die 'Deployed certificate differs from the current ACME certificate.'
  cmp -s "${live_dir}/privkey.pem" "${CERT_DIR}/privkey.pem" || die 'Deployed private key differs from the current ACME private key.'
}

smoke_test_certificate_hook() {
  "$CERT_HOOK"
  verify_certificate_automation
  systemctl is-active --quiet sing-box.service || die 'sing-box is inactive after the certificate deploy-hook smoke test.'
  systemctl is-active --quiet nginx.service || die 'nginx is inactive after the certificate deploy-hook smoke test.'
  log 'Certificate renewal hook, key pair, deployed copy, timer, sing-box, and nginx reload paths passed verification.'
}

obtain_certificate() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  if [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]]; then
    log 'Existing ACME certificate found; reusing it.'
  else
    if [[ -n "$(port_is_listening tcp 80 || true)" ]]; then
      die 'TCP/80 is occupied; certbot standalone cannot complete HTTP-01.'
    fi
    log "Requesting a Let's Encrypt certificate for ${TLS_DOMAIN}."
    certbot certonly --standalone --non-interactive --agree-tos \
      --preferred-challenges http --email "$ACME_EMAIL" --domain "$TLS_DOMAIN"
  fi
  deploy_certificate
  configure_certificate_hook
  systemctl enable --now certbot.timer >/dev/null
}
