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
permissions_body="$(declare -f health_managed_permissions_are_healthy)"
grep -Fq "'750:root:www-data'" <<<"$permissions_body"
grep -Fq "'640:root:www-data'" <<<"$permissions_body"
grep -Fq '.clients[].subscription_token' <<<"$permissions_body"

printf 'Management and client lifecycle smoke test: PASS\n'
