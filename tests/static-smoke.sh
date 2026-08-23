#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The path is resolved at runtime so the test also works outside the repository
# working directory. ShellCheck cannot follow this dynamic source or see the
# globals consumed by the imported renderer functions.
# shellcheck disable=SC1091,SC2034
source "${repo_root}/install-sing-box-server.sh"

generated_fixture="$(mktemp)"
"${repo_root}/scripts/build-standalone.sh" "$generated_fixture" >/dev/null
cmp -s "$generated_fixture" "${repo_root}/install-sing-box-server.sh" || {
  printf 'Committed standalone installer is out of sync with src modules.\n' >&2
  exit 1
}
rm -f -- "$generated_fixture"

# Candidate extraction must consume the complete producer stream. An early
# awk exit makes pipefail report SIGPIPE (141) on apt-cache in some Ubuntu
# installations.
apt-cache() {
  printf '%s\n' \
    'sing-box:' \
    '  Installed: (none)' \
    '  Candidate: 1.13.16' \
    '  Version table:'
  local line
  for line in {1..4096}; do
    printf '     1.13.16 500 source-%s\n' "$line"
  done
}
[[ "$(sing_box_candidate_version)" == "1.13.16" ]]

# Installer and state metadata parsing must also consume complete files rather
# than hiding SIGPIPE behind `head -n1` under pipefail.
metadata_fixture="$(mktemp)"
{
  printf '%s\n' 'readonly SCRIPT_VERSION="1.0.10"'
  for line in {1..4096}; do
    printf 'readonly SCRIPT_VERSION="9.9.%s"\n' "$line"
  done
} >"$metadata_fixture"
[[ "$(script_version_from_file "$metadata_fixture")" == "1.0.10" ]]
rm -f -- "$metadata_fixture"
if grep -Eq '\|[[:space:]]*head([[:space:]]|$)' "${repo_root}/install-sing-box-server.sh"; then
  printf 'Early-closing head pipeline remains in the installer.\n' >&2
  exit 1
fi

# Subscription rendering only needs already-generated server secrets. Replacing
# this loader keeps the test entirely inside its temporary directory.
generate_or_load_server_secrets() { :; }
sing-box() {
  [[ "$1" == "check" && "$2" == "-c" ]]
  jq -e . "$3" >/dev/null
}

SERVER_IPV4="203.0.113.10"
TLS_DOMAIN="vpn.example.com"
REALITY_TARGET="www.example.com"
COUNTRY_EMOJI="🇩🇪"
CLIENT_FINGERPRINT="firefox"
HY2_OBFS_MODE="off"
HY2_OBFS_PASSWORD="1234567890abcdef1234567890abcdef1234567890abcdef"
REALITY_PRIVATE_KEY="testPrivateKey"
REALITY_PUBLIC_KEY="testPublicKey"
REALITY_SHORT_ID="deadbeef"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

SSH_PORT="2222"
write_firewall_candidate "${work}/vpn-filter.nft"
grep -Fxq 'add table inet vpn_filter' "${work}/vpn-filter.nft"
grep -Fxq 'flush table inet vpn_filter' "${work}/vpn-filter.nft"
if grep -Fq 'flush ruleset' "${work}/vpn-filter.nft"; then
  printf 'Managed firewall candidate still flushes the global nftables ruleset.\n' >&2
  exit 1
fi
rollback_firewall_body="$(declare -f rollback_firewall)"
if grep -Fq 'nft flush ruleset' <<<"$rollback_firewall_body"; then
  printf 'Firewall rollback still flushes the global nftables ruleset.\n' >&2
  exit 1
fi
grep -Fq 'nft delete table inet vpn_filter' <<<"$rollback_firewall_body"
firewall_boundary_body="$(declare -f render_nftables_service_boundary)"
grep -Fxq '# Managed by vpn-setup. Preserve unrelated nftables tables.' <<<"$firewall_boundary_body"
grep -Fxq 'ExecStop=-/usr/sbin/nft delete table inet vpn_filter' <<<"$firewall_boundary_body"
grep -Fq 'configure_nftables_service_boundary' <<<"$(declare -f apply_firewall)"
# shellcheck disable=SC2016 # Match the literal source declaration.
grep -Fxq 'readonly NFTABLES_SYSTEMD_DROPIN="${NFTABLES_SYSTEMD_DROPIN_DIR}/90-vpn-table-boundary.conf"' \
  "${repo_root}/src/00-preamble.sh"
if grep -R -Fq '10-vpn-table-boundary.conf' \
  "${repo_root}/src" "${repo_root}/install-sing-box-server.sh"; then
  printf 'Unpublished legacy nftables boundary cleanup remains in production files.\n' >&2
  exit 1
fi
nftables_health_body="$(declare -f nftables_service_boundary_is_healthy)"
grep -Fq 'nftables_effective_execstop_is_exact' <<<"$nftables_health_body"
grep -Fq 'systemctl show -p ExecStop --value nftables.service' <<<"$nftables_health_body"

token="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
client="$(jq -cn \
  --arg token "$token" \
  '{
    name: "default",
    vless_uuid: "550e8400-e29b-41d4-a716-446655440000",
    hy2_password: "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
    subscription_token: $token,
    created_at: "2026-07-17T00:00:00+03:00"
  }')"

render_client_subscription_files "$client" "$work"
openssl base64 -d -A -in "${work}/${token}.links" >"${work}/decoded.links"
grep -q '^vless://' "${work}/decoded.links"
grep -q '^hysteria2://' "${work}/decoded.links"
grep -Fq '&fp=firefox&' "${work}/decoded.links"
if grep -Eq 'obfs=|obfs-password=' "${work}/decoded.links"; then
  printf 'Unexpected Hysteria2 obfuscation in URI subscription.\n' >&2
  exit 1
fi

jq -e '
  .mode == "rule" and
  .["allow-lan"] == false and
  .ipv6 == false and
  (.proxies | length == 2) and
  (.proxies[0].type == "vless") and
  (.proxies[0]["packet-encoding"] == "xudp") and
  (.proxies[0].flow == "xtls-rprx-vision") and
  (.proxies[0]["client-fingerprint"] == "firefox") and
  (.proxies[1].type == "hysteria2") and
  ((.proxies[1] | has("obfs")) | not) and
  ((.proxies[1] | has("obfs-password")) | not) and
  (.rules[-1] == "MATCH,PROXY")
' "${work}/${token}.mihomo" >/dev/null

for fingerprint in chrome firefox safari ios android edge 360 qq random; do
  CLIENT_FINGERPRINT="$fingerprint"
  render_client_subscription_files "$client" "$work"
  openssl base64 -d -A -in "${work}/${token}.links" >"${work}/decoded.links"
  grep -Fq "&fp=${fingerprint}&" "${work}/decoded.links"
  jq -e --arg fingerprint "$fingerprint" \
    '.proxies[0]["client-fingerprint"] == $fingerprint' \
    "${work}/${token}.mihomo" >/dev/null
done

# Salamander is an explicit global opt-in. It must update the server inbound
# and both portable subscription representations with the same shared secret.
HY2_OBFS_MODE="salamander"
render_client_subscription_files "$client" "$work"
openssl base64 -d -A -in "${work}/${token}.links" >"${work}/decoded.links"
grep -Fq '&obfs=salamander&obfs-password=1234567890abcdef1234567890abcdef1234567890abcdef' \
  "${work}/decoded.links"
jq -e '
  .proxies[1].obfs == "salamander" and
  .proxies[1]["obfs-password"] == "1234567890abcdef1234567890abcdef1234567890abcdef"
' "${work}/${token}.mihomo" >/dev/null

client_database="${work}/clients.json"
jq -n --argjson client "$client" '{schema_version: 2, clients: [$client]}' >"$client_database"
build_sing_box_config "$client_database" "${work}/sing-box.json"
jq -e '
  (.inbounds[] | select(.tag == "hysteria2-in") | .obfs.type) == "salamander" and
  (.inbounds[] | select(.tag == "hysteria2-in") | .obfs.password) ==
    "1234567890abcdef1234567890abcdef1234567890abcdef"
' "${work}/sing-box.json" >/dev/null
HY2_OBFS_MODE="off"
build_sing_box_config "$client_database" "${work}/sing-box-off.json"
jq -e '
  (.inbounds | length == 2) and
  ([.inbounds[].type] | sort) == ["hysteria2", "vless"] and
  ([.inbounds[].tag] | sort) == ["hysteria2-in", "vless-reality-in"] and
  ([.outbounds[].type] | sort) == ["direct"] and
  ([.outbounds[].tag] | sort) == ["direct"] and
  ([.inbounds[] | select(
    .type == "vless" and
    .tag == "vless-reality-in" and
    .listen == "0.0.0.0" and
    .listen_port == 443 and
    .tls.enabled == true and
    .tls.reality.enabled == true and
    .tls.reality.handshake.server_port == 443 and
    (all(.users[]; .flow == "xtls-rprx-vision"))
  )] | length) == 1 and
  ([.inbounds[] | select(
    .type == "hysteria2" and
    .tag == "hysteria2-in" and
    .listen == "0.0.0.0" and
    .listen_port == 443 and
    .tls.enabled == true and
    .tls.min_version == "1.3" and
    .tls.alpn == ["h3"]
  )] | length) == 1 and
  ((.inbounds[] | select(.tag == "hysteria2-in") | has("obfs")) | not) and
  any(.route.rules[]; .ip_is_private == true and .action == "reject") and
  any(.route.rules[];
    .action == "reject" and
    (.ip_cidr | index("100.64.0.0/10")) != null and
    (.ip_cidr | index("169.254.0.0/16")) != null and
    (.ip_cidr | index("fe80::/10")) != null)
' "${work}/sing-box-off.json" >/dev/null
masquerade_directory="$(jq -r '.inbounds[] | select(.tag == "hysteria2-in") | .masquerade.directory' "${work}/sing-box-off.json")"
[[ "$(jq -r '.inbounds[] | select(.tag == "hysteria2-in") | .masquerade.type' "${work}/sing-box-off.json")" == file ]]
[[ "$masquerade_directory" == "$HY2_MASQUERADE_ROOT" ]]
[[ "$HY2_MASQUERADE_ROOT" == "${CONFIG_DIR}/masquerade" ]]
[[ "$HY2_MASQUERADE_ROOT" != /var/lib/sing-box/* ]]
render_hy2_masquerade_site "${work}/hy2-index.html"
grep -Fq '<title>Welcome</title>' "${work}/hy2-index.html"
[[ "$(<"${work}/hy2-index.html")" != *'http://'* ]]
[[ "$(<"${work}/hy2-index.html")" != *'https://'* ]]
masquerade_body="$(declare -f install_hy2_masquerade)"
# shellcheck disable=SC2016 # Match literal function text.
grep -Fq 'install -d -o root -g sing-box -m 0750 "$CONFIG_DIR"' <<<"$masquerade_body"
grep -Fq 'install -d -o root -g sing-box -m 0750' <<<"$masquerade_body"
grep -Fq 'install -o root -g sing-box -m 0644' <<<"$masquerade_body"
# shellcheck disable=SC2016 # Match literal function text.
grep -Fq 'chown root:sing-box "$HY2_MASQUERADE_ROOT"' <<<"$masquerade_body"
# shellcheck disable=SC2016 # Match literal function text.
grep -Fq 'chmod 0750 "$HY2_MASQUERADE_ROOT"' <<<"$masquerade_body"
# shellcheck disable=SC2016 # Match literal function text.
grep -Fq 'chown root:sing-box "$staged"' <<<"$masquerade_body"
# shellcheck disable=SC2016 # Match literal function text.
grep -Fq 'chmod 0644 "$staged"' <<<"$masquerade_body"

# The macOS runner cannot prove Linux uid/gid values. Exercise the complete
# normalization command path instead, including an existing drifted tree and
# a repeated reconciliation pass.
(
  permission_log="${work}/hy2-permissions.log"
  masquerade_installer="${work}/masquerade-installer.sh"
  cp "${repo_root}/install-sing-box-server.sh" "$masquerade_installer"
  for mapping in \
    "CONFIG_DIR:${work}/sing-box-config" \
    "HY2_MASQUERADE_ROOT:${work}/hy2-masquerade"
  do
    constant="${mapping%%:*}"
    path="${mapping#*:}"
    sed -i.bak "s|^readonly ${constant}=.*|readonly ${constant}=\"${path}\"|" \
      "$masquerade_installer"
    rm -f -- "${masquerade_installer}.bak"
  done
  bash -c '
    set -Eeuo pipefail
    source "$1"
    permission_log="$2"
    install() {
      local directory=0 source destination
      while (( $# > 0 )); do
        case "$1" in
          -d) directory=1; shift ;;
          -o|-g|-m) shift 2 ;;
          *)
            if (( directory == 1 )); then
              destination="$1"
            else
              source="$1"
              shift
              destination="$1"
            fi
            break
            ;;
        esac
      done
      if (( directory == 1 )); then
        command mkdir -p "$destination"
      else
        command cp "$source" "$destination"
      fi
    }
    chown() { printf "chown %s %s\n" "$1" "$2" >>"$permission_log"; }
    # shellcheck disable=SC2032 # This test intentionally shadows chmod.
    chmod() { printf "chmod %s %s\n" "$1" "$2" >>"$permission_log"; }
    command mkdir -p "$HY2_MASQUERADE_ROOT"
    printf "drift\n" >"${HY2_MASQUERADE_ROOT}/index.html"
    install_hy2_masquerade
    [[ -f "${HY2_MASQUERADE_ROOT}/index.html" ]]
    grep -Fxq "chown root:sing-box ${HY2_MASQUERADE_ROOT}" "$permission_log"
    grep -Fxq "chmod 0750 ${HY2_MASQUERADE_ROOT}" "$permission_log"
    grep -Fxq "chown root:sing-box ${HY2_MASQUERADE_ROOT}/index.html.new" "$permission_log"
    grep -Fxq "chmod 0644 ${HY2_MASQUERADE_ROOT}/index.html.new" "$permission_log"
    install_hy2_masquerade
    [[ "$(grep -Fxc "chown root:sing-box ${HY2_MASQUERADE_ROOT}" "$permission_log")" == 2 ]]
    [[ "$(grep -Fxc "chmod 0750 ${HY2_MASQUERADE_ROOT}" "$permission_log")" == 2 ]]
    [[ "$(grep -Fxc "chown root:sing-box ${HY2_MASQUERADE_ROOT}/index.html.new" "$permission_log")" == 2 ]]
    [[ "$(grep -Fxc "chmod 0644 ${HY2_MASQUERADE_ROOT}/index.html.new" "$permission_log")" == 2 ]]
  ' _ "$masquerade_installer" "$permission_log"
)

render_nginx_subscription_site "${work}/nginx.conf"
[[ "$(grep -Ec '^[[:space:]]*listen[[:space:]]+' "${work}/nginx.conf")" == 1 ]]
grep -Eq '^[[:space:]]*listen[[:space:]]+8443[[:space:]]+ssl;' "${work}/nginx.conf"
grep -Fq 'default links;' "${work}/nginx.conf"
grep -Fq '~*(clash|mihomo|flclash|clash-verge|clashverge|stash) mihomo;' \
  "${work}/nginx.conf"
grep -Fq '~*(sing-box|singbox|hiddify|happ|nekobox|xray|v2ray|v2rayn|v2rayng|shadowrocket) links;' \
  "${work}/nginx.conf"
grep -Fq 'links|mihomo' "${work}/nginx.conf"
if grep -Fq 'links|mihomo|sing-box' "${work}/nginx.conf" || \
   find "$work" -maxdepth 1 -type f -name '*.sing-box' -print -quit | grep -q .; then
  printf 'Unexpected platform-specific sing-box subscription endpoint.\n' >&2
  exit 1
fi
grep -Fq 'access_log off;' "${work}/nginx.conf"
grep -Fq 'limit_except GET HEAD' "${work}/nginx.conf"

# The generated ACME deploy hook must remain valid POSIX shell and serialize
# certificate rotation. Its EXIT trap provides rollback after either file in
# the certificate/key pair has entered the live location.
render_certificate_hook "${work}/certificate-hook"
sh -n "${work}/certificate-hook"
grep -Fq 'certificate-deploy.lock' "${work}/certificate-hook"
grep -Fq 'commit_active=1' "${work}/certificate-hook"
grep -Fq 'restore_previous' "${work}/certificate-hook"
grep -Fq 'MainPID' "${work}/certificate-hook"
grep -Fq 'wait_for_same_pid' "${work}/certificate-hook"
if grep -Fq "reload-or-restart \"\$service\"" "${work}/certificate-hook" ||
   grep -Fq "restart \"\$service\"" "${work}/certificate-hook"; then
  printf 'Certificate deploy hook still deliberately restarts sing-box.\n' >&2
  exit 1
fi
grep -Fq -- "-connect '127.0.0.1:8443'" "${work}/certificate-hook"
grep -Fq -- "-servername 'vpn.example.com'" "${work}/certificate-hook"
# shellcheck disable=SC2016 # Match literal generated-hook variables.
grep -Fq 'cmp -s "$expected_der" "$served_der"' "${work}/certificate-hook"

# The self-test feeds private URLs to curl through stdin rather than argv.
printf 'payload' >"${work}/curl-source"
payload="$(printf 'url = "file://%s/curl-source"\n' "$work" | \
  curl --silent --show-error --config -)"
[[ "$payload" == "payload" ]]

# Verbose health output is intended for sharing after review. Cover the two
# generated secret lengths and bracketed IPv6 endpoints in addition to UUIDs
# and IPv4 addresses.
hy2_secret="abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"
health_sample="$(printf '%s\n' \
  "password=${hy2_secret} from [2001:db8::10]:443 via 203.0.113.10 vpn.example.com" | \
  redact_health_stream)"
[[ "$health_sample" != *"$hy2_secret"* ]]
[[ "$health_sample" != *"2001:db8::10"* ]]
[[ "$health_sample" != *"203.0.113.10"* ]]
[[ "$health_sample" != *"vpn.example.com"* ]]

# Public addresses assigned through provider-managed 1:1 NAT need not appear
# on a local interface. DNS and ACME remain the authoritative external gates.
SERVER_IPV4="203.0.113.10"
ip() { printf '%s\n' '2: eth0    inet 10.0.0.2/24'; }
preflight_public_ip >/dev/null 2>&1

printf 'Static subscription smoke test: PASS\n'
