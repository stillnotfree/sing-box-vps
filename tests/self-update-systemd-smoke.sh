#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ "$(uname -s)" != Linux || ! -d /run/systemd/system ]] || \
   ! command -v systemd-run >/dev/null 2>&1; then
  printf 'Self-update systemd lifecycle test: SKIP (real systemd is unavailable)\n'
  exit 0
fi

[[ "$(id -u)" == 0 ]] || {
  printf 'Self-update systemd lifecycle test requires root.\n' >&2
  exit 1
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d /tmp/vpn-self-update-systemd.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT

cat >"${work}/candidate" <<EOF
#!/bin/sh
sleep 3
printf '%s\n' complete >'${work}/worker-complete'
EOF
chmod 0700 "${work}/candidate"

# The sourced launcher resolves this version probe dynamically.
# shellcheck disable=SC2329
(
  # shellcheck disable=SC1091
  source "${repo_root}/install-sing-box-server.sh"
  trap - EXIT ERR
  installed_helper_version() { printf '%s\n' 1.0.10; }
  launch_detached_self_update "${work}/candidate" 1.0.11 "${work}/staging" >/dev/null
  printf '%s\n' handed-off >"${work}/handed-off"
  sleep 30
) &
# shellcheck disable=SC2031
initiator_pid=$!

for _ in {1..100}; do
  # shellcheck disable=SC2031
  [[ -f "${work}/handed-off" ]] && break
  sleep 0.1
done
# shellcheck disable=SC2031
[[ -f "${work}/handed-off" ]] || {
  printf 'Transient systemd handoff was not confirmed.\n' >&2
  exit 1
}

kill -HUP "$initiator_pid"
wait "$initiator_pid" 2>/dev/null || true
for _ in {1..150}; do
  # shellcheck disable=SC2031
  [[ -f "${work}/worker-complete" ]] && break
  sleep 0.1
done
# shellcheck disable=SC2031
[[ "$(cat "${work}/worker-complete" 2>/dev/null || true)" == complete ]] || {
  printf 'Detached worker did not survive initiating-session loss.\n' >&2
  exit 1
}
# shellcheck disable=SC2031
[[ -z "$(find "${work}/staging" -mindepth 1 -print -quit)" ]]

printf 'Self-update systemd lifecycle test: PASS\n'
