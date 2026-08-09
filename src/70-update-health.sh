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
  download_sing_box_package "$candidate" new_package
  candidate_root="${TMP_DIR}/candidate-root"
  mkdir -p "$candidate_root"
  dpkg-deb -x "$new_package" "$candidate_root"
  [[ -x "${candidate_root}/usr/bin/sing-box" ]] || die 'Candidate package does not contain the sing-box binary.'
  "${candidate_root}/usr/bin/sing-box" check -c "$CONFIG_FILE"
  new_package="$(archive_sing_box_package "$new_package")"
  cleanup_apt_download_dir

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

health_build_redaction_literals() {
  local output="$1" value
  # Keep the first awk input non-empty. With an empty first file, portable awk
  # cannot distinguish it from stdin using FNR == NR and would consume every
  # diagnostic line as a literal definition.
  printf '\t\n' >"$output"
  chmod 0600 "$output"
  if [[ -n "$SERVER_IPV4" ]]; then
    printf '%s\t%s\n' "$SERVER_IPV4" '[IP-REDACTED]' >>"$output"
  fi
  if [[ -n "$TLS_DOMAIN" ]]; then
    printf '%s\t%s\n' "$TLS_DOMAIN" '[DOMAIN-REDACTED]' >>"$output"
  fi
  if [[ -n "$REALITY_TARGET" ]]; then
    printf '%s\t%s\n' "$REALITY_TARGET" '[DOMAIN-REDACTED]' >>"$output"
  fi
  for value in "${REALITY_PRIVATE_KEY:-}" "${REALITY_PUBLIC_KEY:-}" \
    "${REALITY_SHORT_ID:-}" "${HY2_OBFS_PASSWORD:-}"; do
    if [[ -n "$value" ]]; then
      printf '%s\t%s\n' "$value" '[SECRET-REDACTED]' >>"$output"
    fi
  done
  if [[ -r "$SECRETS_FILE" ]]; then
    (
      set +u
      # shellcheck disable=SC1090
      source "$SECRETS_FILE"
      for value in "${REALITY_PRIVATE_KEY:-}" "${REALITY_PUBLIC_KEY:-}" \
        "${REALITY_SHORT_ID:-}" "${HY2_OBFS_PASSWORD:-}"; do
        if [[ -n "$value" ]]; then
          printf '%s\t%s\n' "$value" '[SECRET-REDACTED]'
        fi
      done
    ) >>"$output"
  fi
  if [[ -r "$CLIENTS_FILE" ]]; then
    jq -r '.clients[] | (.vless_uuid // empty), (.hy2_password // empty),
      (.subscription_token // empty)' \
      "$CLIENTS_FILE" 2>/dev/null | while IFS= read -r value; do
        if [[ -n "$value" ]]; then
          printf '%s\t%s\n' "$value" '[CREDENTIAL-REDACTED]'
        fi
      done >>"$output"
  fi
}

redact_health_stream() {
  local literals_file status=0
  literals_file="$(mktemp)"
  health_build_redaction_literals "$literals_file"
  LC_ALL=C awk -F '\t' '
    FNR == NR {
      if (length($1) > 0) {
        needle[++count]=$1
        replacement[count]=$2
      }
      next
    }
    {
      line=$0
      for (i=1; i<=count; i++) {
        while ((position=index(line, needle[i])) > 0) {
          line=substr(line, 1, position - 1) replacement[i] \
            substr(line, position + length(needle[i]))
        }
      }
      print line
    }
  ' "$literals_file" - | sed -E \
    -e 's#(vless|hysteria2)://[^[:space:]]+#\1://[REDACTED]#g' \
    -e 's#(https?://)[^/@[:space:]]+@#\1[CREDENTIALS-REDACTED]@#g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{64}/[TOKEN-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{48}/[SECRET-REDACTED]/g' \
    -e 's/[A-Za-z0-9+_\/-]{32,}={0,2}/[SECRET-REDACTED]/g' \
    -e 's/(^|[^0-9])(([0-9]{1,3}\.){3}[0-9]{1,3})(:[0-9]+)?([^0-9]|$)/\1[IP-REDACTED]\5/g' \
    -e 's/\[[0-9a-fA-F]*:[0-9a-fA-F:]*\]/[IPv6-REDACTED]/g' \
    -e 's/(^|[^0-9a-fA-F:])([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}([^0-9a-fA-F:]|$)/\1[IPv6-REDACTED]\3/g' \
    -e 's/(^|[^0-9a-fA-F:])([0-9a-fA-F]{0,4}:){1,7}:[0-9a-fA-F]{0,4}([^0-9a-fA-F:]|$)/\1[IPv6-REDACTED]\3/g' \
    -e 's/((password|private_key|public_key|short_id|secret|token|pbk|sid)[^:=]*[:=][[:space:]]*)[^, }"]+/\1[REDACTED]/Ig' || status=$?
  rm -f -- "$literals_file"
  return "$status"
}

health_join_states() {
  local state saw_warn=0
  for state in "$@"; do
    case "$state" in
      FAIL) printf 'FAIL\n'; return ;;
      WARN) saw_warn=1 ;;
    esac
  done
  if (( saw_warn == 1 )); then
    printf 'WARN\n'
  else
    printf 'PASS\n'
  fi
}

health_client_label() {
  local count="$1"
  if [[ "$count" == "1" ]]; then
    printf '1 client\n'
  else
    printf '%s clients\n' "$count"
  fi
}

health_print_row() {
  local label="$1" state="$2" details="${3:-}"
  printf '  %-14s ' "$label"
  print_status_value "$state"
  if [[ -n "$details" ]]; then
    printf ' · %s' "$details"
  fi
  printf '\n'
}

health_print_info() {
  local label="$1" details="$2"
  [[ -n "$details" ]] || return 0
  printf '  %-14s %s\n' "$label" "$details"
}

health_human_size() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  if (( bytes >= 1073741824 )); then
    awk -v value="$bytes" 'BEGIN { printf "%.1f GiB", value / 1073741824 }'
  else
    awk -v value="$bytes" 'BEGIN { printf "%.0f MiB", value / 1048576 }'
  fi
}

health_format_uptime() {
  local seconds="${1%%.*}" days hours minutes
  [[ "$seconds" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  days=$(( seconds / 86400 ))
  hours=$(( (seconds % 86400) / 3600 ))
  minutes=$(( (seconds % 3600) / 60 ))
  if (( days > 0 )); then
    printf '%dd %dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

health_reset_state() {
  HEALTH_FAILURES=0
  HEALTH_WARNINGS=0
  HEALTH_CORE_STATE=PASS
  HEALTH_CORE_VERSION=missing
  HEALTH_VERSION_STATE=FAIL
  HEALTH_RUNTIME_STATE=FAIL
  HEALTH_SERVICE_STATE=FAIL
  HEALTH_CONFIG_STATE=FAIL
  HEALTH_VLESS_STATE=FAIL
  HEALTH_HY2_STATE=FAIL
  HEALTH_SUBSCRIPTION_STATE=FAIL
  HEALTH_SUBSCRIPTION_DETAIL='self-test failed'
  HEALTH_DNS_STATE=FAIL
  HEALTH_CERT_STATE=FAIL
  HEALTH_CERT_DETAIL='certificate unavailable'
  HEALTH_CERT_HOSTNAME_STATE=FAIL
  HEALTH_CERT_KEYPAIR_STATE=FAIL
  HEALTH_RENEWAL_STATE=FAIL
  HEALTH_RENEWAL_DETAIL='renewal checks failed'
  HEALTH_TARGET_STATE=FAIL
  HEALTH_FIREWALL_STATE=FAIL
  HEALTH_SSH_STATE=FAIL
  HEALTH_PERMISSIONS_STATE=FAIL
  HEALTH_SECURITY_UPDATES_STATE=WARN
  HEALTH_SECURITY_UPDATES_DETAIL='automatic update policy unavailable'
  HEALTH_CORE_UPDATES_STATE=FAIL
  HEALTH_CORE_UPDATES_DETAIL='sing-box apt hold unavailable'
  HEALTH_TCP443_STATE=FAIL
  HEALTH_UDP443_STATE=FAIL
  HEALTH_TCP8443_STATE=FAIL
  HEALTH_SSH_LISTENER_STATE=FAIL
  HEALTH_TCP443_DETAIL='not listening'
  HEALTH_UDP443_DETAIL='not listening'
  HEALTH_TCP8443_DETAIL='not listening'
  HEALTH_SSH_LISTENER_DETAIL='not listening'
  HEALTH_CONGESTION_STATE=WARN
  HEALTH_CONGESTION=unknown
  HEALTH_QUEUE_STATE=WARN
  HEALTH_QUEUE_DETAIL='active state unavailable'
  HEALTH_ACTIVE_QDISC=unknown
  HEALTH_CONFIGURED_QDISC=unknown
  HEALTH_DEFAULT_INTERFACE=""
  HEALTH_CLIENT_COUNT=unknown
  HEALTH_VLESS_CLIENTS=unknown
  HEALTH_HY2_CLIENTS=unknown
  HEALTH_OS=unknown
  HEALTH_KERNEL=unknown
  HEALTH_UPTIME=unknown
  HEALTH_UPTIME_SECONDS=""
  HEALTH_RESOURCES=unknown
  HEALTH_CLOCK_STATE=WARN
  HEALTH_CLOCK_DETAIL='NTP state unknown'
  HEALTH_RUNTIME_VERSION=missing
  HEALTH_RECENT_ERRORS_STATE=PASS
  HEALTH_RECENT_ERRORS_FILE=""
  HEALTH_DEBUG_ACTIONABLE_FILE=""
  HEALTH_REALITY_NOISE_SAMPLES_FILE=""
  HEALTH_REALITY_NOISE_COUNT=0
  HEALTH_REALITY_NOISE_UNIQUE_SOURCES=0
  HEALTH_SS_TCP=""
  HEALTH_SS_UDP=""
}

health_listener_check() {
  local listeners="$1" port="$2" expected="$3" line owner
  line="$(printf '%s\n' "$listeners" | awk -v port="$port" '$4 ~ (":" port "$") { print; exit }')"
  if [[ -z "$line" ]]; then
    HEALTH_LISTENER_STATE=FAIL
    HEALTH_LISTENER_DETAIL='not listening'
    return
  fi
  if grep -Fq "\"${expected}\"" <<<"$line"; then
    HEALTH_LISTENER_STATE=PASS
    HEALTH_LISTENER_DETAIL="${expected} listening"
    return
  fi
  owner="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line")"
  HEALTH_LISTENER_STATE=FAIL
  HEALTH_LISTENER_DETAIL="expected ${expected}, found ${owner:-unknown process}"
}

health_collect_listeners() {
  HEALTH_SS_TCP="$(ss -H -lntp 2>/dev/null || true)"
  HEALTH_SS_UDP="$(ss -H -lnup 2>/dev/null || true)"

  health_listener_check "$HEALTH_SS_TCP" 443 sing-box
  HEALTH_TCP443_STATE="$HEALTH_LISTENER_STATE"
  HEALTH_TCP443_DETAIL="$HEALTH_LISTENER_DETAIL"
  health_listener_check "$HEALTH_SS_UDP" 443 sing-box
  HEALTH_UDP443_STATE="$HEALTH_LISTENER_STATE"
  HEALTH_UDP443_DETAIL="$HEALTH_LISTENER_DETAIL"
  health_listener_check "$HEALTH_SS_TCP" "$SUBSCRIPTION_PORT" nginx
  HEALTH_TCP8443_STATE="$HEALTH_LISTENER_STATE"
  HEALTH_TCP8443_DETAIL="$HEALTH_LISTENER_DETAIL"
  health_listener_check "$HEALTH_SS_TCP" "$SSH_PORT" sshd
  HEALTH_SSH_LISTENER_STATE="$HEALTH_LISTENER_STATE"
  HEALTH_SSH_LISTENER_DETAIL="$HEALTH_LISTENER_DETAIL"
}

health_managed_permissions_are_healthy() {
  local specification path expected actual token suffix tokens
  for specification in \
    "$SETTINGS_FILE|600:root:root" \
    "$SECRETS_FILE|600:root:root" \
    "$CLIENTS_FILE|600:root:root" \
    "$CONFIG_FILE|640:root:sing-box" \
    "${CERT_DIR}/fullchain.pem|640:root:sing-box" \
    "${CERT_DIR}/privkey.pem|640:root:sing-box"; do
    path="${specification%%|*}"
    expected="${specification#*|}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    actual="$(stat -c '%a:%U:%G' "$path" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] || return 1
  done
  [[ -d "$SUBSCRIPTION_ROOT" && ! -L "$SUBSCRIPTION_ROOT" ]] || return 1
  actual="$(stat -c '%a:%U:%G' "$SUBSCRIPTION_ROOT" 2>/dev/null || true)"
  [[ "$actual" == '750:root:www-data' ]] || return 1
  tokens="$(jq -r '.clients[].subscription_token' "$CLIENTS_FILE" 2>/dev/null)" || return 1
  [[ -n "$tokens" ]] || return 1
  while IFS= read -r token; do
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    for suffix in links mihomo; do
      path="${SUBSCRIPTION_ROOT}/${token}.${suffix}"
      [[ -f "$path" && ! -L "$path" ]] || return 1
      actual="$(stat -c '%a:%U:%G' "$path" 2>/dev/null || true)"
      [[ "$actual" == '640:root:www-data' ]] || return 1
    done
  done <<<"$tokens"
}

health_collect_system() {
  local uptime_seconds ram_total ram_used swap_total swap_used disk_total disk_used ntp
  HEALTH_OS="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
  HEALTH_OS="${HEALTH_OS:-unknown}"
  HEALTH_KERNEL="$(uname -r 2>/dev/null || printf unknown)"
  uptime_seconds="$(cut -d ' ' -f 1 /proc/uptime 2>/dev/null || true)"
  if [[ "${uptime_seconds%%.*}" =~ ^[0-9]+$ ]]; then
    HEALTH_UPTIME_SECONDS="${uptime_seconds%%.*}"
  fi
  HEALTH_UPTIME="$(health_format_uptime "$uptime_seconds")"
  ram_total="$(free -b 2>/dev/null | awk '/^Mem:/ {print $2; exit}')"
  ram_used="$(free -b 2>/dev/null | awk '/^Mem:/ {print $3; exit}')"
  swap_total="$(free -b 2>/dev/null | awk '/^Swap:/ {print $2; exit}')"
  swap_used="$(free -b 2>/dev/null | awk '/^Swap:/ {print $3; exit}')"
  disk_total="$(df -B1 / 2>/dev/null | awk 'NR == 2 {print $2}')"
  disk_used="$(df -B1 / 2>/dev/null | awk 'NR == 2 {print $3}')"
  if [[ "$ram_total" =~ ^[0-9]+$ && "$ram_used" =~ ^[0-9]+$ &&
        "$disk_total" =~ ^[0-9]+$ && "$disk_used" =~ ^[0-9]+$ ]]; then
    HEALTH_RESOURCES="RAM $(health_human_size "$ram_used")/$(health_human_size "$ram_total")"
    HEALTH_RESOURCES+=" · disk $(health_human_size "$disk_used")/$(health_human_size "$disk_total")"
    if [[ "$swap_total" =~ ^[0-9]+$ && "$swap_used" =~ ^[0-9]+$ ]]; then
      HEALTH_RESOURCES+=" · swap $(health_human_size "$swap_used")/$(health_human_size "$swap_total")"
    fi
  fi
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  health_classify_ntp_state "$ntp" "$HEALTH_UPTIME_SECONDS"
}

health_classify_ntp_state() {
  local ntp_state="$1" uptime_seconds="$2"
  if [[ "$ntp_state" == yes ]]; then
    HEALTH_CLOCK_STATE=PASS
    HEALTH_CLOCK_DETAIL='NTP synchronized'
  elif [[ "$ntp_state" == no && "$uptime_seconds" =~ ^[0-9]+$ ]] &&
       (( uptime_seconds < NTP_BOOT_GRACE_SECONDS )); then
    HEALTH_CLOCK_STATE=PENDING
    HEALTH_CLOCK_DETAIL='waiting for NTP synchronization'
  elif [[ "$ntp_state" == no ]]; then
    HEALTH_CLOCK_STATE=WARN
    HEALTH_CLOCK_DETAIL='NTP not synchronized'
  else
    HEALTH_CLOCK_STATE=WARN
    HEALTH_CLOCK_DETAIL='NTP state unknown'
  fi
}

health_collect_network() {
  local qdisc_output
  HEALTH_CONGESTION="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  if [[ "$HEALTH_CONGESTION" == bbr ]]; then
    HEALTH_CONGESTION_STATE=PASS
  else
    HEALTH_CONGESTION_STATE=WARN
  fi
  HEALTH_CONFIGURED_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
  HEALTH_DEFAULT_INTERFACE="$(ip -4 route show default 2>/dev/null | awk '
    !found {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && (i + 1) <= NF) {
          print $(i + 1)
          found=1
        }
      }
    }
  ')"
  if [[ -n "$HEALTH_DEFAULT_INTERFACE" ]]; then
    qdisc_output="$(tc qdisc show dev "$HEALTH_DEFAULT_INTERFACE" 2>/dev/null || true)"
    HEALTH_ACTIVE_QDISC="$(awk '$1 == "qdisc" && $0 ~ / root([[:space:]]|$)/ {print $2; exit}' <<<"$qdisc_output")"
    HEALTH_ACTIVE_QDISC="${HEALTH_ACTIVE_QDISC:-unknown}"
  fi
  if [[ "$HEALTH_CONFIGURED_QDISC" == fq && "$HEALTH_ACTIVE_QDISC" == fq ]]; then
    HEALTH_QUEUE_STATE=PASS
    HEALTH_QUEUE_DETAIL='active fq'
  elif [[ "$HEALTH_CONFIGURED_QDISC" == fq && "$HEALTH_ACTIVE_QDISC" == fq_codel ]]; then
    HEALTH_QUEUE_STATE=INFO
    HEALTH_QUEUE_DETAIL='active fq_codel · fq configured for next interface recreation'
  elif [[ "$HEALTH_CONFIGURED_QDISC" == fq ]]; then
    HEALTH_QUEUE_STATE=INFO
    HEALTH_QUEUE_DETAIL="active $HEALTH_ACTIVE_QDISC · configured default fq"
  else
    HEALTH_QUEUE_STATE=WARN
    HEALTH_QUEUE_DETAIL="active $HEALTH_ACTIVE_QDISC · configured default $HEALTH_CONFIGURED_QDISC"
  fi
}

health_collect_certificate() {
  local expiry_line expiry_value expiry_epoch now_epoch days_remaining
  local timer_enabled timer_active hook_ok=0 renewal_ok=0 sync_ok=0
  if [[ ! -r "${CERT_DIR}/fullchain.pem" ]]; then
    HEALTH_CERT_DETAIL='certificate copy missing'
    return
  fi
  if ! openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
    HEALTH_CERT_DETAIL='certificate expired or invalid'
    return
  fi
  expiry_line="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null || true)"
  expiry_value="${expiry_line#notAfter=}"
  expiry_epoch="$(date -d "$expiry_value" +%s 2>/dev/null || true)"
  now_epoch="$(date +%s)"
  if [[ "$expiry_epoch" =~ ^[0-9]+$ ]]; then
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
    health_classify_certificate_expiry "$expiry_epoch" "$days_remaining"
  else
    HEALTH_CERT_STATE=PASS
    HEALTH_CERT_DETAIL='valid; expiry date unavailable'
  fi
  if openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkhost "$TLS_DOMAIN" >/dev/null 2>&1; then
    HEALTH_CERT_HOSTNAME_STATE=PASS
  fi
  if certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"; then
    HEALTH_CERT_KEYPAIR_STATE=PASS
  fi

  timer_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  timer_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
  if [[ "$timer_enabled" == enabled && "$timer_active" == active ]]; then
    renewal_ok=1
  fi
  if [[ -f "$CERT_HOOK" && -x "$CERT_HOOK" ]] && sh -n "$CERT_HOOK" >/dev/null 2>&1; then
    hook_ok=1
  fi
  if [[ -r "/etc/letsencrypt/renewal/${TLS_DOMAIN}.conf" &&
        -r "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" &&
        -r "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" &&
        -r "${CERT_DIR}/privkey.pem" ]] &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" "${CERT_DIR}/fullchain.pem" &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" "${CERT_DIR}/privkey.pem"; then
    sync_ok=1
  fi
  if (( renewal_ok == 1 && hook_ok == 1 && sync_ok == 1 )); then
    HEALTH_RENEWAL_STATE=PASS
    HEALTH_RENEWAL_DETAIL='certbot timer · deploy hook · deployed cert synced'
  else
    HEALTH_RENEWAL_DETAIL="timer $([[ $renewal_ok == 1 ]] && printf PASS || printf FAIL)"
    HEALTH_RENEWAL_DETAIL+=" · hook $([[ $hook_ok == 1 ]] && printf PASS || printf FAIL)"
    HEALTH_RENEWAL_DETAIL+=" · sync $([[ $sync_ok == 1 ]] && printf PASS || printf FAIL)"
  fi
}

health_classify_certificate_expiry() {
  local expiry_epoch="$1" days_remaining="$2" day_word=days expiry_date
  if (( days_remaining == 1 )); then
    day_word=day
  fi
  expiry_date="$(date -d "@$expiry_epoch" +%F 2>/dev/null || date -r "$expiry_epoch" +%F 2>/dev/null || printf unknown)"
  HEALTH_CERT_DETAIL="expires ${expiry_date} (${days_remaining} ${day_word})"
  if (( days_remaining < 7 )); then
    HEALTH_CERT_STATE=WARN
  else
    HEALTH_CERT_STATE=PASS
  fi
}

health_generated_timestamp() {
  date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

health_dns_matches() {
  local expected="$1" first_answers="$2" second_answers="$3"
  grep -Fxq "$expected" <<<"$first_answers" || return 1
  grep -Fxq "$expected" <<<"$second_answers"
}

health_reality_target_is_healthy() {
  local probe_file status=0
  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    new_temp_dir
  fi
  probe_file="$(mktemp "${TMP_DIR}/health-reality.XXXXXX")"
  chmod 0600 "$probe_file"
  if timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" \
      -servername "$REALITY_TARGET" -verify_hostname "$REALITY_TARGET" \
      -tls1_3 -alpn h2 -verify_return_error </dev/null >"$probe_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  (( status == 0 )) || return 1
  LC_ALL=C grep -aEiq \
    'New,[[:space:]]*TLSv1\.3|Protocol( version)?[[:space:]]*:[[:space:]]*TLSv1\.3' \
    "$probe_file" || return 1
  LC_ALL=C grep -aEiq \
    'Verify return code:[[:space:]]*0[[:space:]]*\(ok\)|Verification:[[:space:]]*OK' \
    "$probe_file" || return 1
  LC_ALL=C grep -aEiq 'ALPN protocol:[[:space:]]*h2' "$probe_file"
}

health_write_bounded_redacted_file() {
  local input="$1" output="$2" max_entries="$3" max_bytes="$4"
  local redacted_file selected_file
  redacted_file="$(mktemp "${TMP_DIR}/health-redacted.XXXXXX")"
  selected_file="$(mktemp "${TMP_DIR}/health-selected.XXXXXX")"
  chmod 0600 "$redacted_file" "$selected_file"
  redact_health_stream <"$input" >"$redacted_file"
  tail -n "$max_entries" "$redacted_file" >"$selected_file"
  LC_ALL=C awk -v limit="$max_bytes" '
    { lines[NR]=$0; sizes[NR]=length($0) + 1 }
    END {
      start=NR + 1
      for (i=NR; i>=1; i--) {
        if (used + sizes[i] > limit) break
        used += sizes[i]
        start=i
      }
      for (i=start; i<=NR; i++) print lines[i]
    }
  ' "$selected_file" >"$output"
}

health_count_unique_reality_noise_sources() {
  local input="$1" sources_file
  sources_file="$(mktemp "${TMP_DIR}/health-noise-sources.XXXXXX")"
  chmod 0600 "$sources_file"
  sed -nE \
    -e 's/.*[Ff]rom[[:space:]]+\[([0-9a-fA-F:]+)\]:[0-9]+.*/\1/p' \
    -e 's/.*[Ff]rom[[:space:]]+(([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]+.*/\1/p' \
    "$input" >"$sources_file"
  sort -u "$sources_file" | awk 'END {print NR + 0}'
}

health_collect_recent_errors() {
  local raw_file actionable_raw noise_raw
  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    new_temp_dir
  fi
  raw_file="$(mktemp "${TMP_DIR}/health-journal.raw.XXXXXX")"
  actionable_raw="$(mktemp "${TMP_DIR}/health-actionable.raw.XXXXXX")"
  noise_raw="$(mktemp "${TMP_DIR}/health-reality-noise.raw.XXXXXX")"
  HEALTH_RECENT_ERRORS_FILE="$(mktemp "${TMP_DIR}/health-journal.redacted.XXXXXX")"
  HEALTH_DEBUG_ACTIONABLE_FILE="$(mktemp "${TMP_DIR}/health-actionable-debug.XXXXXX")"
  HEALTH_REALITY_NOISE_SAMPLES_FILE="$(mktemp "${TMP_DIR}/health-noise-samples.XXXXXX")"
  chmod 0600 "$raw_file" "$actionable_raw" "$noise_raw" \
    "$HEALTH_RECENT_ERRORS_FILE" "$HEALTH_DEBUG_ACTIONABLE_FILE" \
    "$HEALTH_REALITY_NOISE_SAMPLES_FILE"
  journalctl -u sing-box.service --since '-30 minutes' -p warning..alert -n 500 \
    --no-pager --output=short-iso >"$raw_file" 2>/dev/null || true
  awk '
    /^-- No entries --$/ || /^-- Boot / || /^$/ { next }
    index($0, "REALITY: processed invalid connection") { print > noise; next }
    { print > actionable }
  ' actionable="$actionable_raw" noise="$noise_raw" "$raw_file"
  HEALTH_REALITY_NOISE_COUNT="$(grep -cF 'REALITY: processed invalid connection' "$noise_raw" || true)"
  HEALTH_REALITY_NOISE_UNIQUE_SOURCES="$(health_count_unique_reality_noise_sources "$noise_raw")"
  health_write_bounded_redacted_file "$actionable_raw" "$HEALTH_RECENT_ERRORS_FILE" 5 8192
  health_write_bounded_redacted_file "$actionable_raw" "$HEALTH_DEBUG_ACTIONABLE_FILE" 20 12288
  health_write_bounded_redacted_file "$noise_raw" "$HEALTH_REALITY_NOISE_SAMPLES_FILE" 5 4096
  if [[ -s "$HEALTH_RECENT_ERRORS_FILE" ]]; then
    HEALTH_RECENT_ERRORS_STATE=WARN
  fi
}

health_collect_update_policy() {
  local effective_dump host_os_id="${1:-}"
  if [[ -z "$host_os_id" ]]; then
    host_os_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
  fi
  effective_dump="$(apt-config dump 2>/dev/null || true)"
  if [[ -z "$effective_dump" ]]; then
    HEALTH_SECURITY_UPDATES_DETAIL='effective APT configuration unavailable'
  elif ! unattended_policy_dump_is_security_only "$host_os_id" "$effective_dump"; then
    HEALTH_SECURITY_UPDATES_DETAIL="$UNATTENDED_POLICY_REASON"
  elif ! systemctl is-enabled --quiet apt-daily.timer 2>/dev/null ||
       ! systemctl is-active --quiet apt-daily.timer 2>/dev/null; then
    HEALTH_SECURITY_UPDATES_DETAIL='apt-daily.timer is disabled or inactive'
  elif ! systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null ||
       ! systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
    HEALTH_SECURITY_UPDATES_DETAIL='apt-daily-upgrade.timer is disabled or inactive'
  else
    HEALTH_SECURITY_UPDATES_STATE=PASS
    HEALTH_SECURITY_UPDATES_DETAIL='automatic · security-only · no automatic reboot'
  fi

  if apt-mark showhold 2>/dev/null | grep -Fxq sing-box; then
    HEALTH_CORE_UPDATES_STATE=PASS
    HEALTH_CORE_UPDATES_DETAIL='sing-box apt-held · update through vpn update'
  fi
}

health_collect_state() {
  local dns_one dns_two vless_config=0 hy2_config=0
  health_reset_state
  HEALTH_CORE_VERSION="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || printf missing)"
  HEALTH_RUNTIME_VERSION="$(cat "$RUNTIME_VERSION_FILE" 2>/dev/null || printf missing)"
  if sing_box_version_is_supported "$HEALTH_CORE_VERSION"; then
    HEALTH_VERSION_STATE=PASS
  fi
  if [[ "$HEALTH_RUNTIME_VERSION" == "$SCRIPT_VERSION" ]]; then
    HEALTH_RUNTIME_STATE=PASS
  fi
  if systemctl is-active --quiet sing-box.service; then
    HEALTH_SERVICE_STATE=PASS
  fi
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    HEALTH_CONFIG_STATE=PASS
  fi
  if [[ "$HEALTH_RUNTIME_STATE" != PASS || "$HEALTH_VERSION_STATE" != PASS ]] ||
     [[ "$HEALTH_SERVICE_STATE" != PASS || "$HEALTH_CONFIG_STATE" != PASS ]]; then
    HEALTH_CORE_STATE=FAIL
  fi

  HEALTH_CLIENT_COUNT="$(jq -r '.clients | length' "$CLIENTS_FILE" 2>/dev/null || printf unknown)"
  [[ "$HEALTH_CLIENT_COUNT" =~ ^[0-9]+$ ]] || HEALTH_CLIENT_COUNT=unknown
  HEALTH_VLESS_CLIENTS="$(jq -r '[.inbounds[] | select(.type == "vless" and .listen_port == 443 and .tls.enabled == true and .tls.reality.enabled == true) | .users | length] | first // 0' "$CONFIG_FILE" 2>/dev/null || printf 0)"
  HEALTH_HY2_CLIENTS="$(jq -r '[.inbounds[] | select(.type == "hysteria2" and .listen_port == 443 and .tls.enabled == true) | .users | length] | first // 0' "$CONFIG_FILE" 2>/dev/null || printf 0)"
  if [[ "$HEALTH_VLESS_CLIENTS" =~ ^[1-9][0-9]*$ ]]; then
    vless_config=1
  fi
  if [[ "$HEALTH_HY2_CLIENTS" =~ ^[1-9][0-9]*$ ]]; then
    hy2_config=1
  fi

  health_collect_listeners
  if (( vless_config == 1 )) && [[ "$HEALTH_TCP443_STATE" == PASS ]]; then
    HEALTH_VLESS_STATE=PASS
  fi
  if (( hy2_config == 1 )) && [[ "$HEALTH_UDP443_STATE" == PASS ]]; then
    HEALTH_HY2_STATE=PASS
  fi
  if subscription_service_healthy && [[ "$HEALTH_TCP8443_STATE" == PASS ]]; then
    HEALTH_SUBSCRIPTION_STATE=PASS
    HEALTH_SUBSCRIPTION_DETAIL="tcp/${SUBSCRIPTION_PORT} · $(health_client_label "$HEALTH_CLIENT_COUNT")"
  elif [[ "$HEALTH_TCP8443_STATE" != PASS ]]; then
    HEALTH_SUBSCRIPTION_DETAIL="tcp/${SUBSCRIPTION_PORT} · $HEALTH_TCP8443_DETAIL"
  fi

  dns_one="$(timeout 5 dig +time=3 +tries=1 +short A "$TLS_DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)"
  dns_two="$(timeout 5 dig +time=3 +tries=1 +short A "$TLS_DOMAIN" @8.8.8.8 2>/dev/null | sed '/^$/d' || true)"
  if health_dns_matches "$SERVER_IPV4" "$dns_one" "$dns_two"; then
    HEALTH_DNS_STATE=PASS
  fi
  health_collect_certificate
  if health_reality_target_is_healthy; then HEALTH_TARGET_STATE=PASS; fi
  if managed_firewall_is_healthy; then HEALTH_FIREWALL_STATE=PASS; fi
  if ssh_lockdown_is_effective; then HEALTH_SSH_STATE=PASS; fi
  if health_managed_permissions_are_healthy; then HEALTH_PERMISSIONS_STATE=PASS; fi
  health_collect_network
  health_collect_system
  health_collect_recent_errors
  health_collect_update_policy "$OS_ID"
  health_recalculate_result
}

health_recalculate_result() {
  local state
  HEALTH_FAILURES=0
  HEALTH_WARNINGS=0
  for state in \
    "$HEALTH_CORE_STATE" "$HEALTH_VERSION_STATE" "$HEALTH_RUNTIME_STATE" \
    "$HEALTH_CORE_UPDATES_STATE" "$HEALTH_SECURITY_UPDATES_STATE" \
    "$HEALTH_VLESS_STATE" "$HEALTH_HY2_STATE" \
    "$HEALTH_SUBSCRIPTION_STATE" "$HEALTH_DNS_STATE" "$HEALTH_CERT_STATE" \
    "$HEALTH_CERT_HOSTNAME_STATE" "$HEALTH_CERT_KEYPAIR_STATE" "$HEALTH_RENEWAL_STATE" \
    "$HEALTH_TARGET_STATE" "$HEALTH_FIREWALL_STATE" "$HEALTH_SSH_STATE" \
    "$HEALTH_PERMISSIONS_STATE" "$HEALTH_TCP443_STATE" "$HEALTH_UDP443_STATE" \
    "$HEALTH_TCP8443_STATE" "$HEALTH_SSH_LISTENER_STATE" "$HEALTH_CONGESTION_STATE" \
    "$HEALTH_QUEUE_STATE" "$HEALTH_CLOCK_STATE" "$HEALTH_RECENT_ERRORS_STATE"; do
    case "$state" in
      FAIL) (( HEALTH_FAILURES += 1 )) ;;
      WARN) (( HEALTH_WARNINGS += 1 )) ;;
    esac
  done
}

health_result_line() {
  printf 'Result: '
  if (( HEALTH_FAILURES > 0 )); then
    print_status_value UNHEALTHY
  elif (( HEALTH_WARNINGS > 0 )); then
    print_status_value HEALTHY
    printf ' (warnings)'
  else
    print_status_value HEALTHY
  fi
  printf '\n'
}

health_network_detail() {
  local detail="$HEALTH_CONGESTION · $HEALTH_ACTIVE_QDISC"
  if [[ "$HEALTH_ACTIVE_QDISC" != "$HEALTH_CONFIGURED_QDISC" ]]; then
    detail+=" (configured $HEALTH_CONFIGURED_QDISC)"
  fi
  printf '%s\n' "$detail"
}

render_health_short() {
  local core_state protocol_state tls_state security_state network_state
  core_state="$(health_join_states "$HEALTH_CORE_STATE" "$HEALTH_CORE_UPDATES_STATE")"
  protocol_state="$(health_join_states "$HEALTH_VLESS_STATE" "$HEALTH_HY2_STATE")"
  tls_state="$(health_join_states "$HEALTH_DNS_STATE" "$HEALTH_CERT_STATE" \
    "$HEALTH_CERT_HOSTNAME_STATE" "$HEALTH_CERT_KEYPAIR_STATE" "$HEALTH_RENEWAL_STATE")"
  security_state="$(health_join_states "$HEALTH_FIREWALL_STATE" "$HEALTH_SSH_STATE" \
    "$HEALTH_PERMISSIONS_STATE" "$HEALTH_SECURITY_UPDATES_STATE")"
  network_state="$(health_join_states "$HEALTH_CONGESTION_STATE" "$HEALTH_QUEUE_STATE")"
  print_title 'VPN health'
  health_print_row Core "$core_state" "sing-box $HEALTH_CORE_VERSION"
  health_print_row Protocols "$protocol_state" 'REALITY tcp/443 · Hysteria2 udp/443'
  health_print_row Subscription "$HEALTH_SUBSCRIPTION_STATE" "$(health_client_label "$HEALTH_CLIENT_COUNT")"
  health_print_row DNS/TLS "$tls_state" 'configured · DNS/certificate checked'
  health_print_row 'REALITY target' "$HEALTH_TARGET_STATE" \
    'TLS 1.3 · certificate/SNI · ALPN h2'
  health_print_row Security "$security_state" 'nftables · SSH key-only · permissions'
  health_print_row Network "$network_state" "$(health_network_detail)"
  printf '\n'
  health_result_line
}

render_health_verbose() {
  local certificate_detail
  certificate_detail="$HEALTH_CERT_DETAIL"
  if [[ "$HEALTH_CERT_HOSTNAME_STATE" == PASS && "$HEALTH_CERT_KEYPAIR_STATE" == PASS ]]; then
    certificate_detail+=' · hostname · key pair'
  fi

  print_title 'VPN health'
  health_result_line
  print_section 'SYSTEM'
  health_print_info OS "$HEALTH_OS · Linux $HEALTH_KERNEL"
  health_print_info Uptime "$HEALTH_UPTIME"
  health_print_info Resources "$HEALTH_RESOURCES"
  health_print_row Clock "$HEALTH_CLOCK_STATE" "$HEALTH_CLOCK_DETAIL"

  print_section 'VPN'
  if [[ "$HEALTH_SERVICE_STATE" == PASS ]]; then
    health_print_row sing-box "$(health_join_states "$HEALTH_SERVICE_STATE" "$HEALTH_VERSION_STATE")" \
      "$HEALTH_CORE_VERSION · active"
  else
    health_print_row sing-box "$(health_join_states "$HEALTH_SERVICE_STATE" "$HEALTH_VERSION_STATE")" \
      "$HEALTH_CORE_VERSION · inactive"
  fi
  health_print_row Config "$HEALTH_CONFIG_STATE" 'sing-box configuration validation'
  health_print_row Runtime "$HEALTH_RUNTIME_STATE" \
    "installer $SCRIPT_VERSION · managed $HEALTH_RUNTIME_VERSION"
  health_print_row 'VLESS REALITY' "$HEALTH_VLESS_STATE" "tcp/443 · $(health_client_label "$HEALTH_VLESS_CLIENTS")"
  health_print_row Hysteria2 "$HEALTH_HY2_STATE" "udp/443 · $(health_client_label "$HEALTH_HY2_CLIENTS")"
  health_print_row Subscription "$HEALTH_SUBSCRIPTION_STATE" "$HEALTH_SUBSCRIPTION_DETAIL"
  health_print_row 'REALITY target' "$HEALTH_TARGET_STATE" '[DOMAIN-REDACTED] · TLS 1.3/h2'
  health_print_info Fingerprint "$CLIENT_FINGERPRINT"
  health_print_info 'HY2 obfs' "$HY2_OBFS_MODE"

  print_section 'NETWORK'
  if [[ "$HEALTH_DNS_STATE" == PASS ]]; then
    health_print_row 'Public IPv4' PASS 'configured · DNS matches'
  else
    health_print_row 'Public IPv4' FAIL 'configured · DNS mismatch'
  fi
  health_print_row TCP/443 "$HEALTH_TCP443_STATE" "$HEALTH_TCP443_DETAIL"
  health_print_row UDP/443 "$HEALTH_UDP443_STATE" "$HEALTH_UDP443_DETAIL"
  health_print_row TCP/8443 "$HEALTH_TCP8443_STATE" "$HEALTH_TCP8443_DETAIL"
  health_print_row Congestion "$HEALTH_CONGESTION_STATE" "kernel default $HEALTH_CONGESTION"
  health_print_row Queue "$HEALTH_QUEUE_STATE" "$HEALTH_QUEUE_DETAIL"

  print_section 'TLS'
  health_print_row Certificate "$HEALTH_CERT_STATE" "$certificate_detail"
  [[ "$HEALTH_CERT_HOSTNAME_STATE" == PASS ]] || health_print_row Hostname FAIL 'certificate does not match configured domain'
  [[ "$HEALTH_CERT_KEYPAIR_STATE" == PASS ]] || health_print_row 'Key pair' FAIL 'certificate and private key do not match'
  health_print_row Renewal "$HEALTH_RENEWAL_STATE" "$HEALTH_RENEWAL_DETAIL"

  print_section 'SECURITY'
  health_print_row nftables "$HEALTH_FIREWALL_STATE" 'managed vpn_filter policy'
  health_print_row SSH "$HEALTH_SSH_STATE" 'key-only policy'
  health_print_row 'SSH listener' "$HEALTH_SSH_LISTENER_STATE" "tcp/$SSH_PORT · $HEALTH_SSH_LISTENER_DETAIL"
  health_print_row Permissions "$HEALTH_PERMISSIONS_STATE" 'managed files'
  health_print_row 'Security updates' "$HEALTH_SECURITY_UPDATES_STATE" \
    "$HEALTH_SECURITY_UPDATES_DETAIL"
  health_print_row 'Core updates' "$HEALTH_CORE_UPDATES_STATE" "$HEALTH_CORE_UPDATES_DETAIL"

  print_section 'RECENT ACTIONABLE ERRORS'
  if [[ "$HEALTH_RECENT_ERRORS_STATE" == PASS ]]; then
    printf '  None\n'
  else
    sed -n '1,5p' "$HEALTH_RECENT_ERRORS_FILE"
  fi
  printf '\nVersions: installer %s · runtime %s\n' "$SCRIPT_VERSION" "$HEALTH_RUNTIME_VERSION"
  printf 'Generated: %s\n' "$(health_generated_timestamp)"
  printf 'Sensitive values are redacted.\n'
}

render_health_debug_details() {
  local active_congestion
  print_section 'DEVELOPMENT DETAILS'
  printf 'Relevant sysctl:\n'
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
    net.core.rmem_max net.core.wmem_max 2>/dev/null || true
  printf '\nActive congestion samples (bounded):\n'
  active_congestion="$(ss -H -tin 2>/dev/null | grep -Eio 'bbr|cubic|reno' | sort -u | paste -sd, - || true)"
  printf '  %s\n' "${active_congestion:-no identifiable active TCP samples}"
  printf '\nListener dump (bounded):\n'
  ss -H -lntup 2>/dev/null | sed -n '1,80p' || true
  if [[ -n "$HEALTH_DEFAULT_INTERFACE" ]]; then
    printf '\nActive qdisc for default interface:\n'
    tc -s qdisc show dev "$HEALTH_DEFAULT_INTERFACE" 2>/dev/null | sed -n '1,80p' || true
    printf '\nDefault interface counters:\n'
    ip -s link show dev "$HEALTH_DEFAULT_INTERFACE" 2>/dev/null | sed -n '1,80p' || true
  fi
  printf '\nCertificate timestamps:\n'
  openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -dates 2>/dev/null || true
  printf '\nSystemd state:\n'
  systemctl show sing-box.service nginx.service nftables.service certbot.timer ssh.service \
    -p Id -p LoadState -p ActiveState -p SubState --no-pager 2>/dev/null | sed -n '1,100p' || true
  print_section 'ACTIONABLE ERROR DETAILS'
  if [[ -s "$HEALTH_DEBUG_ACTIONABLE_FILE" ]]; then
    sed -n '1,20p' "$HEALTH_DEBUG_ACTIONABLE_FILE"
  else
    printf '  None\n'
  fi
  print_section 'IGNORED INBOUND NOISE'
  printf '  Invalid REALITY handshakes (30 min): %s\n' "$HEALTH_REALITY_NOISE_COUNT"
  printf '  Unique source addresses (30 min): %s\n' "$HEALTH_REALITY_NOISE_UNIQUE_SOURCES"
  if [[ -s "$HEALTH_REALITY_NOISE_SAMPLES_FILE" ]]; then
    printf '  Redacted samples (bounded):\n'
    sed -n '1,5p' "$HEALTH_REALITY_NOISE_SAMPLES_FILE"
  fi
}

health_details() {
  local health_status=0
  require_root
  health_collect_state
  (( HEALTH_FAILURES == 0 )) || health_status=1
  render_health_verbose | redact_health_stream
  return "$health_status"
}

health_debug() {
  local health_status=0
  require_root
  health_collect_state
  (( HEALTH_FAILURES == 0 )) || health_status=1
  {
    render_health_verbose
    render_health_debug_details
  } | redact_health_stream
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
  local health_status=0
  require_root
  health_collect_state
  (( HEALTH_FAILURES == 0 )) || health_status=1
  render_health_short
  return "$health_status"
}
