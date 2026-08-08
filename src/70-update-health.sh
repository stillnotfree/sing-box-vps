update_sing_box() {
  local installed candidate old_package new_package candidate_root failed=0
  require_client_runtime
  require_confirmation
  require_command apt-cache
  require_command apt-get
  require_command dpkg-deb

  acquire_operation_lock
  load_settings
  require_client_runtime
  installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  [[ -n "$installed" ]] || die 'sing-box is not installed.'
  old_package="$(find_cached_sing_box_package "$installed" || true)"
  [[ -n "$old_package" ]] || die 'The current sing-box rollback package is missing; refusing an unsafe update.'

  configure_sing_box_repository
  apt-get update
  candidate="$(sing_box_candidate_version)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die 'No stable sing-box update candidate is available.'
  require_supported_sing_box_version "$candidate"
  if [[ "$candidate" == "$installed" ]]; then
    log "sing-box ${installed} is already the latest supported stable release."
    return
  fi
  dpkg --compare-versions "$candidate" gt "$installed" || die "Refusing non-upgrade candidate ${candidate} over ${installed}."

  new_temp_dir
  new_package="$(download_sing_box_package "$candidate" "${TMP_DIR}/download")"
  candidate_root="${TMP_DIR}/candidate-root"
  mkdir -p "$candidate_root"
  dpkg-deb -x "$new_package" "$candidate_root"
  [[ -x "${candidate_root}/usr/bin/sing-box" ]] || die 'Candidate package does not contain the sing-box binary.'
  "${candidate_root}/usr/bin/sing-box" check -c "$CONFIG_FILE"
  new_package="$(archive_sing_box_package "$new_package")"

  log "Installing validated sing-box ${candidate} (rollback: ${installed})."
  dpkg --force-confold -i "$new_package" >/dev/null 2>&1 || failed=1
  if (( failed == 0 )); then
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
    systemctl restart sing-box.service >/dev/null 2>&1 || failed=1
    systemctl is-active --quiet sing-box.service || failed=1
  fi

  if (( failed == 1 )); then
    warn "sing-box ${candidate} failed validation or startup; restoring ${installed}."
    dpkg --force-confold -i "$old_package" >/dev/null || die 'Automatic package rollback failed during dpkg installation.'
    sing-box check -c "$CONFIG_FILE" >/dev/null || die 'Rollback package cannot validate the existing configuration.'
    systemctl restart sing-box.service
    systemctl is-active --quiet sing-box.service || die 'Rollback package was restored, but sing-box is not active.'
    apt-mark hold sing-box >/dev/null
    die "Update failed; sing-box ${installed} was restored."
  fi

  apt-mark hold sing-box >/dev/null
  prune_sing_box_packages
  log "sing-box updated successfully: ${installed} -> ${candidate}."
}

redact_health_stream() {
  sed -E \
    -e 's#(vless|hysteria2)://[^[:space:]]+#\1://[REDACTED]#g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{64}/[TOKEN-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{48}/[SECRET-REDACTED]/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g' \
    -e 's/\[[0-9a-fA-F:]+\]/[IPv6-REDACTED]/g' \
    -e 's/(^|[^[:alnum:]_-])([[:alnum:]-]+\.)+[[:alpha:]]{2,}([^[:alnum:]_-]|$)/\1[DOMAIN-REDACTED]\3/g' \
    -e 's/((password|private_key|public_key|short_id|secret|pbk|sid)[^:=]*[:=][[:space:]]*)[^, }"]+/\1[REDACTED]/Ig'
}

print_fragmentation_guidance() {
  print_section 'Client-side REALITY fragmentation guidance'
  cat <<'EOF'
Server-enforced fragmentation: disabled (this is a client-side troubleshooting option)
Subscription-enforced fragmentation: disabled (client syntax is not portable)

Leave fragmentation disabled while REALITY works. If Hysteria2 works but
REALITY repeatedly times out on one network, first test another supported TLS
fingerprint with "vpn set-fingerprint" and refresh the subscription.
Only then, in one affected client, temporarily test TLS-record/TLSHello
fragmentation if that client explicitly supports it. Do not enable ordinary
packet fragmentation globally: it can increase latency, battery use, and
breakage, and it cannot repair an IP block or an unreachable TCP/443 path.
Record the client name/version, access network, and result before keeping it.
EOF
}

health_details() {
  local config_result dns_one dns_two cert_status target_status service_status
  local timer_enabled timer_active hook_status renewal_status sync_status keypair_status
  local health_status=0 health_summary default_interface link_stats
  require_root
  print_title 'VPN health details'
  print_section 'HEALTH SUMMARY'
  health_summary="$(health_check)" || health_status=$?
  printf '%s\n' "$health_summary" | redact_health_stream
  printf '\nGenerated: %s\n' "$(date --iso-8601=seconds)"
  printf 'Installer: %s\n' "$SCRIPT_VERSION"
  printf 'Managed runtime: %s\n' "$(cat "$RUNTIME_VERSION_FILE" 2>/dev/null || printf missing)"

  print_section 'CONFIG'
  printf 'REALITY fingerprint: %s\n' "$CLIENT_FINGERPRINT"
  printf 'Hysteria2 obfuscation: %s\n' "$HY2_OBFS_MODE"
  printf 'Subscription URLs: stable across target/fingerprint/obfuscation changes\n'

  print_section 'LOCAL SYSTEM'
  sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'
  printf 'Kernel: %s\n' "$(uname -r)"
  uptime -p 2>/dev/null || true
  free -h 2>/dev/null | sed -n '1,2p' || true
  df -h / 2>/dev/null | tail -n 1 || true
  swapon --show 2>/dev/null || true
  timedatectl show -p NTPSynchronized -p Timezone 2>/dev/null || true

  print_section 'LOCAL SERVICES'
  printf 'Installed: %s\n' "$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || printf missing)"
  printf 'APT hold: %s\n' "$(apt-mark showhold 2>/dev/null | grep -Fx sing-box || printf missing)"
  service_status="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  printf 'Service: %s\n' "${service_status:-unknown}"
  if config_result="$(sing-box check -c "$CONFIG_FILE" 2>&1)"; then
    printf 'Config validation: PASS\n'
  else
    printf 'Config validation: FAIL\n%s\n' "$config_result" | redact_health_stream
  fi
  jq -r '.inbounds[] | "Inbound: \(.type) tag=\(.tag) port=\(.listen_port) users=\(.users | length)"' \
    "$CONFIG_FILE" 2>/dev/null || true

  print_section 'SERVER EGRESS AND NETWORK'
  printf 'Configured public IPv4: [REDACTED]\n'
  dns_one="$(dig +short A "$TLS_DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)"
  dns_two="$(dig +short A "$TLS_DOMAIN" @8.8.8.8 2>/dev/null | sed '/^$/d' || true)"
  if grep -Fxq "$SERVER_IPV4" <<<"$dns_one" && grep -Fxq "$SERVER_IPV4" <<<"$dns_two"; then
    printf 'DNS A consistency: PASS\n'
  else
    printf 'DNS A consistency: FAIL\n'
  fi
  if timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" -servername "$REALITY_TARGET" \
      -tls1_3 -alpn h2 -verify_return_error </dev/null >/dev/null 2>&1; then
    target_status=PASS
  else
    target_status=FAIL
  fi
  printf 'REALITY target TLS reachability: %s\n' "$target_status"
  printf 'Listeners (addresses redacted):\n'
  ss -H -lntup 2>/dev/null | awk -v ssh_port="$SSH_PORT" -v subscription_port="$SUBSCRIPTION_PORT" \
    '$5 ~ (":" ssh_port "$") || $5 ~ (":" subscription_port "$") || $5 ~ /:(80|443)$/ {print}' | redact_health_stream
  printf 'UDP receive ceiling: %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || printf unknown)"
  printf 'UDP send ceiling: %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || printf unknown)"
  default_interface="$(ip -4 route show default 2>/dev/null | awk '
    !found {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && (i + 1) <= NF) {
          interface=$(i + 1)
          found=1
          break
        }
      }
    }
    END { if (found) print interface }
  ')"
  if [[ -n "$default_interface" ]]; then
    printf 'Default interface counters (%s):\n' "$default_interface"
    link_stats="$(ip -s -j link show dev "$default_interface" 2>/dev/null || true)"
    if jq -e 'type == "array" and length == 1' <<<"$link_stats" >/dev/null 2>&1; then
      jq -r '.[0] |
        "  RX bytes=\(.stats64.rx.bytes // .stats.rx.bytes // 0) packets=\(.stats64.rx.packets // .stats.rx.packets // 0) errors=\(.stats64.rx.errors // .stats.rx.errors // 0) dropped=\(.stats64.rx.dropped // .stats.rx.dropped // 0)",
        "  TX bytes=\(.stats64.tx.bytes // .stats.tx.bytes // 0) packets=\(.stats64.tx.packets // .stats.tx.packets // 0) errors=\(.stats64.tx.errors // .stats.tx.errors // 0) dropped=\(.stats64.tx.dropped // .stats.tx.dropped // 0)"' \
        <<<"$link_stats"
    else
      printf '  unavailable\n'
    fi
    printf 'Queue discipline counters:\n'
    tc -s qdisc show dev "$default_interface" 2>/dev/null || true
  fi

  print_fragmentation_guidance

  print_section 'TLS CERTIFICATE'
  if [[ -r "${CERT_DIR}/fullchain.pem" ]]; then
    openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -dates 2>/dev/null || true
    if openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1; then
      cert_status='PASS (valid for more than 7 days)'
    else
      cert_status='WARN (expired or expires within 7 days)'
    fi
  else
    cert_status='FAIL (certificate copy missing)'
  fi
  printf 'Certificate status: %s\n' "$cert_status"
  timer_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  timer_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
  printf 'Certbot timer enabled: %s\n' "${timer_enabled:-unknown}"
  printf 'Certbot timer active: %s\n' "${timer_active:-unknown}"
  if [[ -f "$CERT_HOOK" && -x "$CERT_HOOK" ]] && sh -n "$CERT_HOOK" >/dev/null 2>&1; then
    hook_status='PASS (present, executable, syntax valid)'
  else
    hook_status='FAIL'
  fi
  printf 'Deploy hook: %s\n' "$hook_status"
  if [[ -r "/etc/letsencrypt/renewal/${TLS_DOMAIN}.conf" ]]; then
    renewal_status='PASS'
  else
    renewal_status='FAIL'
  fi
  printf 'Renewal configuration: %s\n' "$renewal_status"
  if [[ -r "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" &&
        -r "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" &&
        -r "${CERT_DIR}/fullchain.pem" && -r "${CERT_DIR}/privkey.pem" ]] &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" "${CERT_DIR}/fullchain.pem" &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" "${CERT_DIR}/privkey.pem"; then
    sync_status='PASS'
  else
    sync_status='FAIL'
  fi
  printf 'Live/deployed certificate sync: %s\n' "$sync_status"
  if certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"; then
    keypair_status='PASS'
  else
    keypair_status='FAIL'
  fi
  printf 'Deployed certificate/key pair: %s\n' "$keypair_status"

  print_section 'SECURITY'
  if managed_firewall_is_healthy; then
    printf 'nftables persistence and managed policy: PASS\n'
  else
    printf 'nftables persistence and managed policy: FAIL\n'
  fi
  if ssh_lockdown_is_effective; then
    printf 'SSH key-only lockdown: PASS\n'
  else
    printf 'SSH key-only lockdown: FAIL\n'
  fi
  systemctl --failed --no-pager --no-legend 2>/dev/null || true
  journalctl --disk-usage 2>/dev/null || true

  print_section 'RECENT SING-BOX WARNINGS/ERRORS — REDACTED'
  journalctl -u sing-box.service --since '-30 minutes' -p warning..alert -n 80 \
    --no-pager --output=short-iso 2>/dev/null | redact_health_stream || true
  printf '\nSecrets, client UUIDs, connection URIs, and IP addresses are redacted. Review before sharing.\n'
  return "$health_status"
}

managed_firewall_is_healthy() {
  local firewall_input
  [[ -s "${STATE_DIR}/firewall.confirmed" ]] || return 1
  [[ -s "${STATE_DIR}/firewall.managed" ]] || return 1
  systemctl is-enabled --quiet nftables.service 2>/dev/null || return 1
  systemctl is-active --quiet nftables.service 2>/dev/null || return 1
  nft --check --file "$NFT_CONFIG" >/dev/null 2>&1 || return 1
  firewall_input="$(nft list chain inet vpn_filter input 2>/dev/null || true)"
  grep -Eq 'tcp dport.*443.*accept' <<<"$firewall_input" || return 1
  grep -Eq "tcp dport.*${SUBSCRIPTION_PORT}.*accept" <<<"$firewall_input" || return 1
  grep -Eq 'udp dport 443.*accept' <<<"$firewall_input" || return 1
}

ssh_lockdown_is_effective() {
  local effective
  [[ -f "$SSH_DROPIN" && ! -L "$SSH_DROPIN" ]] || return 1
  /usr/sbin/sshd -t >/dev/null 2>&1 || return 1
  effective="$(/usr/sbin/sshd -T 2>/dev/null)" || return 1
  grep -Fxq 'permitrootlogin no' <<<"$effective" || return 1
  grep -Fxq 'passwordauthentication no' <<<"$effective" || return 1
  grep -Fxq 'kbdinteractiveauthentication no' <<<"$effective" || return 1
  grep -Fxq 'authenticationmethods publickey' <<<"$effective" || return 1
  grep -Eq "^allowusers([[:space:]].*)?[[:space:]]${ADMIN_USER}([[:space:]]|$)" <<<"$effective" || return 1
}

health_check() {
  local failures=0 dns_one dns_two core_state=PASS protocol_state=PASS
  local subscription_state=PASS tls_state=PASS security_state=PASS target_state=PASS
  local core_version client_count
  local -a problems=()

  require_root
  core_version="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || printf missing)"
  client_count="$(jq -r '.clients | length' "$CLIENTS_FILE" 2>/dev/null || printf unknown)"

  if [[ "$(cat "$RUNTIME_VERSION_FILE" 2>/dev/null || true)" != "$SCRIPT_VERSION" ]] ||
     ! sing_box_version_is_supported "$core_version" ||
     ! systemctl is-active --quiet sing-box.service ||
     ! sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    core_state=FAIL
    (( failures += 1 ))
    problems+=('sing-box service, configuration or managed version is unhealthy')
  fi

  if ! jq -e '
      any(.inbounds[];
        .type == "vless" and .listen_port == 443 and
        .tls.enabled == true and .tls.reality.enabled == true and
        ((.users | length) > 0))' "$CONFIG_FILE" >/dev/null 2>&1 ||
     ! ss -H -lntp 2>/dev/null |
       awk '$4 ~ /:443$/ && $0 ~ /sing-box/ { found=1 } END { exit !found }' ||
     ! jq -e '
      any(.inbounds[];
        .type == "hysteria2" and .listen_port == 443 and
        .tls.enabled == true and ((.users | length) > 0))' \
       "$CONFIG_FILE" >/dev/null 2>&1 ||
     ! ss -H -lnup 2>/dev/null |
       awk '$4 ~ /:443$/ && $0 ~ /sing-box/ { found=1 } END { exit !found }'; then
    protocol_state=FAIL
    (( failures += 1 ))
    problems+=('one or both VPN listeners on TCP/443 and UDP/443 are unhealthy')
  fi

  if ! subscription_service_healthy; then
    subscription_state=FAIL
    (( failures += 1 ))
    problems+=('the private subscription service is unhealthy')
  fi

  dns_one="$(dig +short A "$TLS_DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)"
  dns_two="$(dig +short A "$TLS_DOMAIN" @8.8.8.8 2>/dev/null | sed '/^$/d' || true)"
  if ! grep -Fxq "$SERVER_IPV4" <<<"$dns_one" ||
     ! grep -Fxq "$SERVER_IPV4" <<<"$dns_two" ||
     [[ ! -r "${CERT_DIR}/fullchain.pem" ]] ||
     ! openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1 ||
     ! certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" ||
     ! systemctl is-enabled --quiet certbot.timer 2>/dev/null ||
     ! systemctl is-active --quiet certbot.timer 2>/dev/null ||
     [[ ! -x "$CERT_HOOK" ]] ||
     ! sh -n "$CERT_HOOK" >/dev/null 2>&1; then
    tls_state=FAIL
    (( failures += 1 ))
    problems+=('DNS, TLS certificate or automatic renewal is unhealthy')
  fi

  if ! timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" \
      -servername "$REALITY_TARGET" -tls1_3 -alpn h2 -verify_return_error \
      </dev/null >/dev/null 2>&1; then
    target_state=FAIL
    (( failures += 1 ))
    problems+=('the REALITY target failed its TLS 1.3/h2 probe')
  fi

  if ! managed_firewall_is_healthy || ! ssh_lockdown_is_effective; then
    security_state=FAIL
    (( failures += 1 ))
    problems+=('nftables persistence or SSH key-only lockdown is unhealthy')
  fi

  print_title 'VPN health'
  print_status_row Core "$core_state" "sing-box ${core_version}"
  print_status_row Protocols "$protocol_state" 'REALITY tcp/443 · Hysteria2 udp/443'
  print_status_row Subscription "$subscription_state" "${client_count} client(s)"
  print_status_row DNS/TLS "$tls_state" "$TLS_DOMAIN"
  print_status_row REALITY "$target_state" "$REALITY_TARGET"
  print_status_row Security "$security_state" 'nftables · SSH key-only'
  printf '  %-14s %s\n' Profiles "${CLIENT_FINGERPRINT} · Hysteria2 obfs ${HY2_OBFS_MODE}"
  printf '  %-14s %s\n' Network \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown) · $(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"

  if (( failures == 0 )); then
    printf '\nResult: '
    print_status_value HEALTHY
    printf '\n'
    return 0
  fi

  print_section 'Problems'
  printf '  - %s\n' "${problems[@]}"
  printf 'Result: '
  print_status_value UNHEALTHY
  printf ' (%d)\n' "$failures"
  printf '\nServer-side checks do not prove reachability from a client network.\n'
  printf 'Possible causes include path filtering, UDP filtering, or IP/subnet blocking.\n'
  return 1
}
