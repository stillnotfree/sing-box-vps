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

# Subscription rendering only needs already-generated server secrets. Replacing
# this loader keeps the test entirely inside its temporary directory.
generate_or_load_server_secrets() { :; }

SERVER_IPV4="203.0.113.10"
TLS_DOMAIN="vpn.example.com"
REALITY_TARGET="www.example.com"
COUNTRY_EMOJI="🇩🇪"
CLIENT_FINGERPRINT="firefox"
REALITY_PUBLIC_KEY="testPublicKey"
REALITY_SHORT_ID="deadbeef"
HY2_OBFS_PASSWORD="0123456789abcdef0123456789abcdef0123456789abcdef"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

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

jq -e '
  .mode == "rule" and
  .["allow-lan"] == false and
  .ipv6 == false and
  (.proxies | length == 2) and
  (.proxies[0].type == "vless") and
  (.proxies[0].flow == "xtls-rprx-vision") and
  (.proxies[0]["client-fingerprint"] == "firefox") and
  (.proxies[1].type == "hysteria2") and
  (.proxies[1].obfs == "salamander") and
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

render_nginx_subscription_site "${work}/nginx.conf"
grep -Fq 'default links;' "${work}/nginx.conf"
grep -Fq '~*(clash|mihomo|flclash|clash-verge|clashverge|stash) mihomo;' \
  "${work}/nginx.conf"
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

# The self-test feeds private URLs to curl through stdin rather than argv.
printf 'payload' >"${work}/curl-source"
payload="$(printf 'url = "file://%s/curl-source"\n' "$work" | \
  curl --silent --show-error --config -)"
[[ "$payload" == "payload" ]]

# A diagnostics report is intended for sharing after review. Cover the two
# generated secret lengths and bracketed IPv6 endpoints in addition to UUIDs
# and IPv4 addresses.
hy2_secret="abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"
diagnostic_sample="$(printf '%s\n' \
  "password=${hy2_secret} from [2001:db8::10]:443 via 203.0.113.10" | \
  redact_diagnostic_stream)"
[[ "$diagnostic_sample" != *"$hy2_secret"* ]]
[[ "$diagnostic_sample" != *"2001:db8::10"* ]]
[[ "$diagnostic_sample" != *"203.0.113.10"* ]]

# Public addresses assigned through provider-managed 1:1 NAT need not appear
# on a local interface. DNS and ACME remain the authoritative external gates.
SERVER_IPV4="203.0.113.10"
ip() { printf '%s\n' '2: eth0    inet 10.0.0.2/24'; }
preflight_public_ip >/dev/null 2>&1

printf 'Static subscription smoke test: PASS\n'
