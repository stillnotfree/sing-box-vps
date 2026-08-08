#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-${repo_root}/install-sing-box-server.sh}"
staged="$(mktemp "${output}.XXXXXX")"
trap 'rm -f -- "$staged"' EXIT

readonly -a modules=(
  src/00-preamble.sh
  src/10-runtime-cli.sh
  src/20-validation-settings.sh
  src/30-preflight-packages.sh
  src/40-system-tls.sh
  src/50-core-clients.sh
  src/60-helper-firewall-ssh.sh
  src/70-update-health.sh
  src/80-upgrade-install.sh
  src/90-main.sh
)

for module in "${modules[@]}"; do
  [[ -f "${repo_root}/${module}" ]] || {
    printf 'Missing installer module: %s\n' "$module" >&2
    exit 1
  }
  sed -n '1,$p' "${repo_root}/${module}" >>"$staged"
done

chmod 0755 "$staged"
mv -f -- "$staged" "$output"
trap - EXIT
printf 'Generated %s\n' "$output"
