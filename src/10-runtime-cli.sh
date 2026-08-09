log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

terminal_supports_style() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] || return 1
  if (( INSTALL_LOG_ACTIVE == 1 )) && [[ -t 6 ]]; then
    return 0
  fi
  [[ -t 1 ]]
}

style_text() {
  local style="$1"
  shift
  if terminal_supports_style; then
    printf '\033[%sm%s\033[0m' "$style" "$*"
  else
    printf '%s' "$*"
  fi
}

print_title() {
  printf '\n'
  style_text '1;36' "$*"
  printf '\n'
}

print_section() {
  printf '\n'
  style_text '1' "$*"
  printf '\n'
}

print_status_value() {
  local value="$1"
  case "$value" in
    PASS|OK|HEALTHY) style_text '1;32' "$value" ;;
    WARN) style_text '1;33' "$value" ;;
    FAIL|UNHEALTHY) style_text '1;31' "$value" ;;
    *) printf '%s' "$value" ;;
  esac
}

print_status_row() {
  local label="$1" state="$2" details="$3"
  printf '  %-14s ' "$label"
  print_status_value "$state"
  printf '  %s\n' "$details"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  printf '[ERROR] Step: %s\n' "$CURRENT_STEP" >&2
  if [[ -n "$INSTALL_LOG_FILE" ]]; then
    printf '[ERROR] Full installation log: %s (root-only; review before sharing)\n' \
      "$INSTALL_LOG_FILE" >&2
  fi
  exit 1
}

on_error() {
  local exit_code=$?
  local failed_command="${BASH_COMMAND:-unknown}"
  local source_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  local source_line="${BASH_LINENO[0]:-unknown}"
  local index

  (( ERROR_REPORTED == 0 )) || return "$exit_code"
  ERROR_REPORTED=1
  trap - ERR

  printf '\n[ERROR] Installation command failed.\n' >&2
  printf '[ERROR] Step: %s\n' "$CURRENT_STEP" >&2
  printf '[ERROR] Exit code: %s\n' "$exit_code" >&2
  printf '[ERROR] Location: %s:%s\n' "$source_file" "$source_line" >&2
  printf '[ERROR] Command: %s\n' "$failed_command" >&2
  printf '[ERROR] Call stack:\n' >&2
  for (( index=1; index<${#FUNCNAME[@]}; index++ )); do
    printf '  %s at %s:%s\n' \
      "${FUNCNAME[$index]}" \
      "${BASH_SOURCE[$index]:-unknown}" \
      "${BASH_LINENO[$((index - 1))]:-unknown}" >&2
  done
  if [[ -n "$INSTALL_LOG_FILE" ]]; then
    printf '[ERROR] Full installation log: %s (root-only; review before sharing)\n' \
      "$INSTALL_LOG_FILE" >&2
  fi
  printf '[ERROR] Correct the reported cause, then run the same install command again.\n' >&2
  return "$exit_code"
}

set_step() {
  CURRENT_STEP="$1"
  log "STEP: ${CURRENT_STEP}"
}

redact_install_stream() {
  local escape_sequence=$'\033'
  sed -E \
    -e "s/${escape_sequence}\\[[0-9;]*[[:alpha:]]//g" \
    -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[EMAIL-REDACTED]/g' \
    -e 's#(ssh-ed25519|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([^[:space:]]*)?#\1 [SSH-PUBLIC-KEY-REDACTED]#g' | \
    redact_health_stream
}

capture_install_output() {
  local destination="$1" terminal_fifo terminal_pid pipeline_status=0 terminal_status=0
  terminal_fifo="${destination}.terminal.$$"
  mkfifo -m 0600 "$terminal_fifo"
  cat "$terminal_fifo" >&6 &
  terminal_pid=$!

  # tee forwards bytes through one ordered stream, including Bash prompts
  # without a trailing newline. The FIFO avoids reopening /dev/fd entries,
  # which is not portable across all development and runtime environments.
  if tee "$terminal_fifo" | redact_install_stream | LC_ALL=C awk -v max="$INSTALL_LOG_MAX_BYTES" '
    {
      bytes = length($0) + 1
      if (written + bytes <= max) {
        print
        written += bytes
      } else if (!truncated) {
        print "[LOG TRUNCATED: retained output reached the 1 MiB limit]"
        truncated = 1
      }
    }
  ' >"$destination"; then
    pipeline_status=0
  else
    pipeline_status=$?
  fi
  wait "$terminal_pid" || terminal_status=$?
  rm -f -- "$terminal_fifo"
  (( pipeline_status == 0 )) || return "$pipeline_status"
  return "$terminal_status"
}

sanitize_install_log_file() {
  local file="$1" staged
  [[ -f "$file" && ! -L "$file" ]] || return 0
  staged="${file}.trimmed.$$"
  redact_install_stream <"$file" | LC_ALL=C awk -v max="$INSTALL_LOG_MAX_BYTES" '
    {
      bytes = length($0) + 1
      if (written + bytes <= max) {
        print
        written += bytes
      } else if (!truncated) {
        print "[LOG TRUNCATED: retained output reached the 1 MiB limit]"
        truncated = 1
      }
    }
  ' >"$staged"
  chmod 0600 "$staged"
  mv -f -- "$staged" "$file"
}

rotate_install_logs() {
  local entry file index=0
  local -a logs=()
  while IFS= read -r entry; do
    logs+=("${entry#* }")
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name 'install-*.log' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn)
  for file in "${logs[@]}"; do
    if (( index < INSTALL_LOG_RETENTION )); then
      sanitize_install_log_file "$file"
    else
      rm -f -- "$file"
    fi
    (( index += 1 ))
  done
}
start_install_log() {
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  install -d -o root -g root -m 0700 "$LOG_DIR"
  rotate_install_logs
  INSTALL_LOG_FILE="${LOG_DIR}/install-${timestamp}-$$.log"
  install -o root -g root -m 0600 /dev/null "$INSTALL_LOG_FILE"
  # Keep the original output on a private descriptor so cleanup can close the
  # pipe and wait for the bounded redacting writer. Bash does not otherwise
  # guarantee that an asynchronous process substitution has flushed on exit.
  exec 6>&1
  exec > >(capture_install_output "$INSTALL_LOG_FILE") 2>&1
  INSTALL_TEE_PID=$!
  INSTALL_LOG_ACTIVE=1
  log "Detailed root-only installation log: ${INSTALL_LOG_FILE}"
}

finish_install_log() {
  (( INSTALL_LOG_ACTIVE == 1 )) || return 0
  INSTALL_LOG_ACTIVE=0

  # Redirect away from tee before waiting, otherwise this shell would retain a
  # writer for the pipe and the wait could deadlock.
  exec 1>&6 2>&1 6>&-
  if [[ -n "$INSTALL_TEE_PID" ]]; then
    wait "$INSTALL_TEE_PID" 2>/dev/null || warn 'The bounded installation log writer exited unexpectedly.'
  fi
  INSTALL_TEE_PID=""
  rotate_install_logs
}

begin_mutation_commit() {
  (( MUTATION_COMMIT_ACTIVE == 0 )) || die 'Internal error: nested mutation commit.'
  MUTATION_COMMIT_ACTIVE=1
  DEFERRED_MUTATION_SIGNAL=""
  DEFERRED_MUTATION_STATUS=0
  trap 'DEFERRED_MUTATION_SIGNAL=HUP; DEFERRED_MUTATION_STATUS=129' HUP
  trap 'DEFERRED_MUTATION_SIGNAL=INT; DEFERRED_MUTATION_STATUS=130' INT
  trap 'DEFERRED_MUTATION_SIGNAL=TERM; DEFERRED_MUTATION_STATUS=143' TERM
}

finish_mutation_commit() {
  local deferred_signal="$DEFERRED_MUTATION_SIGNAL"
  local deferred_status="$DEFERRED_MUTATION_STATUS"
  trap - HUP INT TERM
  MUTATION_COMMIT_ACTIVE=0
  DEFERRED_MUTATION_SIGNAL=""
  DEFERRED_MUTATION_STATUS=0
  if [[ -n "$deferred_signal" ]]; then
    warn "Received ${deferred_signal} during an atomic state change; the signal was deferred until the state became consistent."
    exit "$deferred_status"
  fi
}

acquire_operation_lock() {
  require_command flock
  exec 7>"$INSTALL_LOCK_FILE"
  flock -x 7
}

acquire_bootstrap_lock() {
  if mkdir "$BOOTSTRAP_LOCK_DIR" 2>/dev/null; then
    BOOTSTRAP_LOCK_OWNED=1
    return
  fi
  die 'Another VPN installation process is already running (bootstrap lock is held).'
}

release_bootstrap_lock() {
  (( BOOTSTRAP_LOCK_OWNED == 1 )) || return 0
  rmdir "$BOOTSTRAP_LOCK_DIR" 2>/dev/null || \
    warn "Could not remove bootstrap lock directory: ${BOOTSTRAP_LOCK_DIR}"
  BOOTSTRAP_LOCK_OWNED=0
}

acquire_install_flock() {
  require_command flock
  exec 7>"$INSTALL_LOCK_FILE"
  flock -n 7 || die 'Another VPN installation or upgrade process is already running.'
}

cleanup() {
  if (( UPGRADE_ROLLBACK_ACTIVE == 1 )); then
    rollback_upgrade_transaction
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    if (( MUTATION_COMMIT_ACTIVE == 1 )); then
      printf '[FATAL] An unexpected exit occurred during a live state change. Preserving transaction backups for manual recovery: %s\n' \
        "$TEMP_ROOT" >&2
    else
      rm -rf -- "$TEMP_ROOT"
    fi
  fi
  if (( UPGRADE_ROLLBACK_FAILED == 0 )) && [[ -n "$UPGRADE_BACKUP_DIR" && -d "$UPGRADE_BACKUP_DIR" ]]; then
    rm -rf -- "$UPGRADE_BACKUP_DIR"
  elif (( UPGRADE_ROLLBACK_FAILED == 1 )) && [[ -n "$UPGRADE_BACKUP_DIR" ]]; then
    printf '[FATAL] Preserved incomplete overlay rollback state for manual recovery: %s\n' \
      "$UPGRADE_BACKUP_DIR" >&2
  fi
  release_bootstrap_lock
  finish_install_log
}

new_temp_dir() {
  if [[ -z "$TEMP_ROOT" ]]; then
    TEMP_ROOT="$(mktemp -d)"
    chmod 0700 "$TEMP_ROOT"
  fi
  TMP_DIR="$(mktemp -d "${TEMP_ROOT}/operation.XXXXXX")"
  chmod 0700 "$TMP_DIR"
}

trap on_error ERR
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  ./install-sing-box-server.sh plan
  sudo ./install-sing-box-server.sh check
  sudo ./install-sing-box-server.sh install
  sudo ./install-sing-box-server.sh upgrade
  vpn health [--verbose]
  vpn add NAME
  vpn show [NAME]
  vpn delete NAME
  vpn audit-target [DOMAIN]
  vpn set-target DOMAIN
  vpn set-fingerprint [VALUE]
  vpn set-obfs [off|salamander]
  vpn update
  vpn self-update /path/to/new/install-sing-box-server.sh

Install options (missing values are requested interactively):
  --admin-user NAME        Administrative account to create.
  --public-key KEY         One quoted OpenSSH public-key line. Never a private key.
  --server-ipv4 ADDRESS    Public IPv4 address of the VPS.
  --domain DOMAIN          Domain whose A record points to the VPS.
  --email ADDRESS          ACME account email for the TLS certificate.
  --ssh-port PORT          Existing SSH port (default: 22).
  --reality-target DOMAIN  REALITY handshake target (required; no universal default).
  --fingerprint VALUE      Initial client TLS fingerprint (default: chrome).
  --emoji EMOJI            Server/country emoji for non-interactive installs.
  --yes                    Skip the final confirmation prompt for a mutating operation.
  --verbose                Show a redacted report; review it before sharing.
  --automatic              Internal use by the firewall rollback timer.
  -h, --help               Show this help.

The default command is "plan". Both "plan" and "check" are read-only.
EOF
}

parse_args() {
  if (( $# > 0 )) && [[ "$1" != -* ]]; then
    case "$1" in
      add|delete)
        COMMAND="client-$1"
        (( $# >= 2 )) || die "$1 requires a client name."
        CLIENT_NAME="$2"
        shift 2
        ;;
      show)
        if (( $# >= 2 )) && [[ "$2" != -* ]]; then
          COMMAND="client-show"
          CLIENT_NAME="$2"
          shift 2
        else
          COMMAND="client-list"
          shift
        fi
        ;;
      set-target)
        COMMAND="set-target"
        (( $# >= 2 )) || die 'set-target requires a domain.'
        NEW_REALITY_TARGET="$2"
        shift 2
        ;;
      audit-target)
        COMMAND="audit-target"
        if (( $# >= 2 )) && [[ "$2" != -* ]]; then
          AUDIT_TARGET="$2"
          shift 2
        else
          shift
        fi
        ;;
      set-fingerprint)
        COMMAND="set-fingerprint"
        if (( $# >= 2 )) && [[ "$2" != -* ]]; then
          NEW_CLIENT_FINGERPRINT="$2"
          shift 2
        else
          shift
        fi
        ;;
      set-obfs)
        COMMAND="set-obfs"
        if (( $# >= 2 )) && [[ "$2" != -* ]]; then
          NEW_HY2_OBFS_MODE="$2"
          shift 2
        else
          shift
        fi
        ;;
      self-update)
        COMMAND="self-update"
        (( $# >= 2 )) || die 'self-update requires a path to a newer installer file.'
        SELF_UPDATE_SOURCE="$2"
        shift 2
        ;;
      *)
        COMMAND="$1"
        shift
        ;;
    esac
  fi

  while (( $# > 0 )); do
    case "$1" in
      --email)
        (( $# >= 2 )) || die '--email requires a value.'
        ACME_EMAIL="$2"
        shift 2
        ;;
      --admin-user)
        (( $# >= 2 )) || die '--admin-user requires a value.'
        ADMIN_USER="$2"
        shift 2
        ;;
      --public-key)
        (( $# >= 2 )) || die '--public-key requires a value.'
        ADMIN_PUBLIC_KEY="$2"
        shift 2
        ;;
      --server-ipv4)
        (( $# >= 2 )) || die '--server-ipv4 requires a value.'
        SERVER_IPV4="$2"
        shift 2
        ;;
      --domain)
        (( $# >= 2 )) || die '--domain requires a value.'
        TLS_DOMAIN="$2"
        shift 2
        ;;
      --ssh-port)
        (( $# >= 2 )) || die '--ssh-port requires a value.'
        SSH_PORT="$2"
        shift 2
        ;;
      --reality-target)
        (( $# >= 2 )) || die '--reality-target requires a value.'
        REALITY_TARGET="$2"
        shift 2
        ;;
      --fingerprint)
        (( $# >= 2 )) || die '--fingerprint requires a value.'
        CLIENT_FINGERPRINT="$2"
        shift 2
        ;;
      --emoji)
        (( $# >= 2 )) || die '--emoji requires a value.'
        COUNTRY_EMOJI="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --automatic)
        AUTOMATIC=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}
