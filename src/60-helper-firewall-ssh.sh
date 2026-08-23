install_helper() {
  local self version timestamp backup=""
  LAST_HELPER_BACKUP=""
  self="$(readlink -f "$0")"
  version="$(validate_installer_file "$self")"
  [[ "$version" == "$SCRIPT_VERSION" ]] || die 'The running installer version does not match its source file.'

  if [[ -e "$INSTALLED_HELPER" ]]; then
    [[ -f "$INSTALLED_HELPER" && ! -L "$INSTALLED_HELPER" ]] || die "Refusing to replace unexpected helper path: $INSTALLED_HELPER"
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    install -d -o root -g root -m 0700 "$INSTALLER_BACKUP_DIR"
    backup="${INSTALLER_BACKUP_DIR}/vpn-${timestamp}-$(installed_helper_version || printf unknown)"
    install -o root -g root -m 0700 "$INSTALLED_HELPER" "$backup"
  fi

  install -o root -g root -m 0750 "$self" "${INSTALLED_HELPER}.new"
  bash -n "${INSTALLED_HELPER}.new" || {
    rm -f -- "${INSTALLED_HELPER}.new"
    die 'Staged management helper failed bash syntax validation.'
  }
  mv -f -- "${INSTALLED_HELPER}.new" "$INSTALLED_HELPER"
  [[ "$(installed_helper_version)" == "$SCRIPT_VERSION" ]] || die 'Installed management helper reports an unexpected version.'
  install_user_command_wrapper

  if [[ -n "$backup" ]]; then
    find "$INSTALLER_BACKUP_DIR" -maxdepth 1 -type f -name 'vpn-*' -printf '%T@ %p\n' \
      | sort -rn | cut -d' ' -f2- | sed -n '4,$p' | while IFS= read -r obsolete; do
          rm -f -- "$obsolete"
        done
  fi
  LAST_HELPER_BACKUP="$backup"
}

render_user_command_wrapper() {
  local output="$1"
  cat >"$output" <<'EOF'
#!/bin/sh
set -eu

helper=/usr/local/sbin/vpn
if [ "$(id -u)" -eq 0 ]; then
  exec "$helper" "$@"
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf 'vpn: sudo is unavailable\n' >&2
  exit 1
fi

exec sudo -n "$helper" "$@"
EOF
}

install_user_command_wrapper() {
  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    new_temp_dir
  fi
  render_user_command_wrapper "${TMP_DIR}/vpn-command"
  sh -n "${TMP_DIR}/vpn-command"
  install -d -o root -g root -m 0755 "$(dirname "$USER_COMMAND")"
  if [[ -e "$USER_COMMAND" ]]; then
    [[ -f "$USER_COMMAND" && ! -L "$USER_COMMAND" ]] || \
      die "Refusing to replace unexpected command path: $USER_COMMAND"
  fi
  install -o root -g root -m 0755 "${TMP_DIR}/vpn-command" "${USER_COMMAND}.new"
  mv -f -- "${USER_COMMAND}.new" "$USER_COMMAND"
}

restore_installed_helper() {
  local backup="$1"
  [[ -n "$backup" && -r "$backup" ]] || return 1
  install -o root -g root -m 0750 "$backup" "${INSTALLED_HELPER}.restore"
  bash -n "${INSTALLED_HELPER}.restore" || return 1
  mv -f -- "${INSTALLED_HELPER}.restore" "$INSTALLED_HELPER"
}

handoff_deferred_helper() {
  local candidate="$1" candidate_version backup timestamp
  DEFERRED_HELPER_BACKUP=""
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  candidate_version="$(validate_installer_file "$candidate")"
  [[ "$candidate_version" == "$SCRIPT_VERSION" ]] || return 1
  [[ -f "$INSTALLED_HELPER" && ! -L "$INSTALLED_HELPER" ]] || return 1

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  install -d -o root -g root -m 0700 "$INSTALLER_BACKUP_DIR" || return 1
  backup="${INSTALLER_BACKUP_DIR}/vpn-${timestamp}-$(installed_helper_version || printf unknown)"
  install -o root -g root -m 0700 "$INSTALLED_HELPER" "$backup" || return 1
  DEFERRED_HELPER_BACKUP="$backup"

  if ! install -o root -g root -m 0750 "$candidate" "${INSTALLED_HELPER}.new"; then
    rollback_deferred_helper_handoff || true
    return 1
  fi
  if ! bash -n "${INSTALLED_HELPER}.new"; then
    rm -f -- "${INSTALLED_HELPER}.new"
    rollback_deferred_helper_handoff || true
    return 1
  fi
  if ! mv -f -- "${INSTALLED_HELPER}.new" "$INSTALLED_HELPER"; then
    rm -f -- "${INSTALLED_HELPER}.new"
    rollback_deferred_helper_handoff || true
    return 1
  fi
  if [[ "$(installed_helper_version)" != "$candidate_version" ]]; then
    rollback_deferred_helper_handoff || true
    return 1
  fi
}

rollback_deferred_helper_handoff() {
  local backup="${DEFERRED_HELPER_BACKUP:-}"
  [[ -z "$backup" ]] && return 0
  restore_installed_helper "$backup" || return 1
  rm -f -- "$backup"
  DEFERRED_HELPER_BACKUP=""
}

commit_deferred_helper_handoff() {
  local backup="${DEFERRED_HELPER_BACKUP:-}"
  [[ -z "$backup" ]] && return 0
  rm -f -- "$backup" || return 1
  DEFERRED_HELPER_BACKUP=""
}

deferred_job_fail_and_remove() {
  local detail="$1" operation started old_version candidate_version diagnostic
  [[ -n "$DEFERRED_JOB_DIR" && -d "$DEFERRED_JOB_DIR" ]] || return 0
  operation="$(deferred_job_field operation "${DEFERRED_JOB_DIR}/metadata")"
  started="$(deferred_job_field created "${DEFERRED_JOB_DIR}/metadata")"
  old_version="$(deferred_job_field old_version "${DEFERRED_JOB_DIR}/metadata")"
  candidate_version="$(deferred_job_field candidate_version "${DEFERRED_JOB_DIR}/metadata")"
  diagnostic="${OPERATION_OUTCOME_ROOT}/$(basename "$DEFERRED_JOB_DIR").log"
  printf '%s\n' "$detail" >"${diagnostic}.new"
  chmod 0600 "${diagnostic}.new"
  mv -f -- "${diagnostic}.new" "$diagnostic"
  write_operation_outcome "$DEFERRED_OUTCOME_FILE" "$operation" failure \
    "$started" "$(operation_timestamp)" "$old_version" "$candidate_version" '' 1 \
    "$detail" "$diagnostic"
  rm -rf -- "$DEFERRED_JOB_DIR"
  DEFERRED_JOB_DIR=""
}

restore_deferred_helper_or_die() {
  rollback_deferred_helper_handoff || \
    die 'Deferred activation queue failed and the previous management helper could not be restored; recovery state was preserved.'
}

download_self_update_asset() {
  local url="$1" destination="$2" max_bytes="$3" label="$4"
  local partial="${destination}.partial" error_file="${destination}.curl-error"
  rm -f -- "$partial" "$error_file"
  if ! curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
      --connect-timeout 10 --max-time 120 --max-filesize "$max_bytes" \
      --output "$partial" "$url" 2>"$error_file"; then
    warn "Could not download ${label} from the official GitHub Release."
    if [[ -s "$error_file" ]]; then
      LC_ALL=C sed -n '1,5p' "$error_file" >&2
    fi
    rm -f -- "$partial" "$error_file"
    die "Self-update download failed before any managed state was changed: ${label}"
  fi
  [[ -f "$partial" && ! -L "$partial" ]] || \
    die "Self-update download did not produce a regular file: ${label}"
  chmod 0600 "$partial"
  mv -f -- "$partial" "$destination"
  rm -f -- "$error_file"
}

installer_checksum_from_file() {
  local file="$1" line pattern
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || \
    die 'Release checksum asset is not a readable regular file.'
  [[ "$(LC_ALL=C wc -l <"$file" | tr -d '[:space:]')" == "1" ]] || \
    die 'Release checksum asset must contain exactly one newline-terminated record.'
  IFS= read -r line <"$file" || die 'Unable to read the release checksum asset.'
  pattern='^([0-9A-Fa-f]{64})  install-sing-box-server\.sh$'
  [[ "$line" =~ $pattern ]] || \
    die 'Release checksum asset has an invalid format or filename.'
  printf '%s\n' "${BASH_REMATCH[1]}" | tr 'A-F' 'a-f'
}

prune_self_update_staging() {
  local staging_root="$1" stale
  [[ -d "$staging_root" && ! -L "$staging_root" ]] || return 0
  while IFS= read -r stale; do
    [[ "$stale" == "${staging_root}/job."* ]] || continue
    if ! rm -rf -- "$stale"; then
      warn "Could not remove stale self-update staging directory: ${stale}"
    fi
  done < <(find "$staging_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'job.*' -mmin +60 -print 2>/dev/null)
}

render_self_update_runner() {
  local output="$1"
  cat >"$output" <<'EOF'
#!/bin/sh
set -eu
umask 077

candidate=$1
job_dir=$2
outcome=$3
old_version=$4
candidate_version=$5
unit=$6
diagnostic=${7:-${outcome}.log}
outcome_written=0

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
safe_detail() { printf '%s' "${1:-}" | tr '\r\n' '  ' | tr -cd '[:print:]' | cut -c1-240; }
write_outcome() {
  outcome_state=$1
  completed_at=$2
  result_code=$3
  detail_text=$(safe_detail "${4:-}")
  staged="${outcome}.new.$$"
  {
    printf 'operation=self-update\n'
    printf 'status=%s\n' "$outcome_state"
    printf 'started=%s\n' "$(sed -n 's/^started=//p' "$outcome" | sed -n '1p')"
    printf 'completed=%s\n' "$completed_at"
    printf 'old_version=%s\n' "$old_version"
    printf 'candidate_version=%s\n' "$candidate_version"
    printf 'unit=%s\n' "$unit"
    printf 'exit_status=%s\n' "$result_code"
    printf 'diagnostic=%s\n' "$diagnostic"
    printf 'detail=%s\n' "$detail_text"
  } >"$staged"
  chmod 0600 "$staged"
  mv -f -- "$staged" "$outcome"
  outcome_written=1
}

capture_output() {
  diagnostic_stage="${diagnostic}.new.$$"
  command_status_file="${diagnostic}.exit.$$"
  command_output_file="${diagnostic}.raw.$$"
  rm -f -- "$command_status_file" "$command_output_file"
  "$candidate" upgrade --yes >"$command_output_file" 2>&1 &
  command_pid=$!
  if wait "$command_pid"; then
    command_status=0
  else
    command_status=$?
  fi
  command_pid=
  printf '%s\n' "$command_status" >"$command_status_file"
  awk -v max=32768 '
    {
      if (written < max) {
        remaining=max-written
        if (length($0) + 1 <= remaining) {
          print
          written += length($0) + 1
        } else if (remaining > 1) {
          print substr($0, 1, remaining - 1)
          written=max
        } else {
          written=max
        }
      }
    }
  ' "$command_output_file" >"$diagnostic_stage" || true
  if [ -r "$command_status_file" ]; then
    command_status=$(sed -n '1p' "$command_status_file")
  else
    command_status=125
  fi
  case "$command_status" in
    ''|*[!0-9]*) command_status=125 ;;
  esac
  chmod 0600 "$diagnostic_stage"
  mv -f -- "$diagnostic_stage" "$diagnostic"
  rm -f -- "$command_status_file" "$command_output_file"
  return "$command_status"
}

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "${command_pid:-}" ]; then
    kill "$command_pid" 2>/dev/null || true
  fi
  if [ "$outcome_written" -eq 0 ]; then
    printf '%s\n' 'self-update worker ended before recording a result' >"${diagnostic}.new"
    chmod 0600 "${diagnostic}.new"
    mv -f -- "${diagnostic}.new" "$diagnostic"
    write_outcome failure "$(now)" "$cleanup_status" 'self-update worker ended before recording a result' || true
  fi
  rm -f -- "$candidate" "$job_dir/runner" \
    "${command_status_file:-}" "${command_output_file:-}" "${diagnostic_stage:-}"
  rmdir -- "$job_dir" 2>/dev/null || true
  exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
unset SSH_CONNECTION
worker_status=0
if capture_output; then
  worker_status=0
else
  worker_status=$?
fi
if [ "$worker_status" -eq 0 ]; then
  write_outcome success "$(now)" 0 'detached upgrade completed and postconditions passed'
else
  write_outcome failure "$(now)" "$worker_status" "detached upgrade failed; inspect the bounded diagnostic for ${unit}.service"
fi
exit "$worker_status"
EOF
  sh -n "$output" || die 'Generated self-update runner failed shell syntax validation.'
}

# The optional staging root is a test seam. Production always uses the private
# managed directory under STATE_DIR.
launch_detached_self_update() {
  local candidate="$1" candidate_version="$2"
  local staging_root="${3:-$SELF_UPDATE_STAGING_DIR}"
  local job_dir staged_candidate runner unit_base outcome_file diagnostic started old_version outcome_root

  if [[ -e "$staging_root" ]]; then
    [[ -d "$staging_root" && ! -L "$staging_root" ]] || \
      die "Refusing unsafe self-update staging path: ${staging_root}"
  fi
  install -d -o root -g root -m 0700 "$staging_root"
  prune_self_update_staging "$staging_root"
  job_dir="$(mktemp -d "${staging_root}/job.XXXXXX")"
  chmod 0700 "$job_dir"
  staged_candidate="${job_dir}/installer"
  runner="${job_dir}/runner"
  old_version="$(installed_helper_version)"
  unit_base="vpn-self-update-$(date +%s)-$$"
  if [[ "$staging_root" == "$SELF_UPDATE_STAGING_DIR" ]]; then
    outcome_root="$OPERATION_OUTCOME_ROOT"
  else
    outcome_root="${staging_root}.outcomes"
  fi
  install -d -o root -g root -m 0700 "$outcome_root"
  outcome_file="${outcome_root}/self-update-${unit_base}.status"
  diagnostic="${outcome_root}/self-update-${unit_base}.log"
  started="$(operation_timestamp)"
  write_operation_outcome "$outcome_file" self-update pending "$started" '' \
    "$old_version" "$candidate_version" "$unit_base" '' \
    "detached installer update staged; unit ${unit_base}.service" "$diagnostic"
  install -o root -g root -m 0500 "$candidate" "$staged_candidate"
  render_self_update_runner "$runner"
  chmod 0500 "$runner"

  if ! systemd-run --quiet --collect --unit="$unit_base" \
      --property=Type=exec --property=RuntimeMaxSec=45min \
      --property=StandardOutput=null --property=StandardError=null \
      "$runner" "$staged_candidate" "$job_dir" "$outcome_file" \
      "$old_version" "$candidate_version" "$unit_base" "$diagnostic"; then
    printf '%s\n' 'systemd could not start the detached self-update worker; no upgrade is running' \
      >"${diagnostic}.new"
    chmod 0600 "${diagnostic}.new"
    mv -f -- "${diagnostic}.new" "$diagnostic"
    write_operation_outcome "$outcome_file" self-update failure "$started" \
      "$(operation_timestamp)" "$old_version" "$candidate_version" "$unit_base" 1 \
      'systemd could not start the detached self-update worker; no upgrade is running' "$diagnostic"
    rm -rf -- "$job_dir"
    die 'The detached self-update unit could not be started; no upgrade is running.'
  fi

  printf 'Detached installer update started: %s -> %s\n' \
    "$(installed_helper_version)" "$candidate_version"
  printf 'Transient systemd unit: %s.service\n' "$unit_base"
  printf '%s\n' 'The update now continues independently on the server.'
  printf '%s\n' 'sing-box may briefly restart; SSH routed through this VPN may disconnect.'
  printf '%s\n' 'After reconnecting, run: vpn health -v'
}

self_update_from_file() {
  local source_path candidate checksum_file expected_checksum actual_checksum
  local candidate_version current_version
  require_root
  require_command dpkg
  acquire_operation_lock

  new_temp_dir
  candidate="${TMP_DIR}/installer-candidate"
  if [[ -n "$SELF_UPDATE_SOURCE" ]]; then
    source_path="$(readlink -f "$SELF_UPDATE_SOURCE" 2>/dev/null || true)"
    [[ -n "$source_path" ]] || die 'Unable to resolve the installer candidate path.'
    install -o root -g root -m 0700 "$source_path" "$candidate"
  else
    require_command curl
    require_command sha256sum
    checksum_file="${TMP_DIR}/installer-candidate.sha256"
    download_self_update_asset \
      "${SELF_UPDATE_RELEASE_BASE}/${SELF_UPDATE_INSTALLER_ASSET}" \
      "$candidate" 8388608 'installer asset'
    download_self_update_asset \
      "${SELF_UPDATE_RELEASE_BASE}/${SELF_UPDATE_CHECKSUM_ASSET}" \
      "$checksum_file" 16384 'checksum asset'
    if ! expected_checksum="$(installer_checksum_from_file "$checksum_file")"; then
      exit 1
    fi
    if ! actual_checksum="$(sha256sum "$candidate" | awk '{ print tolower($1) }')"; then
      die 'Unable to calculate the downloaded installer SHA-256.'
    fi
    [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
      die 'Unable to calculate a valid SHA-256 for the downloaded installer.'
    [[ "$actual_checksum" == "$expected_checksum" ]] || \
      die 'Downloaded installer SHA-256 does not match the published release asset.'
  fi

  if ! candidate_version="$(validate_installer_file "$candidate")"; then
    exit 1
  fi
  current_version="$(installed_helper_version)"
  [[ -n "$current_version" ]] || die 'The installed management helper version cannot be determined.'
  dpkg --validate-version "$current_version" >/dev/null 2>&1 || \
    die 'The installed management helper reports an invalid version.'
  if dpkg --compare-versions "$candidate_version" lt "$current_version"; then
    die "Refusing installer downgrade from ${current_version} to ${candidate_version}."
  fi
  if dpkg --compare-versions "$candidate_version" eq "$current_version"; then
    log "Installer ${current_version} already matches the selected candidate; no changes were made."
    return
  fi
  require_command systemd-run

  printf 'Installer self-update: %s -> %s\n' "$current_version" "$candidate_version"
  if [[ -n "$SELF_UPDATE_SOURCE" ]]; then
    printf 'Local candidate passed syntax, project identity, and version validation.\n'
  else
    printf 'Release checksum matched; candidate passed syntax, project identity, and version validation.\n'
  fi
  printf '%s\n' 'sing-box may briefly restart during the update.'
  printf '%s\n' 'If this SSH connection uses the same VPN, it may disconnect; the update will continue on the server.'
  require_confirmation
  launch_detached_self_update "$candidate" "$candidate_version"
}

operation_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

operation_safe_detail() {
  printf '%s' "${1:-}" | tr '\r\n' '  ' | tr -cd '[:print:]' | cut -c1-240
}

write_operation_outcome() {
  local output="$1" operation="$2" status="$3" started="$4" completed="$5"
  local old_version="$6" candidate_version="$7" unit="$8" exit_status="$9" detail="${10:-}"
  local diagnostic="${11:-}"
  local staged
  detail="$(operation_safe_detail "$detail")"
  install -d -o root -g root -m 0700 "$(dirname "$output")"
  staged="${output}.new.$$"
  {
    printf 'operation=%s\n' "$operation"
    printf 'status=%s\n' "$status"
    printf 'started=%s\n' "$started"
    printf 'completed=%s\n' "$completed"
    printf 'old_version=%s\n' "$old_version"
    printf 'candidate_version=%s\n' "$candidate_version"
    printf 'unit=%s\n' "$unit"
    printf 'exit_status=%s\n' "$exit_status"
    printf 'diagnostic=%s\n' "$diagnostic"
    printf 'detail=%s\n' "$detail"
  } >"$staged"
  chmod 0600 "$staged"
  mv -f -- "$staged" "$output"
}

management_address_is_local() {
  local address="$1"
  [[ -n "$address" ]] || return 1
  ip -o addr show 2>/dev/null | awk -v needle="$address" '
    {
      value=$4
      sub(/\/[0-9]+$/, "", value)
      if (value == needle) found=1
    }
    END { exit found ? 0 : 1 }
  '
}

management_normalize_endpoint() {
  printf '%s\n' "$1" | sed -E 's/^\[//; s/\](:[0-9]+)$/\1/'
}

management_ss_established_connections() {
  LC_ALL=C ss -HtanOep 2>/dev/null
}

management_ss_transport_connections() {
  LC_ALL=C ss -HtanOe 2>/dev/null
}

management_capture_ssh_transport_identity() {
  local local_endpoint remote_endpoint connections identity
  local_endpoint="$(management_normalize_endpoint "$1")"
  remote_endpoint="$(management_normalize_endpoint "$2")"
  MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT=""
  MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT=""
  MANAGEMENT_TRANSPORT_SOCKET_COOKIE=""
  MANAGEMENT_TRANSPORT_SOCKET_INODE=""
  connections="$(management_ss_established_connections)" || return 1
  identity="$(awk -v expected_local="$local_endpoint" -v expected_remote="$remote_endpoint" '
    function normalize(value) {
      sub(/^\[/, "", value)
      sub(/\](:[0-9]+)$/, "\\1", value)
      return value
    }
    {
      if ($1 != "ESTAB" || normalize($4) != expected_local ||
          normalize($5) != expected_remote || index($0, "users:((\"sshd") == 0) next
      inode=""
      cookie=""
      for (i=6; i<=NF; i++) {
        if ($i ~ /^ino:[0-9]+$/) inode=substr($i, 5)
        if ($i ~ /^sk:[[:xdigit:]]+$/) cookie=substr($i, 4)
      }
      if (inode != "" && cookie != "") {
        matches++
        result=cookie "|" inode
      }
    }
    END {
      if (matches == 1) print result
      else exit 1
    }
  ' <<<"$connections")" || return 1
  MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT="$local_endpoint"
  MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT="$remote_endpoint"
  MANAGEMENT_TRANSPORT_SOCKET_COOKIE="${identity%%|*}"
  MANAGEMENT_TRANSPORT_SOCKET_INODE="${identity#*|}"
}

management_transport_identity_is_present() {
  local local_endpoint="$1" remote_endpoint="$2" cookie="$3" inode="$4" connections
  connections="$(management_ss_transport_connections)" || return 2
  awk -v expected_local="$(management_normalize_endpoint "$local_endpoint")" \
      -v expected_remote="$(management_normalize_endpoint "$remote_endpoint")" \
      -v expected_cookie="$cookie" -v expected_inode="$inode" '
    function normalize(value) {
      sub(/^\[/, "", value)
      sub(/\](:[0-9]+)$/, "\\1", value)
      return value
    }
    {
      if (normalize($4) != expected_local || normalize($5) != expected_remote) next
      tuple_found=1
      inode=""
      cookie=""
      for (i=6; i<=NF; i++) {
        if ($i ~ /^ino:[0-9]+$/) inode=substr($i, 5)
        if ($i ~ /^sk:[[:xdigit:]]+$/) cookie=substr($i, 4)
      }
      if (inode != "" && cookie != "") identity_found=1
      if (inode == expected_inode && cookie == expected_cookie) found=1
    }
    END {
      if (found) exit 0
      if (tuple_found && !identity_found) exit 2
      exit 1
    }
  ' <<<"$connections"
}

management_proc_parent_pid_from_stat() {
  local stat="$1" tail
  local -a fields=()
  tail="${stat##*) }"
  [[ "$tail" != "$stat" ]] || return 1
  IFS=' ' read -r -a fields <<<"$tail"
  [[ "${fields[1]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[1]}"
}

management_proc_parent_pid() {
  local pid="$1" stat
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]] || return 1
  IFS= read -r stat <"/proc/${pid}/stat" || return 1
  management_proc_parent_pid_from_stat "$stat"
}

management_proc_command_name() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/comm" ]] || return 1
  tr -d '\r\n' <"/proc/${pid}/comm"
}

management_proc_environment_value() {
  local pid="$1" key="$2" value
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/environ" ]] || return 1
  value="$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null |
    sed -n "s/^${key}=//p" | sed -n '1p' || true)"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

management_ssh_context_from_ancestry() {
  local pid="$$" parent command value depth=0
  MANAGEMENT_SSH_ANCESTOR_FOUND=0
  MANAGEMENT_SSH_ANCESTOR_PID=""
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 && $depth -lt 64 ]]; do
    command="$(management_proc_command_name "$pid" 2>/dev/null || true)"
    case "$command" in
      sshd|sshd:*|sshd-*)
        MANAGEMENT_SSH_ANCESTOR_FOUND=1
        [[ -n "$MANAGEMENT_SSH_ANCESTOR_PID" ]] || MANAGEMENT_SSH_ANCESTOR_PID="$pid"
        ;;
    esac
    if [[ -z "$MANAGEMENT_SSH_CONNECTION" ]]; then
      value="$(management_proc_environment_value "$pid" SSH_CONNECTION 2>/dev/null || true)"
      if [[ -n "$value" ]]; then
        MANAGEMENT_SSH_CONNECTION="$value"
      fi
    fi
    parent="$(management_proc_parent_pid "$pid" 2>/dev/null || true)"
    [[ "$parent" =~ ^[0-9]+$ && "$parent" != "$pid" ]] || break
    pid="$parent"
    depth=$(( depth + 1 ))
  done
  (( MANAGEMENT_SSH_ANCESTOR_FOUND == 1 ))
}

management_sing_box_connection_to_ssh_endpoint() {
  local expected_endpoint connections
  [[ -n "$SERVER_IPV4" && "$SSH_PORT" =~ ^[0-9]+$ ]] || return 1
  expected_endpoint="${SERVER_IPV4}:${SSH_PORT}"
  connections="$(ss -Htnp 2>/dev/null || true)"
  awk -v expected="$expected_endpoint" '
    function normalize(value) {
      sub(/^\[/, "", value)
      sub(/\](:[0-9]+)$/, "\\1", value)
      return value
    }
    { if (normalize($5) == expected && index($0, "users:((\"sing-box\"") > 0) found=1 }
    END { exit found ? 0 : 1 }
  ' <<<"$connections"
}

classify_management_ssh_session() {
  local remote remote_port local_address local_port
  MANAGEMENT_SESSION_CLASS=console
  MANAGEMENT_SESSION_REASON='non-SSH invocation'
  MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT=""
  MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT=""
  MANAGEMENT_TRANSPORT_SOCKET_COOKIE=""
  MANAGEMENT_TRANSPORT_SOCKET_INODE=""
  MANAGEMENT_SSH_CONNECTION="${SSH_CONNECTION:-}"
  management_ssh_context_from_ancestry >/dev/null 2>&1 || true

  if [[ -z "$MANAGEMENT_SSH_CONNECTION" ]]; then
    if (( MANAGEMENT_SSH_ANCESTOR_FOUND == 1 )); then
      MANAGEMENT_SESSION_CLASS=deferred
      MANAGEMENT_SESSION_REASON='an SSH ancestor was found but SSH_CONNECTION could not be recovered'
    fi
    return 0
  fi
  MANAGEMENT_SESSION_CLASS=deferred
  MANAGEMENT_SESSION_REASON='SSH transport could not be positively classified as direct'
  IFS=' ' read -r remote remote_port local_address local_port _ <<<"$MANAGEMENT_SSH_CONNECTION"
  if [[ -z "$remote" || -z "$remote_port" || -z "$local_address" || -z "$local_port" ||
        ! "$remote_port" =~ ^[0-9]+$ || ! "$local_port" =~ ^[0-9]+$ ]]; then
    MANAGEMENT_SESSION_REASON='SSH_CONNECTION is missing or malformed after ancestry recovery'
    return 0
  fi
  if (( MANAGEMENT_SSH_ANCESTOR_FOUND == 0 )); then
    MANAGEMENT_SESSION_REASON='SSH_CONNECTION was present but no sshd ancestor was positively identified'
    return 0
  fi

  if ! management_address_is_local "$local_address"; then
    MANAGEMENT_SESSION_REASON='SSH local endpoint is not a verified address on this host'
    return 0
  fi
  if ! management_capture_ssh_transport_identity \
      "${local_address}:${local_port}" "${remote}:${remote_port}"; then
    MANAGEMENT_SESSION_REASON='the exact sshd-owned SSH socket identity was not positively observed'
    return 0
  fi
  if [[ "$remote" == "$SERVER_IPV4" ]] || management_address_is_local "$remote" ||
     [[ "$remote" == 127.* || "$remote" == ::1 || "$remote" == 0.0.0.0 ]]; then
    MANAGEMENT_SESSION_REASON='SSH peer is a local/server address consistent with a self-tunneled connection'
    return 0
  fi
  if management_sing_box_connection_to_ssh_endpoint; then
    MANAGEMENT_SESSION_REASON='a sing-box-owned outbound connection to the managed SSH endpoint indicates 1:1 NAT self-tunneling'
    return 0
  fi

  # A public/non-loopback peer alone is never sufficient. The exact established
  # socket, its local address, sshd ownership, and kernel socket identity must
  # positively establish the direct transport before a restart-requiring
  # mutation is applied now.
  MANAGEMENT_SESSION_CLASS=direct
  # shellcheck disable=SC2034 # This is a deliberate global classification result.
  MANAGEMENT_SESSION_REASON='exact SSH socket and local endpoint positively establish a direct transport'
}

management_ssh_requires_deferred_activation() {
  classify_management_ssh_session
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]]
}

deferred_job_field() {
  local key="$1" file="$2"
  sed -n "s/^${key}=//p" "$file" | sed -n '1p'
}

deferred_tree_hash() {
  local path="$1" file
  [[ -d "$path" && ! -L "$path" ]] || return 1
  if find "$path" -type l -print -quit 2>/dev/null | grep -q .; then
    return 1
  fi
  (
    cd -- "$path" || exit 1
    find . -type f -print0 | sort -z |
      while IFS= read -r -d '' file; do
        sha256sum -- "$file"
      done
  ) | sha256sum | awk '{print $1}'
}

deferred_current_identity() {
  local kind="$1" path="$2" hash version
  case "$kind" in
    file)
      if [[ ! -e "$path" ]]; then
        printf 'absent|\n'
        return
      fi
      [[ -f "$path" && ! -L "$path" ]] || return 1
      hash="$(sha256sum -- "$path" | awk '{print $1}')"
      printf 'present|%s\n' "$hash"
      ;;
    tree)
      if [[ ! -e "$path" ]]; then
        printf 'absent|\n'
        return
      fi
      hash="$(deferred_tree_hash "$path")" || return 1
      printf 'present|%s\n' "$hash"
      ;;
    package)
      version="$(dpkg-query -W -f='${Version}' "$path" 2>/dev/null || true)"
      if [[ -n "$version" ]]; then
        printf 'present|%s\n' "$version"
      else
        printf 'absent|\n'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

deferred_job_baseline_artifacts() {
  local operation="$1"
  case "$operation" in
    client-add|client-delete)
      printf 'file|%s\n' "$CLIENTS_FILE" "$CONFIG_FILE"
      printf 'tree|%s\n' "$SUBSCRIPTION_ROOT"
      ;;
    reality-target|fingerprint|hy2-obfs)
      printf 'file|%s\n' "$SETTINGS_FILE" "$CONFIG_FILE"
      printf 'tree|%s\n' "$SUBSCRIPTION_ROOT"
      ;;
    core-update)
      printf 'package|sing-box\n'
      printf 'file|%s\n' "$CONFIG_FILE"
      ;;
    overlay-upgrade)
      printf 'file|%s\n' "$CONFIG_FILE" "$UDP_SYSCTL_FILE" \
        "$UNATTENDED_UPGRADES_CONFIG" "$CERT_HOOK" "$INSTALLED_HELPER" \
        "$USER_COMMAND" "$INSTALL_COMPLETE_FILE" "$RUNTIME_VERSION_FILE" \
        "$SETTINGS_FILE" "$CLIENTS_FILE"
      printf 'tree|%s\n' "$SUBSCRIPTION_ROOT" "$HY2_MASQUERADE_ROOT"
      ;;
    *)
      return 1
      ;;
  esac
}

deferred_job_capture_baseline() {
  local job="$1" output="$2" operation kind path identity state hash
  operation="$(deferred_job_field operation "${job}/metadata")"
  deferred_job_baseline_artifacts "$operation" >/dev/null || return 1
  : >"$output"
  while IFS='|' read -r kind path; do
    identity="$(deferred_current_identity "$kind" "$path")" || return 1
    state="${identity%%|*}"
    hash="${identity#*|}"
    printf '%s|%s|%s|%s\n' "$kind" "$path" "$state" "$hash" >>"$output"
  done < <(deferred_job_baseline_artifacts "$operation")
  chmod 0600 "$output"
}

deferred_job_verify_baseline() {
  local job="$1" kind path expected_state expected_hash identity
  DEFERRED_BASELINE_MISMATCH=""
  [[ -f "${job}/baseline" && ! -L "${job}/baseline" ]] || {
    DEFERRED_BASELINE_MISMATCH='baseline manifest is missing'
    return 1
  }
  while IFS='|' read -r kind path expected_state expected_hash; do
    identity="$(deferred_current_identity "$kind" "$path" 2>/dev/null || true)"
    if [[ "$identity" != "${expected_state}|${expected_hash}" ]]; then
      DEFERRED_BASELINE_MISMATCH="$(basename "$path") changed since staging"
      return 1
    fi
  done <"${job}/baseline"
  return 0
}

deferred_job_unit_is_active() {
  local job="$1" unit load active
  unit="$(deferred_job_field unit "${job}/metadata")"
  [[ -n "$unit" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 2
  load="$(systemctl show -p LoadState --value "${unit}.service" 2>/dev/null)" || return 2
  active="$(systemctl show -p ActiveState --value "${unit}.service" 2>/dev/null)" || return 2
  [[ "$load" != not-found && -n "$load" ]] || return 1
  case "$active" in
    active|activating|reloading|deactivating) return 0 ;;
    inactive|failed|dead) return 1 ;;
    *) return 2 ;;
  esac
}

deferred_job_transport_state() {
  local job="$1" local_endpoint remote_endpoint cookie inode
  local_endpoint="$(deferred_job_field transport_local "${job}/metadata")"
  remote_endpoint="$(deferred_job_field transport_remote "${job}/metadata")"
  cookie="$(deferred_job_field transport_cookie "${job}/metadata")"
  inode="$(deferred_job_field transport_inode "${job}/metadata")"
  [[ -n "$local_endpoint" && -n "$remote_endpoint" && "$cookie" =~ ^[[:xdigit:]]+$ &&
        "$inode" =~ ^[0-9]+$ ]] || return 2
  management_transport_identity_is_present "$local_endpoint" "$remote_endpoint" "$cookie" "$inode"
}

deferred_job_is_orphaned() {
  local job="$1" unit unit_status
  unit="$(deferred_job_field unit "${job}/metadata")"
  if [[ -n "$unit" ]]; then
    if deferred_job_unit_is_active "$job"; then
      return 1
    else
      unit_status=$?
    fi
    case "$unit_status" in
      0) return 1 ;;
      2) return 2 ;;
      1) return 0 ;;
    esac
  fi
  if deferred_job_transport_state "$job"; then
    return 1
  else
    unit_status=$?
  fi
  case "$unit_status" in
    1) return 0 ;;
    *) return 2 ;;
  esac
}

deferred_job_mark_orphaned() {
  local job="$1" job_id operation started unit outcome diagnostic detail
  job_id="$(basename "$job")"
  operation="$(deferred_job_field operation "${job}/metadata")"
  started="$(deferred_job_field created "${job}/metadata")"
  unit="$(deferred_job_field unit "${job}/metadata")"
  outcome="${OPERATION_OUTCOME_ROOT}/${job_id}.status"
  diagnostic="${OPERATION_OUTCOME_ROOT}/${job_id}.log"
  if deferred_job_verify_baseline "$job"; then
    detail='deferred worker/session disappeared before activation; candidate was discarded and live state was unchanged'
  else
    detail="deferred worker/session disappeared and baseline verification failed (${DEFERRED_BASELINE_MISMATCH}); candidate was discarded"
  fi
  printf '%s\n' "$detail" >"${diagnostic}.new"
  chmod 0600 "${diagnostic}.new"
  mv -f -- "${diagnostic}.new" "$diagnostic"
  write_operation_outcome "$outcome" "$operation" failure "$started" \
    "$(operation_timestamp)" \
    "$(deferred_job_field old_version "${job}/metadata")" \
    "$(deferred_job_field candidate_version "${job}/metadata")" \
    "$unit" 125 "$detail" "$diagnostic"
  rm -rf -- "$job"
}

deferred_recover_orphaned_jobs() {
  local job
  [[ -d "$DEFERRED_MUTATION_ROOT" && ! -L "$DEFERRED_MUTATION_ROOT" ]] || return 0
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    if deferred_job_is_orphaned "$job"; then
      deferred_job_mark_orphaned "$job"
    fi
  done < <(find "$DEFERRED_MUTATION_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'job.*' -print 2>/dev/null | sort)
}

deferred_refuse_if_pending() {
  local job
  [[ -d "$DEFERRED_MUTATION_ROOT" && ! -L "$DEFERRED_MUTATION_ROOT" ]] || return 0
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    [[ "$job" == "$DEFERRED_JOB_DIR" ]] && continue
    die "A deferred management operation is already pending; inspect vpn health -v before starting another."
  done < <(find "$DEFERRED_MUTATION_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'job.*' -print -quit 2>/dev/null)
}

deferred_job_create() {
  local operation="$1" description="$2" started job_id
  [[ "$MANAGEMENT_SESSION_CLASS" == deferred ]] || \
    die 'Internal error: deferred mutation requested without an ambiguous SSH session.'
  [[ -n "$MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT" &&
        -n "$MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT" &&
        "$MANAGEMENT_TRANSPORT_SOCKET_COOKIE" =~ ^[[:xdigit:]]+$ &&
        "$MANAGEMENT_TRANSPORT_SOCKET_INODE" =~ ^[0-9]+$ ]] || \
    die 'The exact controlling SSH transport identity is unavailable; refusing restart-requiring activation.'
  install -d -o root -g root -m 0700 "$DEFERRED_MUTATION_ROOT" "$OPERATION_OUTCOME_ROOT"
  deferred_recover_orphaned_jobs
  deferred_refuse_if_pending
  DEFERRED_JOB_DIR="$(mktemp -d "${DEFERRED_MUTATION_ROOT}/job.XXXXXX")"
  chmod 0700 "$DEFERRED_JOB_DIR"
  job_id="$(basename "$DEFERRED_JOB_DIR")"
  DEFERRED_OUTCOME_FILE="${OPERATION_OUTCOME_ROOT}/${job_id}.status"
  started="$(operation_timestamp)"
  {
    printf 'operation=%s\n' "$operation"
    printf 'description=%s\n' "$(operation_safe_detail "$description")"
    printf 'transport_local=%s\n' "$MANAGEMENT_TRANSPORT_LOCAL_ENDPOINT"
    printf 'transport_remote=%s\n' "$MANAGEMENT_TRANSPORT_REMOTE_ENDPOINT"
    printf 'transport_cookie=%s\n' "$MANAGEMENT_TRANSPORT_SOCKET_COOKIE"
    printf 'transport_inode=%s\n' "$MANAGEMENT_TRANSPORT_SOCKET_INODE"
    printf 'created=%s\n' "$started"
  } >"${DEFERRED_JOB_DIR}/metadata"
  chmod 0600 "${DEFERRED_JOB_DIR}/metadata"
  if ! deferred_job_capture_baseline "$DEFERRED_JOB_DIR" "${DEFERRED_JOB_DIR}/baseline"; then
    rm -rf -- "$DEFERRED_JOB_DIR"
    DEFERRED_JOB_DIR=""
    die 'Could not capture a safe deferred-operation baseline; no live state was changed.'
  fi
  printf 'baseline=%s\n' "${DEFERRED_JOB_DIR}/baseline" >>"${DEFERRED_JOB_DIR}/metadata"
  write_operation_outcome "$DEFERRED_OUTCOME_FILE" "$operation" pending \
    "$started" '' '' '' '' '' 'validated activation is waiting for the originating SSH transport to end' \
    "${OPERATION_OUTCOME_ROOT}/${job_id}.log"
}

deferred_job_stage_file() {
  local source="$1" name="$2" owner="$3" group="$4" mode="$5"
  [[ -f "$source" && ! -L "$source" ]] || die "Deferred candidate is not a regular file: ${source}"
  install -o "$owner" -g "$group" -m "$mode" "$source" "${DEFERRED_JOB_DIR}/${name}"
}

deferred_job_stage_tree() {
  local source="$1" name="$2" file
  [[ -d "$source" && ! -L "$source" ]] || die "Deferred candidate tree is not a directory: ${source}"
  install -d -o root -g root -m 0700 "${DEFERRED_JOB_DIR}/${name}"
  while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" ]] || die "Deferred subscription tree contains an unsafe entry: ${file}"
    install -o root -g www-data -m 0640 "$file" \
      "${DEFERRED_JOB_DIR}/${name}/$(basename "$file")"
  done < <(find "$source" -mindepth 1 -maxdepth 1 -type f -print0)
}

deferred_job_stage_activator() {
  local source version
  source="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  [[ -f "$source" && ! -L "$source" ]] || return 1
  version="$(validate_installer_file "$source")"
  [[ "$version" == "$SCRIPT_VERSION" ]] || return 1
  install -o root -g root -m 0500 "$source" "${DEFERRED_JOB_DIR}/activator"
}

render_deferred_mutation_runner() {
  local output="$1"
  cat >"$output" <<'EOF'
#!/bin/sh
set -eu
umask 077

job_dir=$1
outcome=$2
unit=$3
helper=$4
activator=${5:-}
diagnostic=${6:-${outcome}.log}
transport_local=$(sed -n 's/^transport_local=//p' "$job_dir/metadata" | sed -n '1p')
transport_remote=$(sed -n 's/^transport_remote=//p' "$job_dir/metadata" | sed -n '1p')
transport_cookie=$(sed -n 's/^transport_cookie=//p' "$job_dir/metadata" | sed -n '1p')
transport_inode=$(sed -n 's/^transport_inode=//p' "$job_dir/metadata" | sed -n '1p')
outcome_written=0

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
safe_detail() { printf '%s' "${1:-}" | tr '\r\n' '  ' | tr -cd '[:print:]' | cut -c1-240; }
write_outcome() {
  outcome_state=$1
  completed_at=$2
  result_code=$3
  detail_text=$(safe_detail "${4:-}")
  staged="${outcome}.new.$$"
  {
    printf 'operation=%s\n' "$(sed -n 's/^operation=//p' "$job_dir/metadata" | sed -n '1p')"
    printf 'status=%s\n' "$outcome_state"
    printf 'started=%s\n' "$(sed -n 's/^created=//p' "$job_dir/metadata" | sed -n '1p')"
    printf 'completed=%s\n' "$completed_at"
    printf 'old_version=%s\n' "$(sed -n 's/^old_version=//p' "$job_dir/metadata" | sed -n '1p')"
    printf 'candidate_version=%s\n' "$(sed -n 's/^candidate_version=//p' "$job_dir/metadata" | sed -n '1p')"
    printf 'unit=%s\n' "$unit"
    printf 'exit_status=%s\n' "$result_code"
    printf 'diagnostic=%s\n' "$diagnostic"
    printf 'detail=%s\n' "$detail_text"
  } >"$staged"
  chmod 0600 "$staged"
  mv -f -- "$staged" "$outcome"
  outcome_written=1
}
transport_identity_is_present() {
  connections=$(LC_ALL=C ss -HtanOe 2>/dev/null) || return 2
  awk -v expected_local="$transport_local" -v expected_remote="$transport_remote" \
      -v expected_cookie="$transport_cookie" -v expected_inode="$transport_inode" '
    function normalize(value) {
      sub(/^\[/, "", value)
      sub(/\](:[0-9]+)$/, "\\1", value)
      return value
    }
    {
      if (normalize($4) != expected_local || normalize($5) != expected_remote) next
      tuple_found=1
      inode=""
      cookie=""
      for (i=6; i<=NF; i++) {
        if ($i ~ /^ino:[0-9]+$/) inode=substr($i, 5)
        if ($i ~ /^sk:[[:xdigit:]]+$/) cookie=substr($i, 4)
      }
      if (inode != "" && cookie != "") identity_found=1
      if (inode == expected_inode && cookie == expected_cookie) found=1
    }
    END {
      if (found) exit 0
      if (tuple_found && !identity_found) exit 2
      exit 1
    }
  ' <<EOF_CONNECTIONS
$connections
EOF_CONNECTIONS
}

capture_output() {
  diagnostic_stage="${diagnostic}.new.$$"
  command_status_file="${diagnostic}.exit.$$"
  command_output_file="${diagnostic}.raw.$$"
  rm -f -- "$command_status_file" "$command_output_file"
  if [ -n "$activator" ] && [ -x "$activator" ]; then
    "$activator" deferred-activate "$job_dir" >"$command_output_file" 2>&1 &
  else
    "$helper" deferred-activate "$job_dir" >"$command_output_file" 2>&1 &
  fi
  command_pid=$!
  if wait "$command_pid"; then
    command_status=0
  else
    command_status=$?
  fi
  command_pid=
  printf '%s\n' "$command_status" >"$command_status_file"
  awk -v max=32768 '
    {
      if (written < max) {
        remaining=max-written
        if (length($0) + 1 <= remaining) {
          print
          written += length($0) + 1
        } else if (remaining > 1) {
          print substr($0, 1, remaining - 1)
          written=max
        } else {
          written=max
        }
      }
    }
  ' "$command_output_file" >"$diagnostic_stage" || true
  if [ -r "$command_status_file" ]; then
    command_status=$(sed -n '1p' "$command_status_file")
  else
    command_status=125
  fi
  case "$command_status" in
    ''|*[!0-9]*) command_status=125 ;;
  esac
  chmod 0600 "$diagnostic_stage"
  mv -f -- "$diagnostic_stage" "$diagnostic"
  rm -f -- "$command_status_file" "$command_output_file"
  return "$command_status"
}

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "${command_pid:-}" ]; then
    kill "$command_pid" 2>/dev/null || true
  fi
  if [ "$outcome_written" -eq 0 ]; then
    printf '%s\n' 'deferred activation worker ended before recording a result' >"${diagnostic}.new"
    chmod 0600 "${diagnostic}.new"
    mv -f -- "${diagnostic}.new" "$diagnostic"
    write_outcome failure "$(now)" "$cleanup_status" "deferred activation worker ended before recording a result" || true
  fi
  rm -f -- "${command_status_file:-}" "${command_output_file:-}" "${diagnostic_stage:-}"
  rm -rf -- "$job_dir"
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

case "$transport_cookie" in ''|*[!0-9A-Fa-f]*) transport_metadata_valid=0 ;; *) transport_metadata_valid=1 ;; esac
case "$transport_inode" in ''|*[!0-9]*) transport_metadata_valid=0 ;; esac
if [ -z "$transport_local" ] || [ -z "$transport_remote" ] || [ "$transport_metadata_valid" -ne 1 ]; then
  write_outcome failure "$(now)" 125 'controlling SSH transport metadata is invalid; activation was not attempted'
  exit 125
fi

probe_failures=0
while :; do
  if transport_identity_is_present; then
    probe_failures=0
    sleep 1
    continue
  else
    transport_status=$?
  fi
  if [ "$transport_status" -eq 1 ]; then
    break
  fi
  probe_failures=$((probe_failures + 1))
  if [ "$probe_failures" -ge 30 ]; then
    write_outcome failure "$(now)" 125 'controlling SSH transport could not be observed; activation was not attempted'
    exit 125
  fi
  sleep 1
done
unset SSH_CONNECTION
worker_status=0
if capture_output; then
  worker_status=0
else
  worker_status=$?
fi
if [ "$worker_status" -eq 0 ]; then
  write_outcome success "$(now)" 0 'deferred activation completed and postconditions passed'
else
  write_outcome failure "$(now)" "$worker_status" "deferred activation failed; inspect the bounded diagnostic for ${unit}.service"
fi
exit "$worker_status"
EOF
  sh -n "$output" || die 'Generated deferred mutation runner failed shell syntax validation.'
}

queue_deferred_mutation() {
  local operation description job_id unit_base runner activator diagnostic started old_version candidate_version
  operation="$(deferred_job_field operation "${DEFERRED_JOB_DIR}/metadata")"
  description="$(deferred_job_field description "${DEFERRED_JOB_DIR}/metadata")"
  job_id="$(basename "$DEFERRED_JOB_DIR")"
  unit_base="vpn-deferred-${job_id#job.}-$(date +%s)"
  runner="${DEFERRED_JOB_DIR}/runner"
  activator="${DEFERRED_JOB_DIR}/activator"
  diagnostic="${OPERATION_OUTCOME_ROOT}/${job_id}.log"
  started="$(deferred_job_field created "${DEFERRED_JOB_DIR}/metadata")"
  old_version="$(deferred_job_field old_version "${DEFERRED_JOB_DIR}/metadata")"
  candidate_version="$(deferred_job_field candidate_version "${DEFERRED_JOB_DIR}/metadata")"
  if [[ ! -f "$activator" ]]; then
    deferred_job_stage_activator || {
      restore_deferred_helper_or_die
      printf '%s\n' 'The candidate-compatible deferred activator could not be staged; no live state was changed.' \
        >"${diagnostic}.new"
      chmod 0600 "${diagnostic}.new"
      mv -f -- "${diagnostic}.new" "$diagnostic"
      write_operation_outcome "$DEFERRED_OUTCOME_FILE" "$operation" failure "$started" \
        "$(operation_timestamp)" "$old_version" "$candidate_version" "$unit_base" 1 \
        'The candidate-compatible deferred activator could not be staged; no live state was changed.' "$diagnostic"
      rm -rf -- "$DEFERRED_JOB_DIR"
      die 'The candidate-compatible deferred activator could not be staged; no live state was changed.'
    }
  fi
  printf 'unit=%s\n' "$unit_base" >>"${DEFERRED_JOB_DIR}/metadata"
  printf 'diagnostic=%s\n' "$diagnostic" >>"${DEFERRED_JOB_DIR}/metadata"
  render_deferred_mutation_runner "$runner"
  chmod 0500 "$runner"
  if ! systemd-run --quiet --collect --unit="$unit_base" \
      --property=Type=exec --property=RuntimeMaxSec=24h \
      --property=StandardOutput=null --property=StandardError=null \
      "$runner" "$DEFERRED_JOB_DIR" "$DEFERRED_OUTCOME_FILE" \
      "$unit_base" "$INSTALLED_HELPER" "$activator" "$diagnostic"; then
    restore_deferred_helper_or_die
    printf '%s\n' 'systemd could not start the deferred activation worker; no live state was changed' \
      >"${diagnostic}.new"
    chmod 0600 "${diagnostic}.new"
    mv -f -- "${diagnostic}.new" "$diagnostic"
    write_operation_outcome "$DEFERRED_OUTCOME_FILE" "$operation" failure \
      "$started" "$(operation_timestamp)" "$old_version" "$candidate_version" "$unit_base" 1 \
      'systemd could not start the deferred activation worker; no live state was changed' "$diagnostic"
    rm -rf -- "$DEFERRED_JOB_DIR"
    die 'The deferred activation worker could not be started; no live state was changed.'
  fi
  write_operation_outcome "$DEFERRED_OUTCOME_FILE" "$operation" pending \
    "$started" '' "$old_version" "$candidate_version" "$unit_base" '' \
    'validated activation is waiting for the originating SSH transport to end' "$diagnostic"
  DEFERRED_MUTATION_QUEUED=1
  printf 'Staged/pending activation: %s\n' "$description"
  printf 'The specific SSH transport must end before the server activates this change.\n'
  printf 'Transient systemd unit: %s.service\n' "$unit_base"
  printf 'After reconnecting, run: vpn health -v\n'
}

start_sing_box() {
  systemctl daemon-reload
  systemctl enable sing-box.service >/dev/null
  if systemctl is-active --quiet sing-box.service; then
    systemctl restart sing-box.service
  else
    systemctl start sing-box.service
  fi
  systemctl is-active --quiet sing-box.service || die 'sing-box did not become active.'
  sing-box check -c "$CONFIG_FILE"
}

nftables_effective_execstop_is_exact() {
  local effective="$1"
  [[ -n "$effective" && "$effective" =~ \}[[:space:]]*$ ]] || return 1
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      open_count += gsub(/\{/, "&")
      close_count += gsub(/\}/, "&")
      text = text $0 " "
    }
    END {
      if (open_count != 1 || close_count != 1 ||
          match(text, /\{[^{}]*\}/) == 0) {
        exit 1
      }

      prefix = substr(text, 1, RSTART - 1)
      suffix = substr(text, RSTART + RLENGTH)
      if (prefix ~ /[^[:space:]]/ || suffix ~ /[^[:space:]]/) {
        exit 1
      }

      body = substr(text, RSTART + 1, RLENGTH - 2)
      field_count = split(body, fields, ";")
      for (field_index = 1; field_index <= field_count; field_index++) {
        field = trim(fields[field_index])
        if (field ~ /^path=/) {
          path_count++
          sub(/^path=/, "", field)
          path = field
        } else if (field ~ /^argv\[\]=/) {
          argv_count++
          sub(/^argv\[\]=/, "", field)
          argv = field
        } else if (field ~ /^ignore_errors=/) {
          ignore_errors_count++
          sub(/^ignore_errors=/, "", field)
          ignore_errors = field
        }
      }

      if (path_count != 1 || argv_count != 1 || ignore_errors_count != 1 ||
          path != "/usr/sbin/nft" ||
          argv != "/usr/sbin/nft delete table inet vpn_filter" ||
          ignore_errors != "yes") {
        exit 1
      }
    }
  ' <<<"$effective"
}

nftables_service_boundary_is_healthy() {
  local effective
  [[ -f "$NFTABLES_SYSTEMD_DROPIN" && ! -L "$NFTABLES_SYSTEMD_DROPIN" ]] || return 1
  grep -Fxq '# Managed by vpn-setup. Preserve unrelated nftables tables.' \
    "$NFTABLES_SYSTEMD_DROPIN" || return 1
  grep -Fxq 'ExecStop=' "$NFTABLES_SYSTEMD_DROPIN" || return 1
  grep -Fxq 'ExecStop=-/usr/sbin/nft delete table inet vpn_filter' \
    "$NFTABLES_SYSTEMD_DROPIN" || return 1
  effective="$(systemctl show -p ExecStop --value nftables.service 2>/dev/null)" || return 1
  nftables_effective_execstop_is_exact "$effective"
}

render_nftables_service_boundary() {
  local output="$1"
  cat >"$output" <<'EOF'
# Managed by vpn-setup. Preserve unrelated nftables tables.
[Service]
ExecStop=
ExecStop=-/usr/sbin/nft delete table inet vpn_filter
EOF
}

configure_nftables_service_boundary() {
  local candidate
  if [[ -e "$NFTABLES_SYSTEMD_DROPIN" ]]; then
    [[ -f "$NFTABLES_SYSTEMD_DROPIN" && ! -L "$NFTABLES_SYSTEMD_DROPIN" ]] || \
      die "Refusing to replace unexpected nftables service boundary: ${NFTABLES_SYSTEMD_DROPIN}"
    grep -Fxq '# Managed by vpn-setup. Preserve unrelated nftables tables.' \
      "$NFTABLES_SYSTEMD_DROPIN" || \
      die "Refusing to replace an unmanaged nftables service boundary: ${NFTABLES_SYSTEMD_DROPIN}"
  fi
  install -d -o root -g root -m 0755 "$NFTABLES_SYSTEMD_DROPIN_DIR"
  candidate="$(mktemp)"
  render_nftables_service_boundary "$candidate"
  write_atomic "$NFTABLES_SYSTEMD_DROPIN" root root 0644 "$candidate"
  rm -f -- "$candidate"
  systemctl daemon-reload
  nftables_service_boundary_is_healthy || \
    die 'The effective nftables.service ExecStop is not exactly the managed vpn_filter cleanup; refusing unsafe global firewall ownership.'
}

save_firewall_baseline() {
  install -d -o root -g root -m 0700 "$ROLLBACK_DIR"
  if [[ ! -f "${ROLLBACK_DIR}/vpn_filter.table.state" ]]; then
    if nft list table inet vpn_filter >"${ROLLBACK_DIR}/vpn_filter.table.before" 2>/dev/null; then
      chmod 0600 "${ROLLBACK_DIR}/vpn_filter.table.before"
      printf '%s\n' present >"${ROLLBACK_DIR}/vpn_filter.table.state"
    else
      rm -f -- "${ROLLBACK_DIR}/vpn_filter.table.before"
      printf '%s\n' absent >"${ROLLBACK_DIR}/vpn_filter.table.state"
    fi
    if [[ -e "$NFT_CONFIG" ]]; then
      install -o root -g root -m 0600 "$NFT_CONFIG" "${ROLLBACK_DIR}/nftables.conf.before"
      printf '%s\n' present >"${ROLLBACK_DIR}/nftables.conf.state"
    else
      printf '%s\n' absent >"${ROLLBACK_DIR}/nftables.conf.state"
    fi
    if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
      printf '%s\n' enabled >"${ROLLBACK_DIR}/nftables.service.state"
    else
      printf '%s\n' disabled >"${ROLLBACK_DIR}/nftables.service.state"
    fi
    if [[ -e "$NFTABLES_SYSTEMD_DROPIN" ]]; then
      install -o root -g root -m 0600 "$NFTABLES_SYSTEMD_DROPIN" \
        "${ROLLBACK_DIR}/nftables.service.dropin.before"
      printf '%s\n' present >"${ROLLBACK_DIR}/nftables.service.dropin.state"
    else
      printf '%s\n' absent >"${ROLLBACK_DIR}/nftables.service.dropin.state"
    fi
  fi
}

unmanaged_vpn_table_present() {
  nft list table inet vpn_filter >/dev/null 2>&1 && \
    [[ ! -f "${STATE_DIR}/firewall.managed" ]]
}

write_firewall_candidate() {
  local candidate="$1"
  cat >"$candidate" <<EOF
#!/usr/sbin/nft -f
# Only table inet vpn_filter is managed by VPN setup.
# Other nftables tables are intentionally preserved.
add table inet vpn_filter
flush table inet vpn_filter

table inet vpn_filter {
  chain input {
    type filter hook input priority filter; policy drop;

    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp dport { ${SSH_PORT}, 80, 443, ${SUBSCRIPTION_PORT} } ct state new accept
    udp dport 443 ct state new accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
}

stop_pending_firewall_rollback() {
  local unit_base
  unit_base="$(cat "$FIREWALL_UNIT_STATE" 2>/dev/null || true)"
  if [[ -n "$unit_base" ]]; then
    systemctl stop "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || true
  fi
  rm -f -- "$FIREWALL_UNIT_STATE"
}

# The optional state path is an intentional test seam. Production callers use
# FIREWALL_UNIT_STATE, while the smoke test exercises cancellation in /tmp.
# shellcheck disable=SC2120
cancel_pending_firewall_rollback_strict() {
  local state_file="${1:-$FIREWALL_UNIT_STATE}"
  local unit_base timer_state service_state
  unit_base="$(cat "$state_file" 2>/dev/null || true)"
  [[ -n "$unit_base" ]] || return 1
  [[ "$unit_base" =~ ^vpn-nft-rollback-[0-9]+-[0-9]+$ ]] || return 1

  # The transient service is normally not loaded until its timer fires.  Some
  # systemd versions return a failure when asked to stop that absent service,
  # even though stopping the timer succeeded.  Treat unit state, rather than a
  # combined stop exit code, as the security invariant.
  service_state="$(systemctl show --property=ActiveState --value "${unit_base}.service" 2>/dev/null || true)"
  case "$service_state" in
    active|activating|reloading|deactivating)
      return 1
      ;;
  esac

  systemctl stop "${unit_base}.timer" >/dev/null 2>&1 || true
  timer_state="$(systemctl show --property=ActiveState --value "${unit_base}.timer" 2>/dev/null || true)"
  service_state="$(systemctl show --property=ActiveState --value "${unit_base}.service" 2>/dev/null || true)"
  case "$timer_state" in
    active|activating|reloading|deactivating) return 1 ;;
  esac
  case "$service_state" in
    active|activating|reloading|deactivating) return 1 ;;
  esac
  if systemctl is-active --quiet "${unit_base}.timer" 2>/dev/null ||
     systemctl is-active --quiet "${unit_base}.service" 2>/dev/null; then
    return 1
  fi
  systemctl reset-failed "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || true
  rm -f -- "$state_file"
}

schedule_firewall_rollback() {
  local unit_base
  stop_pending_firewall_rollback
  unit_base="vpn-nft-rollback-$(date +%s)-$$"
  systemd-run --quiet --unit="$unit_base" --on-active=5m \
    "$INSTALLED_HELPER" rollback-firewall --automatic
  if ! systemctl is-active --quiet "${unit_base}.timer"; then
    systemctl stop "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || true
    die 'The automatic firewall rollback timer did not become active; refusing to apply the firewall.'
  fi
  printf '%s\n' "$unit_base" >"$FIREWALL_UNIT_STATE"
  chmod 0600 "$FIREWALL_UNIT_STATE"
}

apply_firewall() {
  local candidate
  require_command flock
  exec 5>"$FIREWALL_LOCK_FILE"
  flock -x 5
  if unmanaged_vpn_table_present; then
    die 'An unmanaged table inet vpn_filter already exists; refusing to overwrite that table.'
  fi

  save_firewall_baseline
  configure_nftables_service_boundary
  candidate="$(mktemp)"
  write_firewall_candidate "$candidate"
  nft --check --file "$candidate"
  write_atomic "$NFT_CONFIG" root root 0644 "$candidate"
  rm -f -- "$candidate"

  schedule_firewall_rollback
  nft --file "$NFT_CONFIG"
  printf '%s\n' "managed $(date --iso-8601=seconds)" >"${STATE_DIR}/firewall.managed"
  chmod 0600 "${STATE_DIR}/firewall.managed"

  [[ -n "$(port_is_listening tcp "$SSH_PORT" || true)" ]] || die 'SSH listener disappeared after firewall application.'
  log 'Firewall applied with automatic rollback in five minutes.'
}

rollback_firewall() {
  local table_backup="${ROLLBACK_DIR}/vpn_filter.table.before"
  require_root
  if (( AUTOMATIC == 0 )); then
    require_confirmation
  fi
  require_command flock
  exec 5>"$FIREWALL_LOCK_FILE"
  flock -x 5

  if (( AUTOMATIC == 1 )) && [[ -f "${STATE_DIR}/firewall.confirmed" ]]; then
    rm -f -- "$FIREWALL_UNIT_STATE"
    log 'Automatic firewall rollback skipped because the firewall was already confirmed.'
    return
  fi

  [[ -f "${ROLLBACK_DIR}/vpn_filter.table.state" ]] || die 'No firewall rollback state exists.'
  if (( AUTOMATIC == 0 )); then
    stop_pending_firewall_rollback
  fi
  log 'Restoring the previous firewall state.'
  if nft list table inet vpn_filter >/dev/null 2>&1; then
    nft delete table inet vpn_filter
  fi
  if [[ "$(cat "${ROLLBACK_DIR}/vpn_filter.table.state")" == "present" ]]; then
    [[ -s "$table_backup" ]] || die 'The previous managed-table backup is missing.'
    nft --file "$table_backup"
  fi

  if [[ "$(cat "${ROLLBACK_DIR}/nftables.conf.state" 2>/dev/null || true)" == "present" ]]; then
    install -o root -g root -m 0644 "${ROLLBACK_DIR}/nftables.conf.before" "$NFT_CONFIG"
  else
    rm -f -- "$NFT_CONFIG"
  fi

  if [[ "$(cat "${ROLLBACK_DIR}/nftables.service.state" 2>/dev/null || true)" == "enabled" ]]; then
    systemctl enable nftables.service >/dev/null
  else
    systemctl disable nftables.service >/dev/null 2>&1 || true
  fi
  if [[ "$(cat "${ROLLBACK_DIR}/nftables.service.dropin.state" 2>/dev/null || true)" == "present" ]]; then
    install -o root -g root -m 0644 "${ROLLBACK_DIR}/nftables.service.dropin.before" \
      "$NFTABLES_SYSTEMD_DROPIN"
  else
    rm -f -- "$NFTABLES_SYSTEMD_DROPIN"
  fi
  systemctl daemon-reload
  rm -f -- "${STATE_DIR}/firewall.managed" "${STATE_DIR}/firewall.confirmed" "$FIREWALL_UNIT_STATE"
  log 'Previous firewall state restored.'
}

confirm_firewall() {
  local confirmed_candidate="${STATE_DIR}/firewall.confirmed.new"
  require_root
  require_confirmation
  require_command flock
  exec 5>"$FIREWALL_LOCK_FILE"
  flock -x 5
  [[ -f "${STATE_DIR}/firewall.managed" ]] || die 'No pending managed firewall exists.'
  nftables_service_boundary_is_healthy || \
    die 'The nftables service boundary is missing; refusing to confirm an unsafe firewall.'
  nft --check --file "$NFT_CONFIG"
  [[ -n "$(port_is_listening tcp "$SSH_PORT" || true)" ]] || die 'SSH is not listening; refusing confirmation.'
  systemctl enable --now nftables.service >/dev/null
  systemctl is-active --quiet nftables.service || \
    die 'nftables persistence service did not become active; firewall confirmation was not recorded.'
  # shellcheck disable=SC2119
  cancel_pending_firewall_rollback_strict || \
    die 'Could not prove that the automatic rollback timer was cancelled; firewall confirmation was not recorded.'
  # Re-check the live rules after cancelling the timer so a timer firing at the
  # boundary can never be recorded as a successful confirmation.
  nft list chain inet vpn_filter input >/dev/null 2>&1 || \
    die 'The managed firewall disappeared while cancelling rollback; confirmation was not recorded.'
  [[ -n "$(port_is_listening tcp "$SSH_PORT" || true)" ]] || \
    die 'SSH stopped listening while cancelling rollback; confirmation was not recorded.'
  printf '%s\n' "confirmed $(date --iso-8601=seconds)" >"$confirmed_candidate"
  chmod 0600 "$confirmed_candidate"
  mv -f -- "$confirmed_candidate" "${STATE_DIR}/firewall.confirmed"
  log 'Firewall persistence confirmed; automatic rollback cancelled.'
}

render_auto_finalize_wrapper() {
  local candidate="$1"
  cat >"$candidate" <<EOF
#!/bin/sh
# Managed by vpn-setup. Removed after the first successful administrator login.
set -u

if [ -n "\${SSH_ORIGINAL_COMMAND:-}" ]; then
  printf '%s\n' 'Open one interactive SSH session before using SCP, SFTP, or remote commands.' >&2
  exit 1
fi

if ! /usr/bin/sudo -n "${INSTALLED_HELPER}" finalize --yes; then
  printf '%s\n' 'Automatic VPN security finalization failed. This login remains available for health checks.' >&2
fi

login_shell="\${SHELL:-/bin/bash}"
if [ ! -x "\$login_shell" ]; then
  login_shell=/bin/bash
fi
exec "\$login_shell" -l
EOF
}

render_auto_finalize_ssh_dropin() {
  local candidate="$1"
  cat >"$candidate" <<EOF
# Managed by vpn-setup. Removed after the first successful administrator login.
Match User ${ADMIN_USER}
    DisableForwarding yes
    ForceCommand ${AUTO_FINALIZE_WRAPPER}
Match all
EOF
}

ensure_sshd_runtime_directory() {
  local runtime_dir='/run/sshd'

  if [[ -e "$runtime_dir" ]]; then
    [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]] || \
      die "Refusing to use unexpected SSH runtime path: ${runtime_dir}"
  fi
  install -d -o root -g root -m 0755 "$runtime_dir"
}

reload_ssh_runtime() {
  if systemctl is-active --quiet ssh.service; then
    systemctl reload ssh.service
  elif systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  else
    systemctl reload-or-restart ssh.service
  fi
}

remove_auto_finalization() {
  local restore_required=0
  require_root

  if [[ ! -e "$AUTO_FINALIZE_SSH_DROPIN" &&
        ! -e "$AUTO_FINALIZE_REMOVAL_STAGE" &&
        ! -e "$AUTO_FINALIZE_WRAPPER" ]]; then
    return
  fi

  if [[ -e "$AUTO_FINALIZE_SSH_DROPIN" ]]; then
    [[ -f "$AUTO_FINALIZE_SSH_DROPIN" && ! -L "$AUTO_FINALIZE_SSH_DROPIN" ]] || \
      die "Refusing to remove unexpected automatic-finalization SSH path: ${AUTO_FINALIZE_SSH_DROPIN}"
    grep -Fq '# Managed by vpn-setup. Removed after the first successful administrator login.' \
      "$AUTO_FINALIZE_SSH_DROPIN" || \
      die "Refusing to remove an unmanaged SSH configuration: ${AUTO_FINALIZE_SSH_DROPIN}"
    [[ ! -e "$AUTO_FINALIZE_REMOVAL_STAGE" ]] || \
      die "Stale automatic-finalization removal state exists: ${AUTO_FINALIZE_REMOVAL_STAGE}"
    mv -- "$AUTO_FINALIZE_SSH_DROPIN" "$AUTO_FINALIZE_REMOVAL_STAGE"
    restore_required=1
  fi

  ensure_sshd_runtime_directory
  if ! /usr/sbin/sshd -t; then
    if (( restore_required == 1 )); then
      mv -- "$AUTO_FINALIZE_REMOVAL_STAGE" "$AUTO_FINALIZE_SSH_DROPIN"
    fi
    die 'sshd validation failed while removing automatic first-login finalization.'
  fi
  if ! reload_ssh_runtime; then
    if (( restore_required == 1 )); then
      mv -- "$AUTO_FINALIZE_REMOVAL_STAGE" "$AUTO_FINALIZE_SSH_DROPIN"
      if /usr/sbin/sshd -t >/dev/null 2>&1; then
        reload_ssh_runtime >/dev/null 2>&1 || true
      fi
    fi
    die 'SSH reload failed while removing automatic first-login finalization.'
  fi

  rm -f -- "$AUTO_FINALIZE_WRAPPER" "$AUTO_FINALIZE_REMOVAL_STAGE"
}

configure_auto_finalization() {
  local wrapper_candidate dropin_candidate effective
  require_root

  if [[ -f "${STATE_DIR}/firewall.confirmed" ]] && ssh_lockdown_is_effective; then
    remove_auto_finalization
    return
  fi

  if [[ -e "$AUTO_FINALIZE_WRAPPER" ]]; then
    [[ -f "$AUTO_FINALIZE_WRAPPER" && ! -L "$AUTO_FINALIZE_WRAPPER" ]] || \
      die "Refusing to replace unexpected automatic-finalization wrapper: ${AUTO_FINALIZE_WRAPPER}"
    grep -Fq '# Managed by vpn-setup. Removed after the first successful administrator login.' \
      "$AUTO_FINALIZE_WRAPPER" || \
      die "Refusing to replace an unmanaged wrapper: ${AUTO_FINALIZE_WRAPPER}"
  fi
  if [[ -e "$AUTO_FINALIZE_SSH_DROPIN" ]]; then
    [[ -f "$AUTO_FINALIZE_SSH_DROPIN" && ! -L "$AUTO_FINALIZE_SSH_DROPIN" ]] || \
      die "Refusing to replace unexpected automatic-finalization SSH path: ${AUTO_FINALIZE_SSH_DROPIN}"
    grep -Fq '# Managed by vpn-setup. Removed after the first successful administrator login.' \
      "$AUTO_FINALIZE_SSH_DROPIN" || \
      die "Refusing to replace an unmanaged SSH configuration: ${AUTO_FINALIZE_SSH_DROPIN}"
  fi

  ensure_sshd_runtime_directory
  install -d -o root -g root -m 0755 "$(dirname "$AUTO_FINALIZE_WRAPPER")"
  wrapper_candidate="$(mktemp)"
  render_auto_finalize_wrapper "$wrapper_candidate"
  sh -n "$wrapper_candidate"
  write_atomic "$AUTO_FINALIZE_WRAPPER" root root 0755 "$wrapper_candidate"
  rm -f -- "$wrapper_candidate"

  dropin_candidate="$(mktemp)"
  render_auto_finalize_ssh_dropin "$dropin_candidate"
  write_atomic "$AUTO_FINALIZE_SSH_DROPIN" root root 0644 "$dropin_candidate"
  rm -f -- "$dropin_candidate"

  if ! /usr/sbin/sshd -t; then
    rm -f -- "$AUTO_FINALIZE_SSH_DROPIN" "$AUTO_FINALIZE_WRAPPER"
    die 'sshd rejected the temporary automatic-finalization rule; it was removed.'
  fi
  if ! effective="$(/usr/sbin/sshd -T -C \
    "user=${ADMIN_USER},host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=${SSH_PORT}")"; then
    rm -f -- "$AUTO_FINALIZE_SSH_DROPIN" "$AUTO_FINALIZE_WRAPPER"
    die 'Unable to evaluate the administrator SSH policy; temporary automatic-finalization files were removed.'
  fi
  if ! grep -Fxq "forcecommand ${AUTO_FINALIZE_WRAPPER}" <<<"$effective" ||
     ! grep -Fxq 'disableforwarding yes' <<<"$effective"; then
    rm -f -- "$AUTO_FINALIZE_SSH_DROPIN" "$AUTO_FINALIZE_WRAPPER"
    die 'The effective administrator SSH policy did not activate automatic finalization; temporary files were removed.'
  fi
  if ! reload_ssh_runtime; then
    rm -f -- "$AUTO_FINALIZE_SSH_DROPIN" "$AUTO_FINALIZE_WRAPPER"
    if /usr/sbin/sshd -t >/dev/null 2>&1; then
      reload_ssh_runtime >/dev/null 2>&1 || true
    fi
    die 'SSH could not load the temporary automatic-finalization rule; it was removed.'
  fi
  log 'Armed one-time automatic security finalization for the first administrator SSH login.'
}

lockdown_ssh() {
  local candidate invoking_user effective admin_home authorized_keys
  require_root
  require_confirmation
  invoking_user="${SUDO_USER:-}"
  [[ "$invoking_user" == "$ADMIN_USER" ]] || die "Run this command from a verified ${ADMIN_USER} session using sudo."
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  [[ -n "$admin_home" && -d "$admin_home" ]] || die "Home directory for ${ADMIN_USER} is unavailable."
  path_has_symlink_component "$admin_home" && \
    die "Home path for ${ADMIN_USER} contains a symbolic link: ${admin_home}"
  authorized_keys="${admin_home}/.ssh/authorized_keys"
  [[ ! -L "${admin_home}/.ssh" && ! -L "$authorized_keys" && -s "$authorized_keys" ]] || \
    die 'Admin authorized_keys is missing or unsafe.'
  ssh-keygen -l -f "$authorized_keys" >/dev/null

  ensure_sshd_runtime_directory
  candidate="$(mktemp)"
  cat >"$candidate" <<EOF
# Managed by VPN setup. Applied only after verified key login.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
X11Forwarding no
DisableForwarding yes
PermitUserEnvironment no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers ${ADMIN_USER}
EOF
  write_atomic "$SSH_DROPIN" root root 0644 "$candidate"
  rm -f -- "$candidate"

  if ! /usr/sbin/sshd -t; then
    rm -f -- "$SSH_DROPIN"
    die 'sshd validation failed; hardening drop-in removed.'
  fi
  effective="$(/usr/sbin/sshd -T)"
  if ! grep -Fxq 'permitrootlogin no' <<<"$effective" ||
     ! grep -Fxq 'passwordauthentication no' <<<"$effective" ||
     ! grep -Fxq 'kbdinteractiveauthentication no' <<<"$effective" ||
     ! grep -Fxq 'authenticationmethods publickey' <<<"$effective"; then
    rm -f -- "$SSH_DROPIN"
    die 'Effective SSH security settings did not match the required key-only policy; drop-in removed.'
  fi
  reload_ssh_runtime
  log 'SSH lockdown applied: key-only, no root login, no password login.'
}

finalize_installation() {
  local invoking_user
  require_root
  require_confirmation
  # Finalization is the single user-approved transaction. Nested firewall and
  # SSH operations must not ask for two additional confirmations.
  ASSUME_YES=1
  load_settings
  invoking_user="${SUDO_USER:-}"
  [[ "$invoking_user" == "$ADMIN_USER" ]] || \
    die "Run finalization from an SSH session of ${ADMIN_USER} using sudo."
  [[ -f "$INSTALL_COMPLETE_FILE" ]] || \
    die 'Installation payload is not complete; rerun the install command first.'

  acquire_operation_lock
  load_settings

  if [[ ! -f "${STATE_DIR}/firewall.confirmed" ]]; then
    if [[ ! -f "${STATE_DIR}/firewall.managed" ]]; then
      warn 'The previous firewall safety window expired before a verified administrator login.'
      apply_firewall
    fi
    # The caller has already reached the administrator account and authorized
    # this transaction. Check the live SSH listener and explicit accept rule,
    # persist the policy, and cancel rollback in the same transaction. The
    # already authenticated session remains available throughout the change.
    confirm_firewall
  fi

  # Re-render and validate the drop-in even when it already exists. This keeps
  # finalization idempotent and proves the effective sshd policy before reload.
  lockdown_ssh
  remove_auto_finalization
  log 'VPN server setup finalized: firewall persistent and SSH key-only.'
  printf '%s\n' 'One-time security setup complete. Future SSH logins require the configured key.'
  printf '%s\n' 'No further setup command or reconnect is required.'
}
