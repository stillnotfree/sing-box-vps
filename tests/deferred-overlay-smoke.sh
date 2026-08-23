#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2317 # Test doubles are invoked indirectly by sourced installer functions.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

script_version_from_file() {
  awk '
    /^readonly SCRIPT_VERSION="[^"]*"$/ && !found {
      value=$0
      sub(/^readonly SCRIPT_VERSION="/, "", value)
      sub(/"$/, "", value)
      found=1
    }
    END { if (found) print value }
  ' "$1"
}

make_fixture() {
  local case_root="$1" fixture mapping constant path
  fixture="${case_root}/installer.sh"
  mkdir -p "$case_root"
  cp "${repo_root}/install-sing-box-server.sh" "$fixture"
  for mapping in \
    "STATE_DIR:${case_root}/state" \
    "CONFIG_DIR:${case_root}/config" \
    "INSTALLED_HELPER:${case_root}/installed-helper" \
    "USER_COMMAND:${case_root}/user-command" \
    "SUBSCRIPTION_ROOT:${case_root}/subscriptions"
  do
    constant="${mapping%%:*}"
    path="${mapping#*:}"
    sed -i.bak "s|^readonly ${constant}=.*|readonly ${constant}=\"${path}\"|" "$fixture"
    rm -f -- "${fixture}.bak"
  done
  printf '%s\n' "$fixture"
}

make_candidate_activator() {
  local output="$1" runtime_file="$2" state_file="$3" invocation_file="$4"
  cat >"$output" <<EOF
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.0.11"
readonly PROJECT_NAME="vpn-setup"
runtime_file="${runtime_file}"
state_file="${state_file}"
invocation_file="${invocation_file}"
if [[ "\${1:-}" != deferred-activate ]]; then
  exit 64
fi
printf '%s\n' invoked >>"\$invocation_file"
printf '%s\n' 1.0.11 >"\$runtime_file"
printf '%s\n' 'completed version=1.0.11' >"\$state_file"
exit 0
EOF
  chmod 0700 "$output"
}

portable_install() {
  local directory=0 mode="" source destination
  while (( $# > 0 )); do
    case "$1" in
      -d) directory=1; shift ;;
      -o|-g) shift 2 ;;
      -m) mode="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  if (( directory == 1 )); then
    for destination in "$@"; do
      mkdir -p "$destination"
      [[ -z "$mode" ]] || chmod "$mode" "$destination"
    done
    return 0
  fi
  source="$1"
  destination="$2"
  mkdir -p "$(dirname -- "$destination")"
  cp "$source" "$destination"
  [[ -z "$mode" ]] || chmod "$mode" "$destination"
}

run_queue_case() (
  local mode="$1" case_root="$2" fixture="$3" candidate_activator="$4"
  local candidate_activator_source="$candidate_activator" queue_mode="$mode"
  # shellcheck disable=SC1090
  source "$fixture"
  trap - EXIT ERR

  mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$SUBSCRIPTION_ROOT"
  printf '%s\n' 'completed version=1.0.10' >"$INSTALL_COMPLETE_FILE"
  printf '%s\n' 1.0.10 >"$RUNTIME_VERSION_FILE"
  cat >"$INSTALLED_HELPER" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.0.10"
readonly PROJECT_NAME="vpn-setup"
exit 0
EOF
  chmod 0750 "$INSTALLED_HELPER"
  cp "$INSTALLED_HELPER" "${case_root}/old-helper.expected"
  TEMP_ROOT="${case_root}/temp"
  mkdir -p "$TEMP_ROOT"

  # shellcheck disable=SC2329 # Called indirectly by sourced installer functions.
  install() {
    local destination="${!#}"
    portable_install "$@"
    if [[ "$destination" == "${INSTALLED_HELPER}.new" ]]; then
      : >"${case_root}/helper-staged"
    fi
  }
  # shellcheck disable=SC2329 # Called indirectly by validate_installer_file.
  dpkg() {
    case "${1:-}" in
      --validate-version) [[ "${2:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
      --compare-versions) return 0 ;;
      *) return 2 ;;
    esac
  }
  # shellcheck disable=SC2329 # Called indirectly by the deferred candidate path.
  sing-box() { return 0; }
  # shellcheck disable=SC2329 # Called indirectly by the deferred candidate path.
  systemctl() {
    printf '%s\n' "$*" >>"${case_root}/systemctl.calls"
    return 0
  }
  # shellcheck disable=SC2329 # Called indirectly by queue_deferred_overlay_upgrade.
  build_sing_box_config() {
    printf '%s\n' '{"deferred_candidate":true}' >"$2"
  }
  # shellcheck disable=SC2329 # Called indirectly by queue_deferred_overlay_upgrade.
  render_subscription_tree() {
    mkdir -p "$2"
    printf '%s\n' candidate >"$2/links.txt"
  }
  # shellcheck disable=SC2329 # Called indirectly by queue_deferred_mutation.
  deferred_job_stage_activator() {
    install -o root -g root -m 0500 "$candidate_activator_source" \
      "${DEFERRED_JOB_DIR}/activator"
  }
  # shellcheck disable=SC2329 # Called indirectly by queue_deferred_mutation.
  systemd-run() {
    printf '%s\n' "$@" >"${case_root}/systemd-run.args"
    [[ "$queue_mode" == success ]]
  }

  # shellcheck disable=SC2034 # Consumed by deferred_job_create from the sourced installer.
  MANAGEMENT_SESSION_CLASS=deferred
  # shellcheck disable=SC2034 # Consumed by deferred_job_create from the sourced installer.
  MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT=203.0.113.10:22
  # shellcheck disable=SC2034 # Consumed by deferred_job_create from the sourced installer.
  MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT=203.0.113.10:50122
  # shellcheck disable=SC2034 # Consumed by deferred_job_create from the sourced installer.
  MANAGEMENT_TRANSPORT_SOCKET_COOKIE=a1b2c3
  # shellcheck disable=SC2034 # Consumed by deferred_job_create from the sourced installer.
  MANAGEMENT_TRANSPORT_SOCKET_INODE=98765
  published_1010_caller() {
    # This is the relevant published 1.0.10 caller contract: candidate
    # upgrade returns successfully after staging a deferred operation.
    queue_deferred_overlay_upgrade
  }

  published_1010_caller >/dev/null
  printf '%s\n' 0 >"${case_root}/old-caller.exit"
)

success_root="${work}/success"
success_fixture="$(make_fixture "$success_root")"
make_candidate_activator "$success_root/candidate-activator" \
  "${success_root}/state/runtime.version" \
  "${success_root}/state/install.complete" \
  "$success_root/activations.log"
run_queue_case success "$success_root" "$success_fixture" \
  "$success_root/candidate-activator"

success_helper="$success_root/installed-helper"
success_runtime="$success_root/state/runtime.version"
success_state="$success_root/state/install.complete"
success_job="$(find "$success_root/state/deferred-mutations" -mindepth 1 -maxdepth 1 \
  -type d -name 'job.*' -print -quit)"
success_outcome="$(find "$success_root/state/operation-outcomes" -maxdepth 1 \
  -type f -name '*.status' -print -quit)"
[[ -n "$success_job" && -d "$success_job" ]]
[[ -n "$success_outcome" ]]
[[ "$(<"$success_root/old-caller.exit")" == 0 ]]
[[ "$(script_version_from_file "$success_helper")" == 1.0.11 ]]
[[ "$(<"$success_runtime")" == 1.0.10 ]]
grep -Fxq 'completed version=1.0.10' "$success_state"
grep -Fxq 'status=pending' "$success_outcome"
grep -Fxq 'old_version=1.0.10' "$success_outcome"
grep -Fxq 'candidate_version=1.0.11' "$success_outcome"
[[ -x "${success_job}/activator" ]]
[[ ! -e "${success_root}/systemctl.calls" ]]
[[ -z "$(find "$success_root/state/installer-backups" -type f -print -quit)" ]]
success_helper_hash="$(sha256sum "$success_helper" | awk '{print $1}')"
grep -Fq "file|${success_helper}|present|${success_helper_hash}" "${success_job}/baseline"

# End the modeled SSH transport and run the exact staged worker. The activator
# records one invocation and advances both managed markers; the runner removes
# the job after the durable success outcome is written.
success_unit="$(sed -n 's/^unit=//p' "${success_job}/metadata" | sed -n '1p')"
success_diagnostic="$(sed -n 's/^diagnostic=//p' "${success_job}/metadata" | sed -n '1p')"
success_outcome="${success_root}/state/operation-outcomes/$(basename "$success_job").status"
mkdir -p "${success_root}/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${success_root}/bin/ss"
chmod 0700 "${success_root}/bin/ss"
if PATH="${success_root}/bin:${PATH}" \
  "${success_job}/runner" "$success_job" "$success_outcome" \
  "$success_unit" "$success_helper" "${success_job}/activator" "$success_diagnostic"; then
  success_worker_status=0
else
  success_worker_status=$?
fi
(( success_worker_status == 0 ))
[[ ! -e "$success_job" ]]
[[ "$(<"$success_runtime")" == 1.0.11 ]]
grep -Fxq 'completed version=1.0.11' "$success_state"
[[ "$(wc -l <"$success_root/activations.log" | tr -d '[:space:]')" == 1 ]]
grep -Fxq 'status=success' "$success_outcome"
grep -Fxq 'exit_status=0' "$success_outcome"
[[ ! -e "${success_root}/systemctl.calls" ]]

failure_root="${work}/failure"
failure_fixture="$(make_fixture "$failure_root")"
make_candidate_activator "$failure_root/candidate-activator" \
  "${failure_root}/state/runtime.version" \
  "${failure_root}/state/install.complete" \
  "$failure_root/activations.log"
if run_queue_case failure "$failure_root" "$failure_fixture" \
  "$failure_root/candidate-activator" >"${failure_root}/caller.output" 2>&1; then
  printf 'Deferred overlay queue failure unexpectedly returned success.\n' >&2
  exit 1
fi

failure_helper="$failure_root/installed-helper"
failure_runtime="$failure_root/state/runtime.version"
failure_state="$failure_root/state/install.complete"
failure_outcome="$(find "$failure_root/state/operation-outcomes" -maxdepth 1 \
  -type f -name '*.status' -print -quit)"
[[ -e "$failure_root/helper-staged" ]]
cmp -s "$failure_root/old-helper.expected" "$failure_helper"
[[ "$(script_version_from_file "$failure_helper")" == 1.0.10 ]]
[[ "$(<"$failure_runtime")" == 1.0.10 ]]
grep -Fxq 'completed version=1.0.10' "$failure_state"
[[ -n "$failure_outcome" ]]
grep -Fxq 'status=failure' "$failure_outcome"
grep -Fxq 'old_version=1.0.10' "$failure_outcome"
grep -Fxq 'candidate_version=1.0.11' "$failure_outcome"
grep -Fq 'no live state was changed' "$failure_outcome"
[[ -z "$(find "$failure_root/state/deferred-mutations" -mindepth 1 -maxdepth 1 \
  -type d -name 'job.*' -print -quit)" ]]
[[ -z "$(find "$failure_root/state/installer-backups" -type f -print -quit)" ]]
[[ ! -e "$failure_root/systemctl.calls" ]]

printf 'Deferred overlay smoke test: PASS\n'
