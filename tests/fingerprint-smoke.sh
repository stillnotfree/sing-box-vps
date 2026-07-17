#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

(( ${#SUPPORTED_CLIENT_FINGERPRINTS[@]} == 9 ))

parse_args set-fingerprint firefox --yes
[[ "$COMMAND" == "set-fingerprint" ]]
[[ "$NEW_CLIENT_FINGERPRINT" == "firefox" ]]
(( ASSUME_YES == 1 ))

for fingerprint in chrome firefox safari ios android edge 360 qq random; do
  client_fingerprint_is_supported "$fingerprint"
  validate_client_fingerprint "$fingerprint"
done

if (validate_client_fingerprint randomized >/dev/null 2>&1); then
  printf 'randomized unexpectedly passed the cross-client compatibility set\n' >&2
  exit 1
fi

ADMIN_USER="vpnadmin"
ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButStructurallySingleLine test@example"
SERVER_IPV4="203.0.113.10"
TLS_DOMAIN="vpn.example.com"
ACME_EMAIL="admin@example.com"
SSH_PORT="22"
REALITY_TARGET="www.example.com"
COUNTRY_EMOJI="🇩🇪"
CLIENT_FINGERPRINT="random"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
render_settings "${work}/settings.json"
jq -e '
  .schema_version == 1 and
  .client_fingerprint == "random" and
  .reality_target == "www.example.com"
' "${work}/settings.json" >/dev/null

printf 'Fingerprint state smoke test: PASS\n'
