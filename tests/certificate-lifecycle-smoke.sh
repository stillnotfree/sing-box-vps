#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if (( EUID != 0 )) || ! command -v systemctl >/dev/null 2>&1 || \
   ! systemctl show-environment >/dev/null 2>&1 || \
   ! command -v sing-box >/dev/null 2>&1 || \
   ! command -v openssl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  printf 'Certificate lifecycle smoke test: SKIP (root, systemd, sing-box, openssl, and timeout are required)\n'
  exit 0
fi

work="$(mktemp -d)"
unit="vpn-certificate-lifecycle-$$"
port=$((20000 + RANDOM % 10000))
trap 'systemctl stop "${unit}.service" >/dev/null 2>&1 || true; systemctl reset-failed "${unit}.service" >/dev/null 2>&1 || true; rm -rf -- "$work"' EXIT

make_certificate() {
  local prefix="$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost' \
    -keyout "${prefix}.key" -out "${prefix}.pem" >/dev/null 2>&1
}

make_certificate "${work}/old"
make_certificate "${work}/new"
uuid='550e8400-e29b-41d4-a716-446655440000'
cat >"${work}/config.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${port},
      "users": [{ "uuid": "${uuid}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "${work}/active.pem",
        "key_path": "${work}/active.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
install -m 0600 "${work}/old.pem" "${work}/active.pem"
install -m 0600 "${work}/old.key" "${work}/active.key"
sing-box check -c "${work}/config.json" >/dev/null

systemd-run --quiet --collect --unit="$unit" \
  --property=Type=exec --property=RuntimeMaxSec=2min \
  --property=StandardOutput=null --property=StandardError=null \
  "$(command -v sing-box)" run -c "${work}/config.json"

for _ in {1..50}; do
  systemctl is-active --quiet "${unit}.service" && break
  sleep 0.1
done
systemctl is-active --quiet "${unit}.service"
old_pid="$(systemctl show -p MainPID --value "${unit}.service")"
[[ "$old_pid" =~ ^[1-9][0-9]*$ ]]

certificate_fingerprint() {
  local transcript="${work}/handshake.$$.txt"
  timeout 10 openssl s_client -connect "127.0.0.1:${port}" \
    -servername localhost -showcerts </dev/null >"$transcript" 2>&1 || true
  awk '/-----BEGIN CERTIFICATE-----/ { copy=1 } copy { print } /-----END CERTIFICATE-----/ { exit }' \
    "$transcript" | openssl x509 -outform DER 2>/dev/null | \
    openssl dgst -sha256 | awk '{print $2}'
}

old_fingerprint="$(certificate_fingerprint)"
[[ -n "$old_fingerprint" ]]
install -m 0600 "${work}/new.pem" "${work}/active.pem.new"
install -m 0600 "${work}/new.key" "${work}/active.key.new"
mv -f -- "${work}/active.pem.new" "${work}/active.pem"
mv -f -- "${work}/active.key.new" "${work}/active.key"

new_fingerprint=""
for _ in {1..50}; do
  new_fingerprint="$(certificate_fingerprint)"
  [[ -n "$new_fingerprint" && "$new_fingerprint" != "$old_fingerprint" ]] && break
  sleep 0.2
done
[[ -n "$new_fingerprint" && "$new_fingerprint" != "$old_fingerprint" ]]
[[ "$(systemctl show -p MainPID --value "${unit}.service")" == "$old_pid" ]]

printf 'Certificate lifecycle smoke test: PASS (same PID %s, certificate watcher observed)\n' "$old_pid"
