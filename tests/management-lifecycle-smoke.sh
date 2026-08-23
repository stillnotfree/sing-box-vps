#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

assert_clean_cli_failure() {
  local output="$1" expected="$2"
  grep -Fq "[ERROR] ${expected}" <<<"$output"
  [[ "$output" != *'Step: startup'* ]]
}

trap - ERR
if validation_output="$(validate_client_name '../../test' 2>&1)"; then
  printf 'Invalid client name unexpectedly passed.\n' >&2
  exit 1
fi
trap on_error ERR
assert_clean_cli_failure "$validation_output" 'Client name must start with a letter'

trap - ERR
if duplicate_output="$(require_client_name_available default '{"name":"default"}' 2>&1)"; then
  printf 'Duplicate client unexpectedly passed.\n' >&2
  exit 1
fi
trap on_error ERR
assert_clean_cli_failure "$duplicate_output" \
  'Client default already exists (names are case-insensitive).'

[[ "$(management_proc_parent_pid_from_stat \
  '123 (command name with ) parentheses) S 42 7 8 9 10')" == 42 ]]

trap - ERR
if missing_output="$(require_existing_client missing '' 2>&1)"; then
  printf 'Missing client unexpectedly passed.\n' >&2
  exit 1
fi
trap on_error ERR
assert_clean_cli_failure "$missing_output" 'Client missing does not exist.'

(
  trap - ERR
  require_command() { :; }
  AUDIT_TARGET=not-a-domain
  if invalid_audit_output="$(audit_reality_target 2>&1)"; then
    printf 'Invalid audit target unexpectedly passed.\n' >&2
    exit 1
  fi
  assert_clean_cli_failure "$invalid_audit_output" \
    'Invalid fully qualified domain: not-a-domain'
)

(
  interactive_stdin() { return 0; }
  ASSUME_YES=0
  cancellation_output="$(require_confirmation <<< $'n\n')"
  [[ "$cancellation_output" == 'Cancelled; no changes made.' ]]
  [[ "$cancellation_output" != *'[ERROR]'* ]]
  [[ "$cancellation_output" != *'Step:'* ]]
)

(
  interactive_stdin() { return 0; }
  ASSUME_YES=0
  install_cancel_output="$(require_install_confirmation <<< $'n\n')"
  [[ "$install_cancel_output" == 'Cancelled; no changes made.' ]]
)

(
  trap - ERR
  interactive_stdin() { return 1; }
  ASSUME_YES=0
  if noninteractive_output="$(require_confirmation 2>&1)"; then
    printf 'Non-interactive mutation unexpectedly passed without --yes.\n' >&2
    exit 1
  fi
  assert_clean_cli_failure "$noninteractive_output" \
    'Mutating non-interactive commands require --yes.'
)

set_target_body="$(declare -f set_reality_target)"
grep -Fq 'audit_reality_target' <<<"$set_target_body"
grep -Fq "AUDIT_TARGET=\"\$NEW_REALITY_TARGET\"" <<<"$set_target_body"
[[ "$set_target_body" != *'verify_reality_target'* ]]
if declare -F verify_reality_target >/dev/null; then
  printf 'Independent basic REALITY target verifier still exists.\n' >&2
  exit 1
fi
audit_line="$(awk '/audit_reality_target/ {print NR; exit}' <<<"$set_target_body")"
lock_line="$(awk '/acquire_operation_lock/ {print NR; exit}' <<<"$set_target_body")"
[[ -n "$audit_line" && -n "$lock_line" && "$audit_line" -lt "$lock_line" ]]

(
  trap - ERR
  require_client_runtime() { :; }
  audit_reality_target() {
    printf 'Result: FAIL\n'
    return 2
  }
  acquire_operation_lock() { printf 'TRANSACTION-STARTED\n'; }
  REALITY_TARGET=old.example.com
  NEW_REALITY_TARGET=failed.example.com
  AUDIT_TARGET=""
  if target_fail_output="$(set_reality_target 2>&1)"; then
    printf 'Failed target unexpectedly reached a successful result.\n' >&2
    exit 1
  fi
  assert_clean_cli_failure "$target_fail_output" \
    'REALITY target failed.example.com failed the shared audit; no changes were made.'
  [[ "$target_fail_output" != *'TRANSACTION-STARTED'* ]]
)

(
  require_client_runtime() { :; }
  audit_reality_target() {
    printf 'Result: WARN — usable\n'
    return 1
  }
  acquire_operation_lock() { printf 'TRANSACTION-STARTED\n'; exit 0; }
  interactive_stdin() { return 0; }
  ASSUME_YES=0
  REALITY_TARGET=old.example.com
  NEW_REALITY_TARGET=warning.example.com
  AUDIT_TARGET=""
  target_cancel_output="$(set_reality_target <<< $'n\n' 2>&1)"
  grep -Fq 'Result: WARN — usable' <<<"$target_cancel_output"
  grep -Fq 'Cancelled; no changes made.' <<<"$target_cancel_output"
  [[ "$target_cancel_output" != *'[ERROR]'* ]]
  [[ "$target_cancel_output" != *'Step: startup'* ]]
  [[ "$target_cancel_output" != *'TRANSACTION-STARTED'* ]]
)

(
  require_client_runtime() { :; }
  audit_reality_target() { return 1; }
  acquire_operation_lock() { printf 'TRANSACTION-STARTED\n'; exit 0; }
  ASSUME_YES=1
  REALITY_TARGET=old.example.com
  NEW_REALITY_TARGET=accepted.example.com
  AUDIT_TARGET=""
  accepted_output="$(set_reality_target 2>&1)"
  grep -Fq 'TRANSACTION-STARTED' <<<"$accepted_output"
)

# SSH classification is conservative: a public peer alone is not evidence of
# a direct transport. The exact local socket and sshd ownership must also be
# positively observed.
(
  management_ss_established_connections() {
    printf '%s\n' \
      'ESTAB 0 0 203.0.113.10:22 198.51.100.20:50122 users:(("sshd-session",pid=4242,fd=4)) uid:0 ino:98765 sk:a1b2c3'
  }
  management_capture_ssh_transport_identity \
    203.0.113.10:22 198.51.100.20:50122
  [[ "$MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT" == 203.0.113.10:22 ]]
  [[ "$MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT" == 198.51.100.20:50122 ]]
  [[ "$MANAGEMENT_TRANSPORT_SOCKET_COOKIE" == a1b2c3 ]]
  [[ "$MANAGEMENT_TRANSPORT_SOCKET_INODE" == 98765 ]]

  management_ss_transport_connections() {
    printf '%s\n' \
      'ESTAB 0 0 203.0.113.10:22 198.51.100.20:50122 uid:0 ino:98765 sk:a1b2c3'
  }
  management_transport_identity_is_present \
    203.0.113.10:22 198.51.100.20:50122 a1b2c3 98765
  management_ss_transport_connections() {
    printf '%s\n' \
      'ESTAB 0 0 203.0.113.10:22 198.51.100.20:50122 uid:0 ino:98766 sk:d4e5f6'
  }
  if management_transport_identity_is_present \
      203.0.113.10:22 198.51.100.20:50122 a1b2c3 98765; then
    printf '%s\n' 'A reconnected socket was confused with the originating transport.' >&2
    exit 1
  fi
  management_ss_transport_connections() {
    printf '%s\n' 'ESTAB 0 0 203.0.113.10:22 198.51.100.20:50122'
  }
  if management_transport_identity_is_present \
      203.0.113.10:22 198.51.100.20:50122 a1b2c3 98765; then
    printf '%s\n' 'An unparseable transport observation was accepted.' >&2
    exit 1
  else
    [[ $? == 2 ]]
  fi
)

(
  SERVER_IPV4=203.0.113.10
  SSH_CONNECTION='198.51.100.20 50122 203.0.113.10 22'
  management_address_is_local() { [[ "$1" == 203.0.113.10 ]]; }
  management_capture_ssh_transport_identity() {
    MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT="$1"
    MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT="$2"
    MANAGEMENT_TRANSPORT_SOCKET_COOKIE=a1b2c3
    MANAGEMENT_TRANSPORT_SOCKET_INODE=98765
  }
  management_ssh_context_from_ancestry() {
    MANAGEMENT_SSH_ANCESTOR_FOUND=1
    MANAGEMENT_SSH_ANCESTOR_PID=4242
    return 0
  }
  management_sing_box_connection_to_ssh_endpoint() { return 1; }
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == direct ]]
  [[ "$MANAGEMENT_SESSION_REASON" == *'positively establish'* ]]

  SSH_CONNECTION='203.0.113.10 50122 203.0.113.10 22'
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]

  SSH_CONNECTION='198.51.100.20 50122 203.0.113.10 22'
  management_capture_ssh_transport_identity() { return 1; }
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]

  # A root-side command may lose SSH_CONNECTION after sudo. The ancestry
  # recovery path must still classify the session conservatively.
  unset SSH_CONNECTION
  management_ssh_context_from_ancestry() {
    MANAGEMENT_SSH_ANCESTOR_FOUND=1
    MANAGEMENT_SSH_ANCESTOR_PID=4242
    MANAGEMENT_SSH_CONNECTION='198.51.100.20 50122 203.0.113.10 22'
    return 0
  }
  management_capture_ssh_transport_identity() {
    MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT="$1"
    MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT="$2"
    MANAGEMENT_TRANSPORT_SOCKET_COOKIE=a1b2c3
    MANAGEMENT_TRANSPORT_SOCKET_INODE=98765
  }
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == direct ]]

  # Positive socket evidence is still not enough when sing-box owns an
  # outbound connection to the managed SSH endpoint (1:1 NAT self-tunnel).
  SSH_CONNECTION='198.51.100.20 50122 203.0.113.10 22'
  management_sing_box_connection_to_ssh_endpoint() { return 0; }
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]
  [[ "$MANAGEMENT_SESSION_REASON" == *'1:1 NAT'* ]]

  # Without positive SSH ancestry, a copied SSH_CONNECTION is not evidence of
  # a controlling direct session.
  management_ssh_context_from_ancestry() {
    MANAGEMENT_SSH_ANCESTOR_FOUND=0
    MANAGEMENT_SSH_ANCESTOR_PID=
    return 1
  }
  management_sing_box_connection_to_ssh_endpoint() { return 1; }
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]

  MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT=""
  MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT=""
  MANAGEMENT_TRANSPORT_SOCKET_COOKIE=""
  MANAGEMENT_TRANSPORT_SOCKET_INODE=""
  if missing_identity_output="$(deferred_job_create client-add test 2>&1)"; then
    printf '%s\n' 'Deferred staging accepted a missing SSH transport identity.' >&2
    exit 1
  fi
  grep -Fq 'exact controlling SSH transport identity is unavailable' \
    <<<"$missing_identity_output"
)

fingerprint_body="$(declare -f set_client_fingerprint)"
grep -Fq 'management_ssh_requires_deferred_activation' <<<"$fingerprint_body"
grep -Fq 'deferred_job_create fingerprint' <<<"$fingerprint_body"
for mutation_body in "$(declare -f set_reality_target)" "$(declare -f set_hy2_obfs)"; do
  grep -Fq 'management_ssh_requires_deferred_activation' <<<"$mutation_body"
  grep -Fq 'queue_deferred_mutation' <<<"$mutation_body"
done

# Deferred jobs carry a live-state baseline, refuse a second pending mutation,
# and are recovered when their transient unit disappears even if the original
# session is still alive.
baseline_installer="${work}/baseline-installer.sh"
cp "${repo_root}/install-sing-box-server.sh" "$baseline_installer"
for mapping in \
  "DEFERRED_MUTATION_ROOT:${work}/deferred-mutations" \
  "OPERATION_OUTCOME_ROOT:${work}/operation-outcomes" \
  "CLIENTS_FILE:${work}/clients.json" \
  "CONFIG_FILE:${work}/config.json" \
  "SETTINGS_FILE:${work}/settings.json" \
  "SUBSCRIPTION_ROOT:${work}/subscriptions"
do
  constant="${mapping%%:*}"
  path="${mapping#*:}"
  sed -i.bak "s|^readonly ${constant}=.*|readonly ${constant}=\"${path}\"|" \
    "$baseline_installer"
  rm -f -- "${baseline_installer}.bak"
done
bash -c '
  set -Eeuo pipefail
  # shellcheck disable=SC1090
  source "$1"
  trap - ERR
  install() {
    directory=0
    mode=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) directory=1; shift ;;
        -o|-g) shift 2 ;;
        -m) mode="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    if (( directory == 1 )); then
      mkdir -p "$1"
      [ -z "$mode" ] || chmod "$mode" "$1"
    else
      cp "$1" "$2"
      [ -z "$mode" ] || chmod "$mode" "$2"
    fi
  }
  mkdir -p "$DEFERRED_MUTATION_ROOT" "$OPERATION_OUTCOME_ROOT" "$SUBSCRIPTION_ROOT"
  printf "%s\n" live >"$CLIENTS_FILE"
  printf "%s\n" live >"$CONFIG_FILE"
  printf "%s\n" live >"$SETTINGS_FILE"
  printf "%s\n" subscription >"${SUBSCRIPTION_ROOT}/token.links"
  job="${DEFERRED_MUTATION_ROOT}/job.pending"
  mkdir -p "$job"
  printf "%s\n" operation=client-add >"${job}/metadata"
  deferred_job_capture_baseline "$job" "${job}/baseline"
  deferred_job_verify_baseline "$job"
  printf "%s\n" changed >"$CLIENTS_FILE"
  if deferred_job_verify_baseline "$job"; then
    printf "%s\n" "Baseline mismatch was not detected." >&2
    exit 1
  fi
  [[ "$DEFERRED_BASELINE_MISMATCH" == clients.json*changed* ]]
  DEFERRED_JOB_DIR=""
  if pending_output="$(deferred_refuse_if_pending 2>&1)"; then
    printf "%s\n" "A second pending mutation was accepted." >&2
    exit 1
  fi
  grep -Fq "already pending" <<<"$pending_output"
  DEFERRED_JOB_DIR="$job"
  deferred_refuse_if_pending
  rm -rf -- "$job"

  orphan="${DEFERRED_MUTATION_ROOT}/job.orphan"
  mkdir -p "$orphan"
  printf "%s\n" \
    operation=client-delete \
    created=2026-08-20T20:00:00Z \
    unit=vpn-deferred-missing \
    transport_local=203.0.113.10:22 \
    transport_remote=198.51.100.20:50122 \
    transport_cookie=a1b2c3 \
    transport_inode=98765 \
    >"${orphan}/metadata"
  systemctl() {
    case "$*" in
      *LoadState*) printf "%s\n" not-found ;;
      *ActiveState*) printf "%s\n" inactive ;;
      *) return 1 ;;
    esac
  }
  if deferred_job_is_orphaned "$orphan"; then
    :
  else
    printf "%s\n" "Orphaned transient unit was not detected." >&2
    exit 1
  fi
  deferred_recover_orphaned_jobs
  [[ ! -e "$orphan" ]]
  grep -Fxq "status=failure" "${OPERATION_OUTCOME_ROOT}/job.orphan.status"
  grep -Fxq "exit_status=125" "${OPERATION_OUTCOME_ROOT}/job.orphan.status"
  grep -Fq "worker/session disappeared" "${OPERATION_OUTCOME_ROOT}/job.orphan.status"
' _ "$baseline_installer"

SERVER_IPV4=203.0.113.10
TLS_DOMAIN=vpn.example.com
REALITY_TARGET=curl.se
COUNTRY_EMOJI='🇩🇪'
CLIENT_FINGERPRINT=firefox
HY2_OBFS_MODE=off
HY2_OBFS_PASSWORD=1234567890abcdef1234567890abcdef1234567890abcdef
REALITY_PRIVATE_KEY=test-private-key
REALITY_PUBLIC_KEY=test-public-key
REALITY_SHORT_ID=deadbeef
generate_or_load_server_secrets() { :; }
sing-box() {
  [[ "$1" == check && "$2" == -c ]]
  jq -e . "$3" >/dev/null
}

default_token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
phone_token=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
temp_token=1111111111111111111111111111111111111111111111111111111111111111
temp_uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
temp_hy2=222222222222222222222222222222222222222222222222

default_client="$(jq -cn --arg token "$default_token" '{
  name: "default",
  vless_uuid: "550e8400-e29b-41d4-a716-446655440000",
  hy2_password: "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
  subscription_token: $token,
  created_at: "2026-08-01T00:00:00+03:00"
}')"
phone_client="$(jq -cn --arg token "$phone_token" '{
  name: "phone",
  vless_uuid: "660e8400-e29b-41d4-a716-446655440000",
  hy2_password: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  subscription_token: $token,
  created_at: "2026-08-02T00:00:00+03:00"
}')"
temp_client="$(jq -cn \
  --arg token "$temp_token" --arg uuid "$temp_uuid" --arg hy2 "$temp_hy2" '{
  name: "temporary",
  vless_uuid: $uuid,
  hy2_password: $hy2,
  subscription_token: $token,
  created_at: "2026-08-03T00:00:00+03:00"
}')"

initial_database="${work}/clients.initial.json"
added_database="${work}/clients.added.json"
restored_database="${work}/clients.restored.json"
jq -n --argjson first "$default_client" --argjson second "$phone_client" \
  '{schema_version: 2, clients: [$first, $second]}' >"$initial_database"
validate_client_database "$initial_database"
append_client_to_database "$initial_database" "$temp_client" "$added_database"
remove_client_from_database "$added_database" temporary "$restored_database"
cmp -s "$initial_database" "$restored_database"

render_test_subscription_tree() {
  local database="$1" output="$2" client
  mkdir -p "$output"
  while IFS= read -r client; do
    render_client_subscription_files "$client" "$output"
  done < <(jq -c '.clients[]' "$database")
}

initial_tree="${work}/tree.initial"
added_tree="${work}/tree.added"
restored_tree="${work}/tree.restored"
render_test_subscription_tree "$initial_database" "$initial_tree"
render_test_subscription_tree "$added_database" "$added_tree"
render_test_subscription_tree "$restored_database" "$restored_tree"
diff -ru "$initial_tree" "$restored_tree"
[[ "$(find "$initial_tree" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 4 ]]
openssl base64 -d -A -in "${initial_tree}/${default_token}.links" \
  >"${work}/default.decoded.links"
[[ "$(grep -c '^vless://' "${work}/default.decoded.links")" == 1 ]]
[[ "$(grep -c '^hysteria2://' "${work}/default.decoded.links")" == 1 ]]
jq -e '(.proxies | length == 2) and
  any(.proxies[]; .type == "vless") and
  any(.proxies[]; .type == "hysteria2")' \
  "${initial_tree}/${default_token}.mihomo" >/dev/null
for suffix in links mihomo; do
  [[ -f "${added_tree}/${temp_token}.${suffix}" ]]
  [[ ! -e "${restored_tree}/${temp_token}.${suffix}" ]]
  cmp -s "${initial_tree}/${default_token}.${suffix}" \
    "${added_tree}/${default_token}.${suffix}"
  cmp -s "${initial_tree}/${phone_token}.${suffix}" \
    "${added_tree}/${phone_token}.${suffix}"
done
if grep -RFq "$temp_uuid" "$restored_database" "$restored_tree" ||
   grep -RFq "$temp_hy2" "$restored_database" "$restored_tree" ||
   grep -RFq "$temp_token" "$restored_database" "$restored_tree"; then
  printf 'Deleted client material survived canonical regeneration.\n' >&2
  exit 1
fi

initial_config="${work}/config.initial.json"
restored_config="${work}/config.restored.json"
build_sing_box_config "$initial_database" "$initial_config"
build_sing_box_config "$restored_database" "$restored_config"
cmp -s "$initial_config" "$restored_config"
[[ "$(<"$restored_config")" != *"$temp_uuid"* ]]
[[ "$(<"$restored_config")" != *"$temp_hy2"* ]]

database_before_repeat="$(shasum -a 256 "$restored_database" | awk '{print $1}')"
trap - ERR
if repeated_output="$(require_existing_client temporary '' 2>&1)"; then
  printf 'Repeated delete validation unexpectedly succeeded.\n' >&2
  exit 1
fi
trap on_error ERR
assert_clean_cli_failure "$repeated_output" 'Client temporary does not exist.'
[[ "$(shasum -a 256 "$restored_database" | awk '{print $1}')" == "$database_before_repeat" ]]

roundtrip_tree="${work}/tree.roundtrip"
CLIENT_FINGERPRINT=chrome
render_test_subscription_tree "$initial_database" "${work}/tree.fingerprint.changed"
CLIENT_FINGERPRINT=firefox
render_test_subscription_tree "$initial_database" "$roundtrip_tree"
diff -ru "$initial_tree" "$roundtrip_tree"

REALITY_TARGET=www.kernel.org
render_test_subscription_tree "$initial_database" "${work}/tree.target.changed"
build_sing_box_config "$initial_database" "${work}/config.target.changed.json"
REALITY_TARGET=curl.se
render_test_subscription_tree "$initial_database" "${work}/tree.target.restored"
build_sing_box_config "$initial_database" "${work}/config.target.restored.json"
diff -ru "$initial_tree" "${work}/tree.target.restored"
cmp -s "$initial_config" "${work}/config.target.restored.json"

HY2_OBFS_MODE=salamander
render_test_subscription_tree "$initial_database" "${work}/tree.obfs.changed"
build_sing_box_config "$initial_database" "${work}/config.obfs.changed.json"
HY2_OBFS_MODE=off
render_test_subscription_tree "$initial_database" "${work}/tree.obfs.restored"
build_sing_box_config "$initial_database" "${work}/config.obfs.restored.json"
diff -ru "$initial_tree" "${work}/tree.obfs.restored"
cmp -s "$initial_config" "${work}/config.obfs.restored.json"

nginx_before="${work}/nginx.before.conf"
nginx_after="${work}/nginx.after.conf"
render_nginx_subscription_site "$nginx_before"
render_nginx_subscription_site "$nginx_after"
cmp -s "$nginx_before" "$nginx_after"
grep -Fq "try_files /\$vpn_token.\$vpn_subscription_format =404;" "$nginx_before"
grep -Fq 'location / { return 404; }' "$nginx_before"
grep -Fq 'internal;' "$nginx_before"
grep -Fq 'access_log off;' "$nginx_before"
grep -Fq 'error_log /var/log/nginx/error.log crit;' "$nginx_before"
grep -Fq 'limit_except GET HEAD { deny all; }' "$nginx_before"

activation_body="$(declare -f activate_subscription_tree)"
grep -Fq 'install -d -o root -g www-data -m 0750' <<<"$activation_body"
grep -Fq 'install -o root -g www-data -m 0640' <<<"$activation_body"

(
  bash -c '
    set -Eeuo pipefail
    installer="$1"
    work="$2"
    activation_root="${work}/activation-live"
    staged="${work}/activation-staged"
    mv_log="${work}/activation-mv.log"
    sandbox_installer="${work}/activation-installer.sh"
    cp "$installer" "$sandbox_installer"
    sed -i.bak "s|^readonly SUBSCRIPTION_ROOT=.*|readonly SUBSCRIPTION_ROOT=\"${activation_root}\"|" "$sandbox_installer"
    rm -f "${sandbox_installer}.bak"
    source "$sandbox_installer"
    mkdir -p "$staged" "$SUBSCRIPTION_ROOT"
    printf "staged subscription\\n" >"${staged}/token.links"
    printf "active subscription\\n" >"${SUBSCRIPTION_ROOT}/token.links"

    getent() { return 0; }
    install() {
      if [[ "$1" == "-d" ]]; then
        command mkdir -p -- "${!#}"
        return
      fi
      return 1
    }
    rm() {
      local arg
      for arg in "$@"; do
        [[ "$arg" == -- || "$arg" == -* ]] && continue
        [[ "$arg" == "${work}/"* ]] || return 1
      done
      command rm "$@"
    }
    mv() {
      local arg
      for arg in "$@"; do
        [[ "$arg" == -- || "$arg" == -* ]] && continue
        [[ "$arg" == "${work}/"* ]] || return 1
      done
      printf "%s\\n" "$*" >>"$mv_log"
      command mv "$@"
    }

    if activate_subscription_tree "$staged"; then
      printf "Subscription activation unexpectedly succeeded after file install failure.\\n" >&2
      exit 1
    fi
    cmp -s <(printf "active subscription\\n") "${SUBSCRIPTION_ROOT}/token.links"
    [[ ! -e "${SUBSCRIPTION_ROOT}.new.$$" ]]
    [[ ! -s "$mv_log" ]]
  ' _ "${repo_root}/install-sing-box-server.sh" "$work"
)
permissions_body="$(declare -f health_managed_permissions_are_healthy)"
masquerade_permissions_body="$(declare -f hy2_masquerade_is_healthy)"
grep -Fq "'750:root:sing-box'" <<<"$masquerade_permissions_body"
grep -Fq "'644:root:sing-box'" <<<"$masquerade_permissions_body"
grep -Fq 'hy2_masquerade_is_healthy' <<<"$permissions_body"
grep -Fq "'750:root:www-data'" <<<"$permissions_body"
grep -Fq "'640:root:www-data'" <<<"$permissions_body"
grep -Fq '.clients[].subscription_token' <<<"$permissions_body"

printf 'Management and client lifecycle smoke test: PASS\n'
