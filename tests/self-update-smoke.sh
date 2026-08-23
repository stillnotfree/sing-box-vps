#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"
trap - ERR

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

make_candidate() {
  local output="$1" version="$2" project="${3:-vpn-setup}"
  cat >"$output" <<EOF
#!/usr/bin/env bash
readonly SCRIPT_VERSION="${version}"
readonly PROJECT_NAME="${project}"
exit 0
EOF
  chmod 0700 "$output"
}

make_candidate "${work}/candidate-new" 1.0.11
make_candidate "${work}/candidate-equal" 1.0.10
make_candidate "${work}/candidate-old" 1.0.9
make_candidate "${work}/candidate-wrong-project" 1.0.11 other-project
cat >"${work}/candidate-invalid" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.0.11"
readonly PROJECT_NAME="vpn-setup"
if
EOF

portable_install() {
  local directory=0 mode="" source_file="" destination=""
  while (( $# > 0 )); do
    case "$1" in
      -d) directory=1; shift ;;
      -o|-g) shift 2 ;;
      -m) mode="$2"; shift 2 ;;
      *)
        if [[ -z "$source_file" ]]; then
          source_file="$1"
        elif [[ -z "$destination" ]]; then
          destination="$1"
        else
          source_file="$destination"
          destination="$1"
        fi
        shift
        ;;
    esac
  done
  if (( directory == 1 )); then
    destination="${destination:-$source_file}"
    mkdir -p "$destination"
    [[ -z "$mode" ]] || chmod "$mode" "$destination"
  else
    cp "$source_file" "$destination"
    [[ -z "$mode" ]] || chmod "$mode" "$destination"
  fi
}

(
  trap - EXIT ERR
  COMMAND=plan
  SELF_UPDATE_SOURCE=""
  ASSUME_YES=0
  parse_args self-update --yes
  [[ "$COMMAND" == self-update ]]
  [[ -z "$SELF_UPDATE_SOURCE" ]]
  (( ASSUME_YES == 1 ))
)
(
  trap - EXIT ERR
  COMMAND=plan
  SELF_UPDATE_SOURCE=""
  parse_args self-update "${work}/candidate-new" --yes
  [[ "$SELF_UPDATE_SOURCE" == "${work}/candidate-new" ]]
)

# Test doubles are resolved dynamically by functions sourced from the installer.
# shellcheck disable=SC2329
run_self_update_case() (
  trap - EXIT ERR
  local network_mode="$1" installed_version="$2" release_candidate="$3"
  local case_root checksum
  case_root="$(mktemp -d "${work}/case.XXXXXX")"
  mkdir -p "${case_root}/temp"
  TEMP_ROOT="${case_root}/temp"
  TMP_DIR=""
  SELF_UPDATE_SOURCE=""
  ASSUME_YES=1

  require_root() { :; }
  require_command() { :; }
  acquire_operation_lock() { :; }
  flock() { :; }
  installed_helper_version() { printf '%s\n' "$installed_version"; }
  dpkg() {
    local left operator right left_patch right_patch
    case "$1" in
      --validate-version)
        [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
        ;;
      --compare-versions)
        left="$2"
        operator="$3"
        right="$4"
        left_patch="${left##*.}"
        right_patch="${right##*.}"
        case "$operator" in
          lt) (( left_patch < right_patch )) ;;
          eq) (( left_patch == right_patch )) ;;
          gt) (( left_patch > right_patch )) ;;
          *) return 2 ;;
        esac
        ;;
      *) return 2 ;;
    esac
  }
  portable_sha256sum() {
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$@"
    elif type -P sha256sum >/dev/null 2>&1; then
      command sha256sum "$@"
    else
      return 127
    fi
  }
  sha256sum() { portable_sha256sum "$@"; }
  launch_detached_self_update() {
    local candidate="$1" version="$2"
    printf '%s\n' "$version" >"${case_root}/launched-version"
    cp "$candidate" "${case_root}/launched-candidate"
  }
  curl() {
    local destination="" url="${!#}"
    while (( $# > 0 )); do
      case "$1" in
        --output)
          destination="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    if [[ "$network_mode" == download-failure ]] || \
       [[ "$network_mode" == installer-missing && "$url" == */install-sing-box-server.sh ]] || \
       [[ "$network_mode" == checksum-missing && "$url" == */install-sing-box-server.sh.sha256 ]]; then
      printf '%s\n' 'mocked network failure' >&2
      return 22
    fi
    case "$url" in
      */install-sing-box-server.sh)
        cp "$release_candidate" "$destination"
        ;;
      */install-sing-box-server.sh.sha256)
        case "$network_mode" in
          malformed-checksum)
            printf '%s\n' 'not-a-checksum' >"$destination"
            ;;
          checksum-mismatch)
            printf '%064d  install-sing-box-server.sh\n' 0 >"$destination"
            ;;
          *)
            checksum="$(portable_sha256sum "$release_candidate" | awk '{ print $1 }')"
            printf '%s  install-sing-box-server.sh\n' "$checksum" >"$destination"
            ;;
        esac
        ;;
      *) return 22 ;;
    esac
  }

  self_update_from_file
  if [[ -e "${case_root}/launched-version" ]]; then
    cat "${case_root}/launched-version"
  fi
)

success_output="$(run_self_update_case success 1.0.10 "${work}/candidate-new")"
grep -Fxq '1.0.11' <<<"$success_output"

download_body="$(declare -f download_self_update_asset)"
grep -Fq -- "--proto '=https'" <<<"$download_body"
grep -Fq -- '--connect-timeout 10' <<<"$download_body"
grep -Fq -- '--max-time 120' <<<"$download_body"
# shellcheck disable=SC2016 # Match the literal function parameter.
grep -Fq -- '--max-filesize "$max_bytes"' <<<"$download_body"

for failure_case in malformed-checksum checksum-mismatch download-failure \
  installer-missing checksum-missing
do
  if failure_output="$(run_self_update_case "$failure_case" 1.0.10 "${work}/candidate-new" 2>&1)"; then
    printf 'Automatic self-update unexpectedly passed: %s\n' "$failure_case" >&2
    exit 1
  fi
  [[ "$failure_output" != *$'\n1.0.11\n'* ]]
done

equal_output="$(run_self_update_case success 1.0.10 "${work}/candidate-equal")"
grep -Fq 'already matches the selected candidate; no changes were made' <<<"$equal_output"
[[ "$equal_output" != *$'\n1.0.10\n'* ]]

if downgrade_output="$(run_self_update_case success 1.0.10 "${work}/candidate-old" 2>&1)"; then
  printf 'Automatic self-update accepted a downgrade.\n' >&2
  exit 1
fi
grep -Fq 'Refusing installer downgrade from 1.0.10 to 1.0.9' <<<"$downgrade_output"

for invalid_candidate in candidate-wrong-project candidate-invalid; do
  if invalid_output="$(run_self_update_case success 1.0.10 "${work}/${invalid_candidate}" 2>&1)"; then
    printf 'Invalid automatic candidate unexpectedly reached launch: %s\n' "$invalid_candidate" >&2
    exit 1
  fi
  [[ "$invalid_output" != *$'\n1.0.11\n'* ]]
done

# Explicit local-file mode retains the same candidate validation and detached
# handoff, but intentionally does not require a sidecar checksum.
# shellcheck disable=SC2034,SC2329
local_mode_output="$( (
  trap - EXIT ERR
  case_root="$(mktemp -d "${work}/local.XXXXXX")"
  mkdir -p "${case_root}/temp"
  TEMP_ROOT="${case_root}/temp"
  TMP_DIR=""
  SELF_UPDATE_SOURCE="${work}/candidate-new"
  ASSUME_YES=1
  require_root() { :; }
  require_command() { :; }
  acquire_operation_lock() { :; }
  flock() { :; }
  install() { portable_install "$@"; }
  installed_helper_version() { printf '%s\n' 1.0.10; }
  dpkg() {
    if [[ "$1" == --validate-version ]]; then
      return 0
    fi
    if [[ "$1" == --compare-versions && "$3" == lt ]]; then
      return 1
    fi
    if [[ "$1" == --compare-versions && "$3" == eq ]]; then
      return 1
    fi
    return 2
  }
  curl() { printf 'Local mode unexpectedly used the network.\n' >&2; return 1; }
  launch_detached_self_update() { printf 'LOCAL-LAUNCH:%s\n' "$2"; }
  self_update_from_file
) 2>&1)"
grep -Fq 'LOCAL-LAUNCH:1.0.11' <<<"$local_mode_output"
grep -Fq 'Local candidate passed syntax, project identity, and version validation.' \
  <<<"$local_mode_output"
[[ "$local_mode_output" != *'Release checksum matched'* ]]

# The POSIX detached runner must preserve numeric child statuses. In
# particular, its outcome labels must never overwrite the shell status used by
# the final exit, and cleanup/signals must still produce a numeric result.
runner_root="${work}/runner-regressions"
mkdir -p "$runner_root"
cat >"${runner_root}/success-candidate" <<'EOF'
#!/bin/sh
printf '%s\n' 'candidate completed' >&2
exit 0
EOF
cat >"${runner_root}/failure-candidate" <<'EOF'
#!/bin/sh
printf '%s\n' 'candidate failed' >&2
exit 7
EOF
cat >"${runner_root}/cleanup-candidate" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" >'${runner_root}/candidate.pid'
while :; do sleep 1; done
EOF
chmod 0700 "${runner_root}"/*-candidate

make_pending_self_outcome() {
  local output="$1"
  mkdir -p "$(dirname "$output")"
  printf '%s\n' \
    operation=self-update status=pending started=2026-08-20T20:00:00Z \
    completed= old_version=1.0.10 candidate_version=1.0.11 \
    unit=vpn-self-update-test exit_status= diagnostic= detail=pending >"$output"
}

success_job="${runner_root}/success-job"
mkdir -p "$success_job"
make_pending_self_outcome "${runner_root}/success.status"
render_self_update_runner "${success_job}/runner"
chmod 0500 "${success_job}/runner"
if success_runner_output="$("${success_job}/runner" \
    "${runner_root}/success-candidate" "$success_job" \
    "${runner_root}/success.status" 1.0.10 1.0.11 vpn-self-update-test \
    "${runner_root}/success.log" 2>&1)"; then
  success_runner_status=0
else
  success_runner_status=$?
fi
(( success_runner_status == 0 ))
grep -Fxq 'status=success' "${runner_root}/success.status"
grep -Fxq 'exit_status=0' "${runner_root}/success.status"
grep -Fq 'candidate completed' "${runner_root}/success.log"
[[ "$success_runner_output" != *'Illegal number'* ]]

failure_job="${runner_root}/failure-job"
mkdir -p "$failure_job"
make_pending_self_outcome "${runner_root}/failure.status"
render_self_update_runner "${failure_job}/runner"
chmod 0500 "${failure_job}/runner"
if failure_runner_output="$("${failure_job}/runner" \
    "${runner_root}/failure-candidate" "$failure_job" \
    "${runner_root}/failure.status" 1.0.10 1.0.11 vpn-self-update-test \
    "${runner_root}/failure.log" 2>&1)"; then
  failure_runner_status=0
else
  failure_runner_status=$?
fi
(( failure_runner_status == 7 ))
grep -Fxq 'status=failure' "${runner_root}/failure.status"
grep -Fxq 'exit_status=7' "${runner_root}/failure.status"
grep -Fq 'candidate failed' "${runner_root}/failure.log"
[[ "$failure_runner_output" != *'Illegal number'* ]]

cleanup_job="${runner_root}/cleanup-job"
mkdir -p "$cleanup_job"
make_pending_self_outcome "${runner_root}/cleanup.status"
render_self_update_runner "${cleanup_job}/runner"
chmod 0500 "${cleanup_job}/runner"
"${cleanup_job}/runner" "${runner_root}/cleanup-candidate" "$cleanup_job" \
  "${runner_root}/cleanup.status" 1.0.10 1.0.11 vpn-self-update-test \
  "${runner_root}/cleanup.log" >"${runner_root}/cleanup.output" 2>&1 &
cleanup_pid=$!
for _ in {1..40}; do
  [[ -s "${runner_root}/candidate.pid" ]] && break
  sleep 0.05
done
kill -TERM "$cleanup_pid"
if wait "$cleanup_pid"; then
  cleanup_status=0
else
  cleanup_status=$?
fi
kill "$(<"${runner_root}/candidate.pid")" 2>/dev/null || true
(( cleanup_status == 1 ))
grep -Fxq 'status=failure' "${runner_root}/cleanup.status"
grep -Fxq 'exit_status=1' "${runner_root}/cleanup.status"
[[ "$(<"${runner_root}/cleanup.output")" != *'Illegal number'* ]]

# Portable lifecycle proof: the mocked systemd boundary returns only after it
# has launched the staged runner. Killing the initiating process afterward does
# not kill the worker. The separate Linux test below covers real systemd.
lifecycle_root="${work}/lifecycle"
mkdir -p "$lifecycle_root"
cat >"${lifecycle_root}/candidate" <<EOF
#!/bin/sh
release_gate='${lifecycle_root}/release-worker'
attempt=0
while [ ! -e "\$release_gate" ] && [ "\$attempt" -lt 100 ]; do
  attempt=\$((attempt + 1))
  sleep 0.05
done
[ -e "\$release_gate" ] || exit 124
printf '%s\n' complete >'${lifecycle_root}/worker-complete'
EOF
chmod 0700 "${lifecycle_root}/candidate"
# shellcheck disable=SC2329
(
  trap - EXIT ERR
  install() { portable_install "$@"; }
  installed_helper_version() { printf '%s\n' 1.0.10; }
  systemd-run() {
    printf '%s\n' "$@" >"${lifecycle_root}/systemd-run.args"
    while [[ "$1" == --* ]]; do shift; done
    "$@" >/dev/null 2>&1 &
  }
  launch_detached_self_update "${lifecycle_root}/candidate" 1.0.11 \
    "${lifecycle_root}/staging" >/dev/null
  printf '%s\n' handed-off >"${lifecycle_root}/handed-off"
  sleep 30
) &
initiator_pid=$!
for _ in {1..50}; do
  [[ -f "${lifecycle_root}/handed-off" ]] && break
  sleep 0.1
done
[[ -f "${lifecycle_root}/handed-off" ]]
staged_job="$(find "${lifecycle_root}/staging" -mindepth 1 -maxdepth 1 \
  -type d -name 'job.*' -print -quit)"
[[ -n "$staged_job" ]]
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
[[ "$(file_mode "${lifecycle_root}/staging")" == 700 ]]
[[ "$(file_mode "$staged_job")" == 700 ]]
[[ "$(file_mode "${staged_job}/installer")" == 500 ]]
[[ "$(file_mode "${staged_job}/runner")" == 500 ]]
kill -TERM "$initiator_pid"
wait "$initiator_pid" 2>/dev/null || true
: >"${lifecycle_root}/release-worker"
for _ in {1..60}; do
  [[ -f "${lifecycle_root}/worker-complete" ]] && break
  sleep 0.1
done
[[ "$(cat "${lifecycle_root}/worker-complete")" == complete ]]
for _ in {1..60}; do
  outcome_file="$(find "${lifecycle_root}/staging.outcomes" -maxdepth 1 -type f \
    -name '*.status' -print -quit)"
  if [[ -n "$outcome_file" ]] && grep -Fxq 'status=success' "$outcome_file" &&
     [[ -z "$(find "${lifecycle_root}/staging" -mindepth 1 -print -quit)" ]]; then
    break
  fi
  sleep 0.1
done
grep -Fxq -- '--property=Type=exec' "${lifecycle_root}/systemd-run.args"
grep -Fxq -- '--property=RuntimeMaxSec=45min' "${lifecycle_root}/systemd-run.args"
grep -Fxq -- '--property=StandardOutput=null' "${lifecycle_root}/systemd-run.args"
grep -Fxq -- '--property=StandardError=null' "${lifecycle_root}/systemd-run.args"
[[ -z "$(find "${lifecycle_root}/staging" -mindepth 1 -print -quit)" ]]
outcome_file="$(find "${lifecycle_root}/staging.outcomes" -maxdepth 1 -type f \
  -name '*.status' -print -quit)"
[[ -n "$outcome_file" ]]
grep -Fxq 'operation=self-update' "$outcome_file"
grep -Fxq 'status=success' "$outcome_file"
grep -Fxq 'old_version=1.0.10' "$outcome_file"
grep -Fxq 'candidate_version=1.0.11' "$outcome_file"

# The shared deferred worker waits for the exact accepted TCP socket identity,
# not a command/session PID. A reconnect with the same tuple but a different
# kernel cookie/inode does not keep the originating transport alive.
deferred_worker_root="${work}/deferred-worker"
deferred_job="${deferred_worker_root}/job.test"
mkdir -p "$deferred_job" "${deferred_worker_root}/outcomes" "${deferred_worker_root}/bin"
cat >"${deferred_job}/metadata" <<'EOF'
operation=client-delete
description=test deferred delete
created=2026-08-20T20:00:00Z
transport_local=203.0.113.10:22
transport_remote=203.0.113.10:50122
transport_cookie=a1b2c3
transport_inode=98765
EOF
cat >"${deferred_worker_root}/helper" <<EOF
#!/bin/sh
[ "\$1" = deferred-activate ]
printf '%s\n' activated >'${deferred_worker_root}/activated'
EOF
chmod 0700 "${deferred_worker_root}/helper"
cat >"${deferred_worker_root}/bin/ss" <<EOF
#!/bin/sh
if [ -e '${deferred_worker_root}/hold-origin' ]; then
  printf '%s\n' 'ESTAB 0 0 203.0.113.10:22 203.0.113.10:50122 uid:0 ino:98765 sk:a1b2c3'
else
  printf '%s\n' 'ESTAB 0 0 203.0.113.10:22 203.0.113.10:50122 uid:0 ino:98766 sk:d4e5f6'
  printf '%s\n' 'ESTAB 0 0 203.0.113.10:22 198.51.100.30:50123 uid:0 ino:98767 sk:112233'
fi
EOF
chmod 0700 "${deferred_worker_root}/bin/ss"
touch "${deferred_worker_root}/hold-origin"
render_deferred_mutation_runner "${deferred_job}/runner"
chmod 0500 "${deferred_job}/runner"
PATH="${deferred_worker_root}/bin:${PATH}" \
"${deferred_job}/runner" "$deferred_job" \
  "${deferred_worker_root}/outcomes/result.status" vpn-deferred-test \
  "${deferred_worker_root}/helper" >/dev/null 2>&1 &
worker_pid=$!
sleep 0.2
[[ ! -e "${deferred_worker_root}/activated" ]]
rm -f -- "${deferred_worker_root}/hold-origin"
wait "$worker_pid"
[[ "$(<"${deferred_worker_root}/activated")" == activated ]]
grep -Fxq 'status=success' "${deferred_worker_root}/outcomes/result.status"
[[ ! -e "$deferred_job" ]]

# A worker created by a newer candidate must invoke the staged candidate
# activator even when the installed helper rejects deferred-activate.
candidate_deferred_root="${work}/candidate-deferred"
candidate_deferred_job="${candidate_deferred_root}/job.compatible"
mkdir -p "$candidate_deferred_job" "${candidate_deferred_root}/outcomes" \
  "${candidate_deferred_root}/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${candidate_deferred_root}/bin/ss"
chmod 0700 "${candidate_deferred_root}/bin/ss"
  printf '%s\n' \
    operation=overlay-upgrade \
    description='test candidate-compatible deferred activation' \
    created=2026-08-20T20:00:00Z \
    transport_local=203.0.113.10:22 \
    transport_remote=203.0.113.10:50122 \
    transport_cookie=a1b2c3 \
    transport_inode=98765 >"${candidate_deferred_job}/metadata"
  printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n' 'old helper was incorrectly used' >'${candidate_deferred_root}/old-helper-used'" \
    'exit 64' >"${candidate_deferred_root}/old-helper"
  printf '%s\n' \
    '#!/bin/sh' \
    "[ \"\$1\" = deferred-activate ]" \
    "printf '%s\\n' activated >'${candidate_deferred_root}/activated'" \
    'exit 0' >"${candidate_deferred_root}/candidate-activator"
  chmod 0700 "${candidate_deferred_root}/old-helper" "${candidate_deferred_root}/candidate-activator"
  render_deferred_mutation_runner "${candidate_deferred_job}/runner"
  chmod 0500 "${candidate_deferred_job}/runner"
  PATH="${candidate_deferred_root}/bin:${PATH}" \
  "${candidate_deferred_job}/runner" "$candidate_deferred_job" \
    "${candidate_deferred_root}/outcomes/compatible.status" vpn-deferred-test \
    "${candidate_deferred_root}/old-helper" \
    "${candidate_deferred_root}/candidate-activator" \
    "${candidate_deferred_root}/outcomes/compatible.log" >/dev/null 2>&1 &
  candidate_worker_pid=$!
  if wait "$candidate_worker_pid"; then
    candidate_worker_status=0
  else
    candidate_worker_status=$?
  fi
  (( candidate_worker_status == 0 ))
  [[ "$(<"${candidate_deferred_root}/activated")" == activated ]]
  [[ ! -e "${candidate_deferred_root}/old-helper-used" ]]
  grep -Fxq 'status=success' "${candidate_deferred_root}/outcomes/compatible.status"
  grep -Fxq 'exit_status=0' "${candidate_deferred_root}/outcomes/compatible.status"
  [[ ! -e "$candidate_deferred_job" ]]

# Deferred failures retain their numeric status and bounded diagnostics.
deferred_failure_root="${work}/deferred-failure"
deferred_failure_job="${deferred_failure_root}/job.failure"
mkdir -p "$deferred_failure_job" "${deferred_failure_root}/outcomes" \
  "${deferred_failure_root}/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${deferred_failure_root}/bin/ss"
chmod 0700 "${deferred_failure_root}/bin/ss"
  printf '%s\n' \
    operation=client-delete description='test deferred failure' \
    created=2026-08-20T20:00:00Z \
    transport_local=203.0.113.10:22 \
    transport_remote=203.0.113.10:50122 \
    transport_cookie=a1b2c3 \
    transport_inode=98765 >"${deferred_failure_job}/metadata"
  printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n' 'deferred activation failed' >&2" \
    'exit 9' >"${deferred_failure_root}/failing-helper"
  chmod 0700 "${deferred_failure_root}/failing-helper"
  render_deferred_mutation_runner "${deferred_failure_job}/runner"
  chmod 0500 "${deferred_failure_job}/runner"
  PATH="${deferred_failure_root}/bin:${PATH}" \
  "${deferred_failure_job}/runner" "$deferred_failure_job" \
    "${deferred_failure_root}/outcomes/failure.status" vpn-deferred-test \
    "${deferred_failure_root}/failing-helper" '' \
    "${deferred_failure_root}/outcomes/failure.log" >/dev/null 2>&1 &
  failure_worker_pid=$!
  if wait "$failure_worker_pid"; then
    failure_worker_status=0
  else
    failure_worker_status=$?
  fi
  (( failure_worker_status == 9 ))
  grep -Fxq 'status=failure' "${deferred_failure_root}/outcomes/failure.status"
  grep -Fxq 'exit_status=9' "${deferred_failure_root}/outcomes/failure.status"
  grep -Fq 'deferred activation failed' "${deferred_failure_root}/outcomes/failure.log"

# A failed handoff must remove its private staged job and report that no update
# is running.
failure_staging="${work}/failed-handoff"
# shellcheck disable=SC2329
if failed_handoff_output="$( (
  trap - EXIT ERR
  install() { portable_install "$@"; }
  systemd-run() { return 1; }
  launch_detached_self_update "${work}/candidate-new" 1.0.11 "$failure_staging"
) 2>&1)"; then
  printf 'Failed transient-unit handoff unexpectedly succeeded.\n' >&2
  exit 1
fi
grep -Fq 'no upgrade is running' <<<"$failed_handoff_output"
[[ -z "$(find "$failure_staging" -mindepth 1 -print -quit)" ]]

# The detached worker still uses the existing overlay transaction. Inject a
# failure after every managed file, including the helper, has been replaced and
# prove exact restoration. Settings and clients must remain byte-for-byte
# untouched because the overlay does not regenerate them.
rollback_root="${work}/upgrade-rollback"
mkdir -p "$rollback_root"
rollback_installer="${rollback_root}/installer.sh"
cp "${repo_root}/install-sing-box-server.sh" "$rollback_installer"
for mapping in \
  "UDP_SYSCTL_FILE:${rollback_root}/udp.conf" \
  "UNATTENDED_UPGRADES_CONFIG:${rollback_root}/unattended.conf" \
  "CERT_HOOK:${rollback_root}/certificate-hook" \
  "INSTALLED_HELPER:${rollback_root}/vpn-helper" \
  "USER_COMMAND:${rollback_root}/vpn-command" \
  "INSTALL_COMPLETE_FILE:${rollback_root}/install.complete" \
  "RUNTIME_VERSION_FILE:${rollback_root}/runtime.version" \
  "SETTINGS_FILE:${rollback_root}/settings.json" \
  "CLIENTS_FILE:${rollback_root}/clients.json" \
  "CONFIG_FILE:${rollback_root}/config.json" \
  "SUBSCRIPTION_ROOT:${rollback_root}/subscriptions" \
  "HY2_MASQUERADE_ROOT:${rollback_root}/hy2-masquerade"
do
  constant="${mapping%%:*}"
  path="${mapping#*:}"
  sed -i.bak "s|^readonly ${constant}=.*|readonly ${constant}=\"${path}\"|" \
    "$rollback_installer"
  rm -f -- "${rollback_installer}.bak"
done

bash -c '
  set -Eeuo pipefail
  installer=$1
  root=$2
  # shellcheck disable=SC1090
  source "$installer"
  trap - EXIT ERR

  install() {
    directory=0
    mode=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) directory=1; shift ;;
        -o|-g) shift 2 ;;
        -m) mode=$2; shift 2 ;;
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
  chown() { :; }
  sysctl() {
    if [ "$1" = -n ]; then
      case "$2" in
        net.core.rmem_max) printf "%s\n" 111111 ;;
        net.core.wmem_max) printf "%s\n" 222222 ;;
        *) return 1 ;;
      esac
      return
    fi
    if [ "$1" = -q ] && [ "$2" = -w ]; then
      printf "%s\n" "$3" >>"${root}/sysctl-restores"
      return
    fi
    return 1
  }
  sing-box() { return 0; }
  systemctl() {
    printf "%s|%s\n" "${1:-}" "${2:-}" >>"${root}/systemctl.calls"
    return 0
  }
  subscription_service_healthy() { return 0; }

  for file in "$UDP_SYSCTL_FILE" "$UNATTENDED_UPGRADES_CONFIG" \
    "$CERT_HOOK" "$INSTALLED_HELPER" "$USER_COMMAND" \
    "$INSTALL_COMPLETE_FILE" "$RUNTIME_VERSION_FILE" \
    "$SETTINGS_FILE" "$CLIENTS_FILE"
  do
    printf "original:%s\n" "$(basename "$file")" >"$file"
    cp "$file" "${file}.expected"
  done
  printf "%s\n" original:config >"$CONFIG_FILE"
  mkdir -p "$SUBSCRIPTION_ROOT" "$HY2_MASQUERADE_ROOT"
  printf "%s\n" original:subscription >"${SUBSCRIPTION_ROOT}/token.links"
  printf "%s\n" original:masquerade >"${HY2_MASQUERADE_ROOT}/index.html"
  cp -a -- "$SUBSCRIPTION_ROOT" "${SUBSCRIPTION_ROOT}.expected"
  cp -a -- "$HY2_MASQUERADE_ROOT" "${HY2_MASQUERADE_ROOT}.expected"

  prepare_upgrade_transaction
  for file in "$UDP_SYSCTL_FILE" "$UNATTENDED_UPGRADES_CONFIG" \
    "$CERT_HOOK" "$INSTALLED_HELPER" "$USER_COMMAND" \
    "$INSTALL_COMPLETE_FILE" "$RUNTIME_VERSION_FILE" "$CONFIG_FILE"
  do
    printf "replacement:%s\n" "$(basename "$file")" >"$file"
  done
  printf "%s\n" replacement:subscription >"${SUBSCRIPTION_ROOT}/token.links"
  printf "%s\n" replacement:masquerade >"${HY2_MASQUERADE_ROOT}/index.html"
  rollback_upgrade_transaction >/dev/null 2>&1
  for file in "$UDP_SYSCTL_FILE" "$UNATTENDED_UPGRADES_CONFIG" \
    "$CERT_HOOK" "$INSTALLED_HELPER" "$USER_COMMAND" \
    "$INSTALL_COMPLETE_FILE" "$RUNTIME_VERSION_FILE" \
    "$SETTINGS_FILE" "$CLIENTS_FILE"
  do
    cmp -s "$file" "${file}.expected"
  done
  cmp -s "$CONFIG_FILE" <(printf "%s\n" original:config)
  diff -qr -- "$SUBSCRIPTION_ROOT" "${SUBSCRIPTION_ROOT}.expected" >/dev/null
  diff -qr -- "$HY2_MASQUERADE_ROOT" "${HY2_MASQUERADE_ROOT}.expected" >/dev/null
  grep -Fxq net.core.rmem_max=111111 "${root}/sysctl-restores"
  grep -Fxq net.core.wmem_max=222222 "${root}/sysctl-restores"
  (( UPGRADE_ROLLBACK_ACTIVE == 0 ))
  (( UPGRADE_ROLLBACK_FAILED == 0 ))
  grep -Fxq "restart|sing-box.service" "${root}/systemctl.calls"
  rm -rf -- "$UPGRADE_BACKUP_DIR"

  UPGRADE_BACKUP_DIR="${root}/incomplete-rollback"
  mkdir -p "$UPGRADE_BACKUP_DIR"
  UPGRADE_ROLLBACK_ACTIVE=1
  UPGRADE_ROLLBACK_FAILED=0
  restore_upgrade_file() { return 1; }
  rollback_upgrade_transaction >/dev/null 2>&1
  (( UPGRADE_ROLLBACK_ACTIVE == 0 ))
  (( UPGRADE_ROLLBACK_FAILED == 1 ))
  [[ -d "$UPGRADE_BACKUP_DIR" ]]
' _ "$rollback_installer" "$rollback_root"

printf 'Self-update smoke test: PASS\n'
