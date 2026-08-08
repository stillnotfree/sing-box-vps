#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

(( EUID == 0 )) || die 'Firewall syntax smoke test must run as root.'
require_command nft

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

SSH_PORT="2222"
write_firewall_candidate "${work}/vpn-filter.nft"
nft --check --file "${work}/vpn-filter.nft"

printf 'Firewall nftables syntax smoke test: PASS\n'
