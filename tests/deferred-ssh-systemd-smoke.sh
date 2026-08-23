#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ "$(uname -s)" != Linux || ! -d /run/systemd/system ]] ||
   ! command -v systemd-run >/dev/null 2>&1 ||
   ! command -v sshd >/dev/null 2>&1 ||
   ! command -v ss >/dev/null 2>&1; then
  printf 'Deferred SSH transport lifecycle test: SKIP (real Linux/OpenSSH/systemd is unavailable)\n'
  exit 0
fi

sshd_path="$(command -v sshd)"
[[ "$sshd_path" == /* && -x "$sshd_path" ]] || {
  printf 'Deferred SSH transport lifecycle test: SKIP (sshd path is not absolute and executable)\n' >&2
  exit 0
}

[[ "$(id -u)" == 0 ]] || {
  printf 'Deferred SSH transport lifecycle test requires root.\n' >&2
  exit 1
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d /tmp/vpn-deferred-ssh-systemd.XXXXXX)"
sshd_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$sshd_pid" ]]; then
    kill "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "${work}/host-key"
ssh-keygen -q -t ed25519 -N '' -f "${work}/client-key"
cp "${work}/client-key.pub" "${work}/authorized_keys"

ssh_port=""
for candidate_port in {22022..22121}; do
  if ! ss -Hltn | awk -v port=":${candidate_port}" '$4 ~ (port "$") { found=1 } END { exit found ? 0 : 1 }'; then
    ssh_port="$candidate_port"
    break
  fi
done
[[ -n "$ssh_port" ]] || {
  printf 'No private loopback port was available for the OpenSSH lifecycle test.\n' >&2
  exit 1
}

cat >"${work}/sshd_config" <<EOF
Port ${ssh_port}
ListenAddress 127.0.0.1
HostKey ${work}/host-key
PidFile ${work}/sshd.pid
AuthorizedKeysFile ${work}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
StrictModes no
LogLevel ERROR
EOF

mkdir -p /run/sshd
"$sshd_path" -D -e -f "${work}/sshd_config" >"${work}/sshd.log" 2>&1 &
sshd_pid=$!
for _ in {1..100}; do
  if ss -Hltn | awk -v port=":${ssh_port}" '$4 ~ (port "$") { found=1 } END { exit found ? 0 : 1 }'; then
    break
  fi
  sleep 0.05
done
kill -0 "$sshd_pid"

ssh_base=(
  ssh -F /dev/null -i "${work}/client-key" -p "$ssh_port"
  -o BatchMode=yes -o ControlMaster=no -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

cat >"${work}/remote-harness" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case_root=$1
unit=$2
ssh_port=$3
repo_root=$4
# shellcheck disable=SC1090
source "${repo_root}/install-sing-box-server.sh"
trap - ERR EXIT
SERVER_IPV4=127.0.0.1
SSH_PORT="$ssh_port"
classify_management_ssh_session
[[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]
[[ -n "$MANAGEMENT_TRANSPORT_SOCKET_COOKIE" ]]
mkdir -p "${case_root}/job" "${case_root}/outcomes"
cat >"${case_root}/job/metadata" <<EOF_METADATA
operation=client-delete
description=real OpenSSH transport lifecycle
created=2026-08-23T00:00:00Z
transport_local=${MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT}
transport_remote=${MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT}
transport_cookie=${MANAGEMENT_TRANSPORT_SOCKET_COOKIE}
transport_inode=${MANAGEMENT_TRANSPORT_SOCKET_INODE}
EOF_METADATA
cat >"${case_root}/helper" <<EOF_HELPER
#!/bin/sh
printf '%s\n' activated >'${case_root}/activated'
EOF_HELPER
chmod 0700 "${case_root}/helper"
render_deferred_mutation_runner "${case_root}/job/runner"
chmod 0500 "${case_root}/job/runner"
systemd-run --quiet --collect --unit="$unit" --property=Type=exec \
  --property=RuntimeMaxSec=2min --property=StandardOutput=null \
  --property=StandardError=null "${case_root}/job/runner" \
  "${case_root}/job" "${case_root}/outcomes/result.status" "$unit" \
  "${case_root}/helper"
printf '%s\n' queued >"${case_root}/queued"
sleep 4
EOF
chmod 0700 "${work}/remote-harness"

wait_for_file() {
  local file="$1" label="$2"
  for _ in {1..120}; do
    [[ -e "$file" ]] && return 0
    sleep 0.05
  done
  printf 'Timed out waiting for %s.\n' "$label" >&2
  return 1
}

run_case() {
  local name="$1" tty_mode="$2" case_root
  local unit="vpn-deferred-ssh-${name}-$$" origin_pid unrelated_pid
  case_root="${work}/${name}"
  mkdir -p "$case_root"

  "${ssh_base[@]}" -T root@127.0.0.1 \
    "touch '${case_root}/unrelated-ready'; sleep 12" &
  unrelated_pid=$!
  wait_for_file "${case_root}/unrelated-ready" 'unrelated SSH connection'

  "${ssh_base[@]}" "$tty_mode" root@127.0.0.1 \
    "sudo -n '${work}/remote-harness' '${case_root}' '${unit}' '${ssh_port}' '${repo_root}'" &
  origin_pid=$!
  wait_for_file "${case_root}/queued" 'deferred worker handoff'
  sleep 1
  [[ ! -e "${case_root}/activated" ]] || {
    printf 'Deferred activation began while the originating SSH transport was alive (%s).\n' "$name" >&2
    return 1
  }

  wait "$origin_pid"
  wait_for_file "${case_root}/activated" 'activation after originating SSH disconnect'
  wait_for_file "${case_root}/outcomes/result.status" 'durable activation outcome'
  kill -0 "$unrelated_pid"
  grep -Fxq 'status=success' "${case_root}/outcomes/result.status"
  kill "$unrelated_pid" 2>/dev/null || true
  wait "$unrelated_pid" 2>/dev/null || true
}

run_case no-pty -T
run_case pty -tt

printf 'Deferred SSH transport lifecycle test: PASS\n'
