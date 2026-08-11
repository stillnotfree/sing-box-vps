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

render_unattended_upgrades_config() {
  local output="$1" host_os_id="$2"
  cat >"$output" <<'EOF'
// VPN setup: automatic security updates only; no automatic reboot.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
#clear Unattended-Upgrade::Origins-Pattern;
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Origins-Pattern {
EOF
  case "$host_os_id" in
    debian)
      printf '%s\n' \
        "  \"origin=Debian,codename=\${distro_codename},label=Debian-Security\";" \
        "  \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";" \
        >>"$output"
      ;;
    ubuntu)
      printf '%s\n' \
        "  \"origin=Ubuntu,archive=\${distro_codename}-security,label=Ubuntu\";" \
        >>"$output"
      ;;
    *)
      die "Unsupported unattended-upgrades policy target: ${host_os_id:-unknown}"
      ;;
  esac
  cat >>"$output" <<'EOF'
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

unattended_policy_dump_is_security_only() {
  local host_os_id="$1" effective_dump="$2" line origin origins=""
  local debian_release_security debian_pocket_security ubuntu_pocket_security
  debian_release_security="origin=Debian,codename=\${distro_codename},label=Debian-Security"
  debian_pocket_security="origin=Debian,codename=\${distro_codename}-security,label=Debian-Security"
  ubuntu_pocket_security="origin=Ubuntu,archive=\${distro_codename}-security,label=Ubuntu"
  UNATTENDED_POLICY_REASON=""
  if ! grep -Fq 'APT::Periodic::Update-Package-Lists "1";' <<<"$effective_dump"; then
    UNATTENDED_POLICY_REASON='periodic package-list updates are disabled'
    return 1
  fi
  if ! grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' <<<"$effective_dump"; then
    UNATTENDED_POLICY_REASON='unattended upgrades are disabled'
    return 1
  fi
  if ! grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$effective_dump"; then
    UNATTENDED_POLICY_REASON='automatic reboot is not disabled'
    return 1
  fi
  origins="$(awk '
    /^Unattended-Upgrade::Origins-Pattern::/ ||
    /^Unattended-Upgrade::Allowed-Origins::/ {print}
  ' <<<"$effective_dump")"
  if [[ -z "$origins" ]]; then
    UNATTENDED_POLICY_REASON='no unattended-upgrade origins are configured'
    return 1
  fi
  while IFS= read -r line; do
    origin="${line#*\"}"
    origin="${origin%\";*}"
    case "$host_os_id" in
      debian)
        case "$origin" in
          "$debian_release_security"|"$debian_pocket_security") ;;
          *)
            UNATTENDED_POLICY_REASON='a non-security Debian origin is allowed'
            return 1
            ;;
        esac
        ;;
      ubuntu)
        if [[ "$origin" != "$ubuntu_pocket_security" ]]; then
          UNATTENDED_POLICY_REASON='a non-security Ubuntu origin is allowed'
          return 1
        fi
        ;;
      *)
        UNATTENDED_POLICY_REASON="unsupported distribution policy: ${host_os_id:-unknown}"
        return 1
        ;;
    esac
  done <<<"$origins"
}

configure_unattended_upgrades() {
  local candidate effective_dump host_os_id="$OS_ID"
  if [[ -z "$host_os_id" && -r /etc/os-release ]]; then
    host_os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | sed -n '1p')"
  fi
  candidate="$(mktemp)"
  render_unattended_upgrades_config "$candidate" "$host_os_id"
  write_atomic "$UNATTENDED_UPGRADES_CONFIG" root root 0644 "$candidate"
  rm -f -- "$candidate"
  effective_dump="$(apt-config dump)"
  unattended_policy_dump_is_security_only "$host_os_id" "$effective_dump" || \
    die "Effective unattended-upgrades policy is invalid: ${UNATTENDED_POLICY_REASON}."
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
  systemctl is-enabled --quiet apt-daily.timer || die 'apt-daily.timer is not enabled.'
  systemctl is-enabled --quiet apt-daily-upgrade.timer || die 'apt-daily-upgrade.timer is not enabled.'
  systemctl is-active --quiet apt-daily.timer || die 'apt-daily.timer is not active.'
  systemctl is-active --quiet apt-daily-upgrade.timer || die 'apt-daily-upgrade.timer is not active.'
  log "Configured ${host_os_id} unattended upgrades for security origins only, without automatic reboot."
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

capture_reality_target_audit_probe() {
  local target="$1" destination="$2" status=0
  if (
    # Bound a hostile or unexpectedly verbose endpoint to 2 MiB of diagnostics.
    ulimit -f 2048
    timeout 12 openssl s_client \
      -connect "${target}:443" \
      -servername "$target" \
      -verify_hostname "$target" \
      -tls1_3 -alpn h2 -verify_return_error -msg -ign_eof \
      <<< $'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
  ) >"$destination" 2>&1; then
    status=0
  else
    status=$?
  fi
  return "$status"
}

extract_reality_target_audit_text() {
  local raw_file="$1" text_file="$2"
  {
    LC_ALL=C grep -aEio \
      'New,[[:space:]]*TLSv1\.3|Protocol( version)?[[:space:]]*:[[:space:]]*TLSv1\.3' \
      "$raw_file" || true
    LC_ALL=C grep -aEio \
      'Verify return code:[[:space:]]*[0-9]+[[:space:]]*\([^[:cntrl:]]{0,120}\)|Verification:[[:space:]]*(OK|FAILED)' \
      "$raw_file" || true
    LC_ALL=C grep -aEio \
      'ALPN protocol:[[:space:]]*[^[:space:][:cntrl:]]+|No ALPN negotiated' \
      "$raw_file" || true
    LC_ALL=C grep -aEio 'NewSessionTicket' "$raw_file" || true
    LC_ALL=C grep -aEio \
      'alert[^[:cntrl:]]{0,160}|no application protocol|protocol version|wrong version number|unsupported protocol|certificate verify failed|unable to get local issuer certificate|hostname mismatch|certificate has expired|self-signed certificate|connection refused|name or service not known|temporary failure in name resolution|unexpected eof' \
      "$raw_file" || true
  } >"$text_file"
}

print_reality_target_audit_debug() {
  local probe_status="$1" raw_file="$2" text_file="$3" raw_size
  (( VERBOSE == 1 )) || return 0
  print_section 'OpenSSL audit diagnostics (--verbose)'
  printf 'OpenSSL exit status: %s\n' "$probe_status"
  printf 'Parsed diagnostic tokens:\n'
  sed -n '1,200p' "$text_file"
  printf 'Raw OpenSSL trace excerpt (first 64 KiB, control bytes removed):\n'
  LC_ALL=C head -c 65536 "$raw_file" | LC_ALL=C tr -cd '\11\12\15\40-\176'
  printf '\n'
  raw_size="$(wc -c <"$raw_file")"
  if (( raw_size > 65536 )); then
    printf '[Raw diagnostics truncated: %s bytes total]\n' "$raw_size"
  fi
}

print_reality_target_audit_details() {
  cat <<'EOF'
Details:
  0 tickets is preferred only for this Aparecium-class comparison heuristic.
  1 or more tickets is normal TLS 1.3 server behavior and remains usable.
  The warning means a REALITY server may be easier to compare with this target
  if it does not reproduce the target's post-handshake ticket behavior.
  This is not a general security or censorship-resistance verdict.
EOF
}

audit_reality_target() {
  local target="${AUDIT_TARGET:-$REALITY_TARGET}" raw_file text_file probe_status=0 ticket_count=0
  local tls_state=UNKNOWN certificate_state=UNKNOWN alpn_state=UNKNOWN
  local comparison_signal=UNKNOWN result reason="" ticket_word=tickets
  require_command openssl
  require_command timeout
  domain_is_valid "$target" || cli_error "Invalid fully qualified domain: $target"

  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    new_temp_dir
  fi
  raw_file="$(mktemp "${TMP_DIR}/reality-target-audit.raw.XXXXXX")"
  text_file="$(mktemp "${TMP_DIR}/reality-target-audit.text.XXXXXX")"
  chmod 0600 "$raw_file" "$text_file"
  if capture_reality_target_audit_probe "$target" "$raw_file"; then
    probe_status=0
  else
    probe_status=$?
  fi
  extract_reality_target_audit_text "$raw_file" "$text_file"

  if LC_ALL=C grep -Eiq \
    'New,[[:space:]]*TLSv1\.3|Protocol( version)?[[:space:]]*:[[:space:]]*TLSv1\.3' "$text_file"; then
    tls_state=PASS
  elif LC_ALL=C grep -Eiq 'protocol version|wrong version number|unsupported protocol' "$text_file"; then
    tls_state=FAIL
  fi
  if LC_ALL=C grep -Eiq \
    'Verify return code:[[:space:]]*0[[:space:]]*\(ok\)|Verification:[[:space:]]*OK' "$text_file"; then
    certificate_state=PASS
  elif LC_ALL=C grep -Eiq \
    'Verify return code:[[:space:]]*[1-9][0-9]*|Verification:[[:space:]]*FAILED|certificate verify failed|unable to get local issuer certificate|hostname mismatch|certificate has expired|self-signed certificate' \
    "$text_file"; then
    certificate_state=FAIL
  fi
  if LC_ALL=C grep -Eiq 'ALPN protocol:[[:space:]]*h2' "$text_file"; then
    alpn_state=PASS
  elif LC_ALL=C grep -Eiq 'no application protocol|No ALPN negotiated|ALPN protocol:' "$text_file"; then
    alpn_state=FAIL
  elif [[ "$tls_state" == PASS && "$certificate_state" == PASS ]]; then
    alpn_state=FAIL
  fi

  print_title 'REALITY target audit'
  printf 'Target: %s\n' "$target"
  printf 'TLS 1.3: %s\n' "$tls_state"
  printf 'Certificate/SNI: %s\n' "$certificate_state"
  printf 'ALPN h2: %s\n' "$alpn_state"

  if [[ "$tls_state" != PASS || "$certificate_state" != PASS || "$alpn_state" != PASS ]]; then
    if LC_ALL=C grep -Eiq 'no application protocol' "$text_file"; then
      reason='server returned TLS alert "no application protocol"'
    elif LC_ALL=C grep -Eiq 'protocol version|wrong version number|unsupported protocol' "$text_file"; then
      reason='server returned TLS alert "protocol version"'
    elif LC_ALL=C grep -Eiq 'hostname mismatch' "$text_file"; then
      reason='certificate does not match the requested SNI'
    elif LC_ALL=C grep -Eiq 'certificate has expired' "$text_file"; then
      reason='certificate has expired'
    elif LC_ALL=C grep -Eiq 'unable to get local issuer certificate|self-signed certificate' "$text_file"; then
      reason='certificate chain is not trusted'
    elif LC_ALL=C grep -Eiq 'certificate verify failed|Verify return code:[[:space:]]*[1-9][0-9]*|Verification:[[:space:]]*FAILED' "$text_file"; then
      reason='certificate/SNI verification failed'
    elif (( probe_status == 124 )); then
      reason='probe timed out after 12 seconds'
    elif LC_ALL=C grep -Eiq 'connection refused' "$text_file"; then
      reason='target refused the TCP connection'
    elif LC_ALL=C grep -Eiq 'name or service not known|temporary failure in name resolution' "$text_file"; then
      reason='target DNS resolution failed'
    elif LC_ALL=C grep -Eiq 'unexpected eof' "$text_file"; then
      reason='server closed the connection during the TLS handshake'
    elif [[ "$alpn_state" == FAIL ]]; then
      reason='server did not negotiate ALPN h2'
    elif [[ "$tls_state" != PASS ]]; then
      reason='TLS 1.3 handshake did not complete'
    elif [[ "$certificate_state" != PASS ]]; then
      reason='certificate/SNI status could not be verified'
    else
      reason="OpenSSL probe exited with status ${probe_status}"
    fi
    printf 'Reason: %s\n' "$reason"
    printf 'Result: FAIL\n'
    print_reality_target_audit_debug "$probe_status" "$raw_file" "$text_file"
    return 2
  fi

  ticket_count="$(LC_ALL=C grep -cFx 'NewSessionTicket' "$text_file" || true)"
  printf 'Post-handshake NewSessionTicket: %s\n' "$ticket_count"
  if (( ticket_count == 0 )); then
    comparison_signal='NOT OBSERVED'
    result='PASS — preferred'
    printf 'Comparison signal: %s\n' "$comparison_signal"
    printf 'Result: %s\n' "$result"
    print_reality_target_audit_debug "$probe_status" "$raw_file" "$text_file"
    return
  fi

  (( ticket_count == 1 )) && ticket_word=ticket
  comparison_signal=OBSERVED
  result="WARN — target is usable, but ${ticket_count} post-handshake ${ticket_word} were observed."
  if (( ticket_count == 1 )); then
    result='WARN — target is usable, but 1 post-handshake ticket was observed.'
  fi
  printf 'Comparison signal: %s\n' "$comparison_signal"
  printf 'Result: %s\n' "$result"
  printf 'Note: TLS 1.3 session tickets are normal; this WARN is only the comparison heuristic.\n'
  print_reality_target_audit_debug "$probe_status" "$raw_file" "$text_file"
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

    if (( audit_status == 1 )) && { (( ASSUME_YES == 1 )) || ! interactive_stdin; }; then
      REALITY_TARGET_AUDITED=1
      return
    fi
    if (( ASSUME_YES == 1 )) || ! interactive_stdin; then
      die "REALITY target ${REALITY_TARGET} failed a required TLS 1.3, certificate, or ALPN h2 check; rerun with a different --reality-target."
    fi

    if (( audit_status == 1 )); then
      while true; do
        cat <<'EOF'

[K] Keep this target
[T] Try another target
[?] Details

EOF
        read -r -p 'Choice [K]: ' answer
        answer="${answer:-k}"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
          k|keep|y|yes)
            log "Keeping explicitly accepted REALITY target ${REALITY_TARGET} despite the audit warning."
            REALITY_TARGET_AUDITED=1
            return
            ;;
          t|try|n|no|new)
            REALITY_TARGET=""
            prompt_value REALITY_TARGET 'Replacement REALITY target' '' domain_is_valid
            break
            ;;
          \?)
            print_reality_target_audit_details
            ;;
          *)
            warn 'Choose K to keep, T to try another target, or ? for details.'
            ;;
        esac
      done
    else
      warn "Choose another REALITY target; ${REALITY_TARGET} failed a required TLS, certificate, or ALPN check."
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

# A successful reload is not proof that nginx serves the renewed certificate.
# Compare the leaf certificate from a bounded local TLS handshake with the new
# ACME leaf before accepting the deployment transaction.
served_transcript="\${work_dir}/served-transcript"
served_pem="\${work_dir}/served.pem"
served_der="\${work_dir}/served.der"
expected_der="\${work_dir}/expected.der"
if ! (ulimit -f 256; timeout 10 openssl s_client \
    -connect '127.0.0.1:${SUBSCRIPTION_PORT}' -servername '${TLS_DOMAIN}' \
    -verify_hostname '${TLS_DOMAIN}' -verify_return_error -showcerts \
    </dev/null >"\$served_transcript" 2>&1); then
  exit 1
fi
LC_ALL=C awk '
  /-----BEGIN CERTIFICATE-----/ { copying=1 }
  copying { print }
  /-----END CERTIFICATE-----/ { exit }
' "\$served_transcript" >"\$served_pem"
[ -s "\$served_pem" ]
openssl x509 -in "\${work_dir}/new-fullchain.pem" -outform DER >"\$expected_der"
openssl x509 -in "\$served_pem" -outform DER >"\$served_der"
cmp -s "\$expected_der" "\$served_der"
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
  health_live_subscription_certificate_matches "${live_dir}/fullchain.pem" || \
    die 'The subscription endpoint is not serving the current ACME certificate.'
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
