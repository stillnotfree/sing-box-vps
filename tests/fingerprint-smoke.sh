#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2016

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

[[ "$SCRIPT_VERSION" == "1.0.10" ]]
[[ "$SING_BOX_MIN_VERSION" == "1.13.0" ]]
[[ "$SING_BOX_MAX_EXCLUSIVE" == "1.14.0" ]]
(( ${#SUPPORTED_CLIENT_FINGERPRINTS[@]} == 9 ))
(( ${#SUPPORTED_HY2_OBFS_MODES[@]} == 2 ))

package_list="$(printf ' %s' "${BASE_PACKAGES[@]}")"
for package in \
  apt ca-certificates curl jq openssl nftables sudo certbot dnsutils qrencode \
  nginx-light unattended-upgrades openssh-client openssh-server iproute2 procps \
  kmod util-linux gpg
do
  [[ "${package_list} " == *" ${package} "* ]]
done

(
  package_capture="$(mktemp)"
  apt-get() {
    if [[ "$1" == "install" ]]; then
      shift
      printf '%s\n' "$@" >"$package_capture"
    fi
  }
  systemctl() { return 0; }
  install_base_packages >/dev/null
  grep -Fxq -- '--no-install-recommends' "$package_capture"
  grep -Fxq util-linux "$package_capture"
  grep -Fxq jq "$package_capture"
  grep -Fxq gpg "$package_capture"
  rm -f -- "$package_capture"
)

# Invalid interactive values must remain in the same prompt instead of
# aborting a fresh installation. interactive_stdin is an intentional test seam.
(
  interactive_stdin() { return 0; }
  ADMIN_USER=""
  prompt_value ADMIN_USER '[Step 1 / 10] Administrative user' 'vpnadmin' \
    admin_user_is_valid <<< $'Root!\nvpnadmin'
  [[ "$ADMIN_USER" == "vpnadmin" ]]

  SERVER_IPV4=""
  prompt_value SERVER_IPV4 '[Step 3 / 10] Public VPS IPv4' '' ipv4_is_valid \
    <<< $'999.1.2.3\n203.0.113.10'
  [[ "$SERVER_IPV4" == "203.0.113.10" ]]

  ACME_EMAIL=""
  prompt_value ACME_EMAIL '[Step 5 / 10] ACME email' '' email_is_valid \
    <<< $'admin@example.com\nadmin@vpn-mail.net'
  [[ "$ACME_EMAIL" == "admin@vpn-mail.net" ]]

  test_fingerprint=""
  select_client_fingerprint test_fingerprint <<< $'invalid\n  FIREFOX  '
  [[ "$test_fingerprint" == "firefox" ]]
)

validate_emoji "🇩🇪"
if (validate_emoji $'\033[31m' >/dev/null 2>&1); then
  printf 'Terminal control characters unexpectedly passed emoji validation.\n' >&2
  exit 1
fi

parse_args set-fingerprint firefox --yes
[[ "$COMMAND" == "set-fingerprint" ]]
[[ "$NEW_CLIENT_FINGERPRINT" == "firefox" ]]
(( ASSUME_YES == 1 ))

(
  COMMAND="plan"
  CLIENT_NAME=""
  parse_args show
  [[ "$COMMAND" == "client-list" ]]
  [[ -z "$CLIENT_NAME" ]]
)

(
  COMMAND="plan"
  CLIENT_NAME=""
  parse_args show WorkPC
  [[ "$COMMAND" == "client-show" ]]
  [[ "$CLIENT_NAME" == "WorkPC" ]]
)

trap - ERR
if unknown_output="$(bash "$repo_root/install-sing-box-server.sh" unsupported-command 2>&1)"; then
  printf 'An unsupported command unexpectedly remains accepted.\n' >&2
  exit 1
fi
trap on_error ERR
grep -Fq 'Unknown command: unsupported-command' <<<"$unknown_output"
if grep -Fq 'VPN settings are unavailable' <<<"$unknown_output"; then
  printf 'Unknown commands are validated only after loading managed state.\n' >&2
  exit 1
fi

(
  COMMAND="plan"
  AUDIT_TARGET=""
  parse_args audit-target cdn.example.com
  [[ "$COMMAND" == "audit-target" ]]
  [[ "$AUDIT_TARGET" == "cdn.example.com" ]]
)

# The audit parser receives only a filtered text representation of the raw
# OpenSSL file. These fixtures cover its public states and exit statuses.
(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="no-tickets.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verify return code: 0 (ok)' \
      'ALPN protocol: h2' >"$2"
  }
  audit_output="$(audit_reality_target 2>&1)"
  grep -Fq 'TLS 1.3: PASS' <<<"$audit_output"
  grep -Fq 'Certificate/SNI: PASS' <<<"$audit_output"
  grep -Fq 'ALPN h2: PASS' <<<"$audit_output"
  grep -Fq 'Post-handshake NewSessionTicket: 0' <<<"$audit_output"
  grep -Fq 'Comparison signal: NOT OBSERVED' <<<"$audit_output"
  grep -Fq 'Result: PASS — preferred' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="one-ticket.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verify return code: 0 (ok)' \
      'ALPN protocol: h2' \
      '<<< TLS 1.3, Handshake, NewSessionTicket' >"$2"
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 1 ))
  grep -Fq 'Post-handshake NewSessionTicket: 1' <<<"$audit_output"
  grep -Fq 'Comparison signal: OBSERVED' <<<"$audit_output"
  grep -Fq 'Result: WARN — target is usable, but 1 post-handshake ticket was observed.' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="two-tickets.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verify return code: 0 (ok)' \
      'ALPN protocol: h2' \
      '<<< TLS 1.3, Handshake, NewSessionTicket' \
      '<<< TLS 1.3, Handshake, NewSessionTicket' >"$2"
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 1 ))
  grep -Fq 'Post-handshake NewSessionTicket: 2' <<<"$audit_output"
  grep -Fq 'Result: WARN — target is usable, but 2 post-handshake tickets were observed.' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="no-alpn.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'SSL3 alert read:fatal:no application protocol' >"$2"
    return 1
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 2 ))
  grep -Fq 'TLS 1.3: PASS' <<<"$audit_output"
  grep -Fq 'Certificate/SNI: UNKNOWN' <<<"$audit_output"
  grep -Fq 'ALPN h2: FAIL' <<<"$audit_output"
  grep -Fq 'Reason: server returned TLS alert "no application protocol"' <<<"$audit_output"
  grep -Fq 'Result: FAIL' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="old-tls.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' 'SSL3 alert read:fatal:protocol version' >"$2"
    return 1
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 2 ))
  grep -Fq 'TLS 1.3: FAIL' <<<"$audit_output"
  grep -Fq 'Certificate/SNI: UNKNOWN' <<<"$audit_output"
  grep -Fq 'ALPN h2: UNKNOWN' <<<"$audit_output"
  grep -Fq 'Reason: server returned TLS alert "protocol version"' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="bad-certificate.example.com"
  capture_reality_target_audit_probe() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verify return code: 20 (unable to get local issuer certificate)' \
      'certificate verify failed' \
      'ALPN protocol: h2' >"$2"
    return 1
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 2 ))
  grep -Fq 'TLS 1.3: PASS' <<<"$audit_output"
  grep -Fq 'Certificate/SNI: FAIL' <<<"$audit_output"
  grep -Fq 'ALPN h2: PASS' <<<"$audit_output"
  grep -Fq 'Reason: certificate chain is not trusted' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="timeout.example.com"
  capture_reality_target_audit_probe() {
    : >"$2"
    return 124
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 2 ))
  grep -Fq 'TLS 1.3: UNKNOWN' <<<"$audit_output"
  grep -Fq 'Certificate/SNI: UNKNOWN' <<<"$audit_output"
  grep -Fq 'ALPN h2: UNKNOWN' <<<"$audit_output"
  grep -Fq 'Reason: probe timed out after 12 seconds' <<<"$audit_output"
)

(
  trap - ERR
  require_command() { :; }
  VERBOSE=0
  AUDIT_TARGET="binary.example.com"
  capture_reality_target_audit_probe() {
    printf 'RAW-TRACE-SENTINEL\000ClientHello\n0000 - de ad be ef\nCertificate chain\n' >"$2"
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verify return code: 0 (ok)' \
      'ALPN protocol: h2' \
      '<<< TLS 1.3, Handshake, NewSessionTicket' >>"$2"
  }
  if audit_output="$(audit_reality_target 2>&1)"; then
    audit_status=0
  else
    audit_status=$?
  fi
  (( audit_status == 1 ))
  [[ "$audit_output" != *'ignored null byte'* ]]
  [[ "$audit_output" != *'RAW-TRACE-SENTINEL'* ]]
  [[ "$audit_output" != *'ClientHello'* ]]
  [[ "$audit_output" != *'0000 - de ad be ef'* ]]
  [[ "$audit_output" != *'Certificate chain'* ]]

  VERBOSE=1
  if verbose_output="$(audit_reality_target 2>&1)"; then
    verbose_status=0
  else
    verbose_status=$?
  fi
  (( verbose_status == 1 ))
  grep -Fq 'OpenSSL exit status: 0' <<<"$verbose_output"
  grep -Fq 'RAW-TRACE-SENTINEL' <<<"$verbose_output"
)

(
  interactive_stdin() { return 0; }
  audit_reality_target() {
    [[ "$REALITY_TARGET" == "safe.example.com" ]] && return 0
    return 1
  }
  ASSUME_YES=0
  REALITY_TARGET="tickets.example.com"
  REALITY_TARGET_AUDITED=0
  select_audited_reality_target_for_install <<< $'t\nsafe.example.com'
  [[ "$REALITY_TARGET" == "safe.example.com" ]]
  (( REALITY_TARGET_AUDITED == 1 ))
)

(
  interactive_stdin() { return 0; }
  audit_reality_target() { return 1; }
  ASSUME_YES=0
  REALITY_TARGET="reviewed.example.com"
  REALITY_TARGET_AUDITED=0
  select_audited_reality_target_for_install <<< $'\n'
  [[ "$REALITY_TARGET" == "reviewed.example.com" ]]
  (( REALITY_TARGET_AUDITED == 1 ))
)

(
  interactive_stdin() { return 0; }
  audit_reality_target() { return 1; }
  ASSUME_YES=0
  REALITY_TARGET="reviewed.example.com"
  REALITY_TARGET_AUDITED=0
  selection_file="$(mktemp)"
  select_audited_reality_target_for_install <<< $'?\nk' >"$selection_file" 2>&1
  selection_output="$(cat "$selection_file")"
  rm -f -- "$selection_file"
  grep -Fq '[K] Keep this target' <<<"$selection_output"
  grep -Fq '[T] Try another target' <<<"$selection_output"
  grep -Fq '[?] Details' <<<"$selection_output"
  grep -Fq '0 tickets is preferred only for this Aparecium-class comparison heuristic.' <<<"$selection_output"
  (( REALITY_TARGET_AUDITED == 1 ))
)

(
  interactive_stdin() { return 1; }
  audit_reality_target() { return 1; }
  ASSUME_YES=1
  REALITY_TARGET="reviewed.example.com"
  REALITY_TARGET_AUDITED=0
  select_audited_reality_target_for_install
  (( REALITY_TARGET_AUDITED == 1 ))
)

(
  COMMAND="plan"
  NEW_HY2_OBFS_MODE=""
  ASSUME_YES=0
  parse_args set-obfs salamander --yes
  [[ "$COMMAND" == "set-obfs" ]]
  [[ "$NEW_HY2_OBFS_MODE" == "salamander" ]]
  (( ASSUME_YES == 1 ))
)

(
  COMMAND="plan"
  ASSUME_YES=0
  parse_args finalize --yes
  [[ "$COMMAND" == "finalize" ]]
  (( ASSUME_YES == 1 ))
)

(
  COMMAND="plan"
  VERBOSE=0
  parse_args health --verbose
  [[ "$COMMAND" == "health" ]]
  (( VERBOSE == 1 ))
)

if declare -F show_status >/dev/null; then
  printf 'Removed status implementation is still present.\n' >&2
  exit 1
fi
if declare -F diagnostic_report >/dev/null ||
   declare -F redact_diagnostic_stream >/dev/null; then
  printf 'Removed diagnostic implementation is still present.\n' >&2
  exit 1
fi

help_output="$(usage)"
if grep -Eq 'vpn (status|diagnostic)([[:space:]]|$)' <<<"$help_output"; then
  printf 'Removed management command is still advertised.\n' >&2
  exit 1
fi
grep -Fq 'vpn show [NAME]' <<<"$help_output"
grep -Fq 'vpn audit-target [DOMAIN] [--verbose]' <<<"$help_output"
[[ "$(style_text '1;32' PASS)" == "PASS" ]]

for fingerprint in chrome firefox safari ios android edge 360 qq random; do
  client_fingerprint_is_supported "$fingerprint"
  validate_client_fingerprint "$fingerprint"
done

for mode in off salamander; do
  hy2_obfs_mode_is_supported "$mode"
  validate_hy2_obfs_mode "$mode"
done
if (validate_hy2_obfs_mode gecko >/dev/null 2>&1); then
  printf 'gecko unexpectedly passed the stable cross-client compatibility set\n' >&2
  exit 1
fi

if (validate_client_fingerprint randomized >/dev/null 2>&1); then
  printf 'randomized unexpectedly passed the cross-client compatibility set\n' >&2
  exit 1
fi

ADMIN_USER="vpnadmin"
ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButStructurallySingleLine test@example"
SERVER_IPV4="203.0.113.10"
TLS_DOMAIN="vpn.example.com"
ACME_EMAIL="admin@vpn-mail.net"
SSH_PORT="22"
REALITY_TARGET="www.example.com"
COUNTRY_EMOJI="🇩🇪"
CLIENT_FINGERPRINT="random"
HY2_OBFS_MODE="salamander"

(
  audit_tool_dir="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' >"${audit_tool_dir}/openssl"
  printf '#!/bin/sh\nexit 0\n' >"${audit_tool_dir}/timeout"
  chmod 0700 "${audit_tool_dir}/openssl" "${audit_tool_dir}/timeout"
  PATH="${audit_tool_dir}:${PATH}"
  REALITY_TARGET_AUDITED=0
  audit_during_settings=0
  select_audited_reality_target_for_install() {
    audit_during_settings=1
    REALITY_TARGET_AUDITED=1
  }
  collect_install_settings >/dev/null
  (( audit_during_settings == 1 ))
  (( REALITY_TARGET_AUDITED == 1 ))
  rm -rf -- "$audit_tool_dir"
)

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# A prompt without a newline must reach the terminal immediately instead of
# waiting for the next logged line. This is the fresh-install interaction that
# previously appeared to hang or reordered prompts ahead of their menus.
mkfifo "${work}/prompt-stream"
exec 6>"${work}/prompt-terminal"
capture_install_output "${work}/prompt.log" <"${work}/prompt-stream" &
prompt_capture_pid=$!
exec 7>"${work}/prompt-stream"
printf 'Prompt without newline: ' >&7
prompt_visible=0
for _ in {1..100}; do
  if grep -Fq 'Prompt without newline: ' "${work}/prompt-terminal"; then
    prompt_visible=1
    break
  fi
  sleep 0.01
done
if (( prompt_visible == 0 )); then
  printf 'Interactive prompt was buffered instead of reaching the terminal immediately.\n' >&2
  exit 1
fi
printf 'answer\nNext line\n' >&7
exec 7>&-
wait "$prompt_capture_pid"
exec 6>&-
[[ "$(cat "${work}/prompt-terminal")" == $'Prompt without newline: answer\nNext line' ]]

# The retained installer log is redacted and bounded while terminal output is
# preserved verbatim. Generate input without an early-closing pipeline.
exec 6>"${work}/terminal-output"
awk 'BEGIN {
  print "admin@vpn-mail.net 203.0.113.10 vpn.example.com 550e8400-e29b-41d4-a716-446655440000"
  printf "\033[31mFAIL\033[0m\n"
  for (i=0; i<120000; i++) print "0123456789abcdef"
}' | capture_install_output "${work}/bounded.log"
exec 6>&-
grep -Fq 'admin@vpn-mail.net 203.0.113.10' "${work}/terminal-output"
grep -Fq '[EMAIL-REDACTED] [IP-REDACTED] [DOMAIN-REDACTED] [UUID-REDACTED]' "${work}/bounded.log"
grep -Fq '[LOG TRUNCATED:' "${work}/bounded.log"
if LC_ALL=C grep -q "$(printf '\033')" "${work}/bounded.log"; then
  printf 'ANSI terminal styling leaked into the retained installer log.\n' >&2
  exit 1
fi
(( $(wc -c <"${work}/bounded.log") < 1050000 ))
render_user_command_wrapper "${work}/vpn-command"
sh -n "${work}/vpn-command"
grep -Fxq 'exec sudo -n "$helper" "$@"' "${work}/vpn-command"
render_settings "${work}/settings.json"
jq -e '
  .schema_version == 1 and
  .client_fingerprint == "random" and
  .hy2_obfs_mode == "salamander" and
  .reality_target == "www.example.com"
' "${work}/settings.json" >/dev/null

validate_email 'admin@vpn-mail.net'
for reserved_email in \
  random@example.com \
  admin@example.org \
  admin@host.invalid \
  admin@service.test
do
  if (validate_email "$reserved_email" >/dev/null 2>&1); then
    printf 'Reserved ACME email unexpectedly passed validation: %s\n' "$reserved_email" >&2
    exit 1
  fi
done

if declare -F configure_first_login_hook >/dev/null || declare -F render_first_login_hook >/dev/null; then
  printf 'Obsolete automatic first-login finalization hook is still present.\n' >&2
  exit 1
fi
render_auto_finalize_wrapper "${work}/auto-finalize-login"
sh -n "${work}/auto-finalize-login"
grep -Fq 'SSH_ORIGINAL_COMMAND' "${work}/auto-finalize-login"
grep -Fq 'sudo -n "/usr/local/sbin/vpn" finalize --yes' "${work}/auto-finalize-login"
grep -Fq 'exec "$login_shell" -l' "${work}/auto-finalize-login"
render_auto_finalize_ssh_dropin "${work}/auto-finalize.conf"
grep -Fxq 'Match User vpnadmin' "${work}/auto-finalize.conf"
grep -Fxq '    DisableForwarding yes' "${work}/auto-finalize.conf"
grep -Fxq '    ForceCommand /usr/local/libexec/vpn-auto-finalize-login' "${work}/auto-finalize.conf"
grep -Fxq 'Match all' "${work}/auto-finalize.conf"

finalize_body="$(declare -f finalize_installation)"
grep -Fq 'ASSUME_YES=1' <<<"$finalize_body"
grep -Fq 'apply_firewall' <<<"$finalize_body"
grep -Fq 'confirm_firewall' <<<"$finalize_body"
grep -Fq 'remove_auto_finalization' <<<"$finalize_body"
if grep -Fq 'Open one more new SSH session' <<<"$finalize_body"; then
  printf 'Finalization still requires a second authorization cycle.\n' >&2
  exit 1
fi
configure_auto_body="$(declare -f configure_auto_finalization)"
grep -Fq '/usr/sbin/sshd -t' <<<"$configure_auto_body"
grep -Fq '/usr/sbin/sshd -T -C' <<<"$configure_auto_body"
grep -Fq 'forcecommand ${AUTO_FINALIZE_WRAPPER}' <<<"$configure_auto_body"
grep -Fq 'reload_ssh_runtime' <<<"$configure_auto_body"
create_admin_body="$(declare -f create_admin_account)"
grep -Fq 'sudo -u "$ADMIN_USER" sudo -n /bin/true' <<<"$create_admin_body"
grep -Fq 'path_has_symlink_component "$user_home"' <<<"$create_admin_body"
lockdown_body="$(declare -f lockdown_ssh)"
grep -Fq 'getent passwd "$ADMIN_USER"' <<<"$lockdown_body"
if grep -Fq '/home/${ADMIN_USER}' <<<"$lockdown_body"; then
  printf 'SSH lockdown still assumes that every account lives under /home.\n' >&2
  exit 1
fi

temp_dir_body="$(declare -f new_temp_dir)"
grep -Fq 'TMP_DIR="$(mktemp -d "${TEMP_ROOT}/operation.XXXXXX")"' <<<"$temp_dir_body"
if grep -Fq '${ROLLBACK_DIR}/config.before.json' "${repo_root}/install-sing-box-server.sh"; then
  printf 'Persistent configuration backup still duplicates live VPN secrets.\n' >&2
  exit 1
fi

# Firewall confirmation must verify transient unit state instead of trusting a
# combined `systemctl stop timer service` exit code.  The service is commonly
# not loaded before the timer fires on both Debian and Ubuntu.
cancel_body="$(declare -f cancel_pending_firewall_rollback_strict)"
grep -Fq 'systemctl show --property=ActiveState --value' <<<"$cancel_body"
if grep -Fq 'systemctl stop "${unit_base}.timer" "${unit_base}.service"' <<<"$cancel_body"; then
  printf 'Firewall rollback cancellation still couples timer success to an absent transient service.\n' >&2
  exit 1
fi

(
  state_file="${work}/firewall.rollback.unit"
  printf '%s\n' 'vpn-nft-rollback-123-456' >"$state_file"
  systemctl() {
    case "$1" in
      show) printf '%s\n' inactive ;;
      stop|reset-failed) return 0 ;;
      is-active) return 3 ;;
      *) return 1 ;;
    esac
  }
  cancel_pending_firewall_rollback_strict "$state_file"
  [[ ! -e "$state_file" ]]
)

upgrade_body="$(declare -f upgrade_existing_installation)"
grep -Fq 'reconcile_managed_runtime' <<<"$upgrade_body"
grep -Fq 'write_runtime_version_marker' <<<"$upgrade_body"
marker_line="$(awk 'index($0, "write_runtime_version_marker") && !found {
  line=NR
  found=1
} END { if (found) print line }' <<<"$upgrade_body")"
health_line="$(awk 'index($0, "\"$INSTALLED_HELPER\" health") && !found {
  line=NR
  found=1
} END { if (found) print line }' <<<"$upgrade_body")"
[[ -n "$marker_line" && -n "$health_line" && "$marker_line" -lt "$health_line" ]]
grep -Fq 'Refusing managed runtime downgrade' <<<"$upgrade_body"

install_body="$(declare -f run_install)"
grep -Fq 'acquire_bootstrap_lock' <<<"$install_body"
grep -Fq 'install_base_packages' <<<"$install_body"
grep -Fq 'acquire_install_flock' <<<"$install_body"
grep -Fq 'switching install to safe overlay-update mode' <<<"$install_body"
grep -Fq 'select_audited_reality_target_for_install' <<<"$install_body"
audit_line="$(awk 'index($0, "select_audited_reality_target_for_install") && !found {
  line=NR
  found=1
} END { if (found) print line }' <<<"$install_body")"
save_line="$(awk 'index($0, "save_settings") && !found {
  line=NR
  found=1
} END { if (found) print line }' <<<"$install_body")"
[[ -n "$audit_line" && -n "$save_line" && "$audit_line" -lt "$save_line" ]]

certificate_body="$(declare -f obtain_certificate)"
grep -Fq 'Existing ACME certificate found; reusing it.' <<<"$certificate_body"
firewall_body="$(declare -f confirm_firewall)"
grep -Fq 'systemctl enable --now nftables.service' <<<"$firewall_body"
firewall_health_body="$(declare -f managed_firewall_is_healthy)"
grep -Fq 'systemctl is-enabled --quiet nftables.service' <<<"$firewall_health_body"
grep -Fq 'systemctl is-active --quiet nftables.service' <<<"$firewall_health_body"
health_details_body="$(declare -f health_details)"
grep -Fq 'render_health_verbose | redact_health_stream' <<<"$health_details_body"
health_debug_body="$(declare -f health_debug)"
grep -Fq 'render_health_debug_details' <<<"$health_debug_body"
subscription_health_body="$(declare -f subscription_service_healthy)"
grep -Fq -- '--resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:127.0.0.1"' \
  <<<"$subscription_health_body"
if grep -Fq -- '--resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:${SERVER_IPV4}"' \
  <<<"$subscription_health_body"; then
  printf 'Subscription self-test still depends on public-IP hairpin routing.\n' >&2
  exit 1
fi

printf 'Fingerprint state smoke test: PASS\n'
