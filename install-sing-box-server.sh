#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Single-core VPN server installer for a clean supported amd64 VPS.
#
# Default action is read-only:
#   ./install-sing-box-server.sh plan
#   sudo ./install-sing-box-server.sh check
#
# Interactive installation:
#   sudo ./install-sing-box-server.sh install
#
# Management after installation:
#   sudo vpn add WorkPC
#   sudo vpn show WorkPC
#   sudo vpn set-target example.com
#   sudo vpn set-fingerprint
#   sudo vpn update
#   sudo vpn self-update /path/to/new/install-sing-box-server.sh
#   sudo vpn diagnostic
#
# This script intentionally does not install a web panel, Docker, Xray, UFW,
# fail2ban, or experimental sing-box builds. nginx-light serves only private,
# tokenized, read-only subscription files.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_VERSION="1.0.0"
readonly PROJECT_NAME="vpn-setup"
readonly SAGERNET_KEY_URL="https://sing-box.app/gpg.key"
readonly SAGERNET_KEY_FILE="/etc/apt/keyrings/sagernet.asc"
readonly SAGERNET_SOURCE_FILE="/etc/apt/sources.list.d/sagernet.sources"

readonly STATE_DIR="/var/lib/${PROJECT_NAME}"
readonly ROLLBACK_DIR="${STATE_DIR}/rollback"
readonly SECRETS_FILE="${STATE_DIR}/server-secrets.env"
readonly CLIENTS_FILE="${STATE_DIR}/clients.json"
readonly CLIENT_LOCK_FILE="${STATE_DIR}/clients.lock"
readonly SETTINGS_FILE="${STATE_DIR}/settings.json"
readonly INSTALL_COMPLETE_FILE="${STATE_DIR}/install.complete"
readonly INSTALL_LOCK_FILE="${STATE_DIR}/install.lock"
readonly FIREWALL_LOCK_FILE="${STATE_DIR}/firewall.lock"
readonly PACKAGE_CACHE_DIR="${STATE_DIR}/packages"
readonly INSTALLER_BACKUP_DIR="${STATE_DIR}/installer-backups"
readonly INITIAL_CLIENT_NAME="default"
readonly DEFAULT_CLIENT_FINGERPRINT="chrome"
readonly -a SUPPORTED_CLIENT_FINGERPRINTS=(
  chrome firefox safari ios android edge 360 qq random
)
readonly SUBSCRIPTION_PORT="8443"
readonly SUBSCRIPTION_ROOT="/var/www/vpn-subscriptions"
readonly NGINX_SITE="/etc/nginx/sites-available/vpn-subscription"
readonly NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/vpn-subscription"
readonly UDP_BUFFER_MAX="7340032"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly CERT_DIR="${CONFIG_DIR}/certs"
readonly SYSTEMD_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly SYSTEMD_DROPIN="${SYSTEMD_DROPIN_DIR}/10-vpn-hardening.conf"
readonly JOURNAL_DROPIN_DIR="/etc/systemd/journald.conf.d"
readonly JOURNAL_DROPIN="${JOURNAL_DROPIN_DIR}/90-vpn-limits.conf"
readonly UDP_SYSCTL_FILE="/etc/sysctl.d/90-vpn-udp-buffers.conf"
readonly NFT_CONFIG="/etc/nftables.conf"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/00-vpn-hardening.conf"
readonly INSTALLED_HELPER="/usr/local/sbin/vpn"
readonly CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/50-vpn-sing-box"
readonly FIREWALL_UNIT_STATE="${STATE_DIR}/firewall.rollback.unit"
readonly LOG_DIR="/var/log/${PROJECT_NAME}"

ADMIN_USER=""
ADMIN_PUBLIC_KEY=""
SERVER_IPV4=""
TLS_DOMAIN=""
SSH_PORT=""
REALITY_TARGET=""
COUNTRY_EMOJI=""
ACME_EMAIL=""
CLIENT_FINGERPRINT=""
ASSUME_YES=0
AUTOMATIC=0
COMMAND="plan"
TMP_DIR=""
CLIENT_NAME=""
NEW_REALITY_TARGET=""
NEW_CLIENT_FINGERPRINT=""
SELF_UPDATE_SOURCE=""
OS_ID=""
OS_VERSION=""
OS_PRETTY_NAME=""
CURRENT_STEP="startup"
INSTALL_LOG_FILE=""
INSTALL_TEE_PID=""
INSTALL_LOG_ACTIVE=0
MUTATION_COMMIT_ACTIVE=0
DEFERRED_MUTATION_SIGNAL=""
DEFERRED_MUTATION_STATUS=0
ERROR_REPORTED=0
UPGRADE_ROLLBACK_ACTIVE=0
UPGRADE_ROLLBACK_FAILED=0
UPGRADE_BACKUP_DIR=""
UPGRADE_ORIGINAL_RMEM=""
UPGRADE_ORIGINAL_WMEM=""
LAST_HELPER_BACKUP=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
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

start_install_log() {
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  install -d -o root -g root -m 0700 "$LOG_DIR"
  INSTALL_LOG_FILE="${LOG_DIR}/install-${timestamp}-$$.log"
  install -o root -g root -m 0600 /dev/null "$INSTALL_LOG_FILE"
  # Keep the original output on a private descriptor so cleanup can close the
  # pipe and wait for tee. Bash does not otherwise guarantee that an
  # asynchronous process substitution has flushed before the shell exits.
  exec 6>&1
  exec > >(tee -a "$INSTALL_LOG_FILE" >&6) 2>&1
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
    wait "$INSTALL_TEE_PID" 2>/dev/null || true
  fi
  INSTALL_TEE_PID=""
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

cleanup() {
  if (( UPGRADE_ROLLBACK_ACTIVE == 1 )); then
    rollback_upgrade_transaction
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    if (( MUTATION_COMMIT_ACTIVE == 1 )); then
      printf '[FATAL] An unexpected exit occurred during a live state change. Preserving transaction backups for manual recovery: %s\n' \
        "$TMP_DIR" >&2
    else
      rm -rf -- "$TMP_DIR"
    fi
  fi
  if (( UPGRADE_ROLLBACK_FAILED == 0 )) && [[ -n "$UPGRADE_BACKUP_DIR" && -d "$UPGRADE_BACKUP_DIR" ]]; then
    rm -rf -- "$UPGRADE_BACKUP_DIR"
  elif (( UPGRADE_ROLLBACK_FAILED == 1 )) && [[ -n "$UPGRADE_BACKUP_DIR" ]]; then
    printf '[FATAL] Preserved incomplete overlay rollback state for manual recovery: %s\n' \
      "$UPGRADE_BACKUP_DIR" >&2
  fi
  finish_install_log
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
  sudo vpn status
  sudo vpn add NAME
  sudo vpn show NAME
  sudo vpn delete NAME
  sudo vpn list
  sudo vpn set-target DOMAIN
  sudo vpn set-fingerprint [VALUE]
  sudo vpn update
  sudo vpn self-update /path/to/new/install-sing-box-server.sh
  sudo vpn diagnostic
  sudo vpn confirm-firewall --yes
  sudo vpn rollback-firewall --yes
  sudo vpn lockdown-ssh --yes

Install options (missing values are requested interactively):
  --admin-user NAME        Administrative account to create.
  --public-key KEY         One quoted OpenSSH public-key line. Never a private key.
  --server-ipv4 ADDRESS    Public IPv4 address of the VPS.
  --domain DOMAIN          Domain whose A record points to the VPS.
  --email ADDRESS          ACME account email for the TLS certificate.
  --ssh-port PORT          Existing SSH port (default: 22).
  --reality-target DOMAIN  REALITY handshake target (required; no universal default).
  --fingerprint VALUE      Initial client TLS fingerprint (default: chrome).
  --emoji EMOJI            Server/country emoji used in generated profile names.
  --yes                    Confirm a mutating operation non-interactively.
  --automatic              Internal use by the firewall rollback timer.
  -h, --help               Show this help.

The default command is "plan". Both "plan" and "check" are read-only.
EOF
}

parse_args() {
  if (( $# > 0 )) && [[ "$1" != -* ]]; then
    case "$1" in
      add|show|delete)
        COMMAND="client-$1"
        (( $# >= 2 )) || die "$1 requires a client name."
        CLIENT_NAME="$2"
        shift 2
        ;;
      set-target)
        COMMAND="set-target"
        (( $# >= 2 )) || die 'set-target requires a domain.'
        NEW_REALITY_TARGET="$2"
        shift 2
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
      list)
        COMMAND="client-list"
        shift
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

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this command as root (sudo).'
}

require_confirmation() {
  local answer
  (( ASSUME_YES == 1 )) && return
  [[ -t 0 ]] || die 'Mutating non-interactive commands require --yes.'
  read -r -p 'Type YES to continue: ' answer
  [[ "$answer" == "YES" ]] || die 'Cancelled.'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

validate_domain() {
  local value="$1" label
  local -a labels=()
  (( ${#value} <= 253 )) || die "Domain is longer than 253 characters: $value"
  [[ "$value" == *.* && "$value" != *..* ]] || die "Domain must be fully qualified: $value"
  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || die "Invalid DNS label length in domain: $value"
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || die "Invalid domain: $value"
  done
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Provide a valid ACME email with --email.'
}

validate_ipv4() {
  local value="$1" octet
  local -a octets=()
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IPv4 address: $value"
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || die "Invalid IPv4 address: $value"
  done
}

validate_admin_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
    die 'Admin user must be a valid lower-case Debian account name (maximum 32 characters).'
  [[ "$1" != "root" ]] || die 'Choose an administrative user other than root.'
}

validate_ssh_port() {
  if [[ ! "$1" =~ ^[0-9]+$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
    die 'Invalid SSH port.'
  fi
  [[ "$1" != "80" && "$1" != "443" && "$1" != "$SUBSCRIPTION_PORT" ]] || \
    die "SSH port cannot be 80, 443, or ${SUBSCRIPTION_PORT} in this deployment."
}

validate_emoji() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && ${#1} -le 16 ]] || \
    die 'Provide a short emoji/flag without control characters.'
}

client_fingerprint_is_supported() {
  local value="$1" item
  for item in "${SUPPORTED_CLIENT_FINGERPRINTS[@]}"; do
    [[ "$value" == "$item" ]] && return 0
  done
  return 1
}

validate_client_fingerprint() {
  client_fingerprint_is_supported "$1" || die \
    "Unsupported client fingerprint: $1 (supported: chrome, firefox, safari, ios, android, edge, 360, qq, random)."
}

select_client_fingerprint() {
  local variable="$1" answer selected
  [[ -t 0 ]] || die 'A fingerprint value is required in non-interactive mode.'
  cat <<'EOF'
Select the client TLS fingerprint written to REALITY subscriptions:
  1) chrome   — broad compatibility; existing-installation default
  2) firefox  — useful alternative when chrome is filtered
  3) safari   — fixed Safari browser profile
  4) ios      — fixed iOS profile
  5) android  — fixed Android profile
  6) edge     — fixed Microsoft Edge profile
  7) 360      — fixed 360 Browser profile
  8) qq       — fixed QQ Browser profile
  9) random   — client chooses a modern browser profile at startup

There is no universally best value. Change it only when testing indicates that
the current profile is failing. "randomized" is deliberately excluded because
current Mihomo profiles do not support it consistently.
EOF
  read -r -p 'Fingerprint [1]: ' answer
  answer="${answer:-1}"
  case "$answer" in
    1|chrome) selected="chrome" ;;
    2|firefox) selected="firefox" ;;
    3|safari) selected="safari" ;;
    4|ios) selected="ios" ;;
    5|android) selected="android" ;;
    6|edge) selected="edge" ;;
    7|360) selected="360" ;;
    8|qq) selected="qq" ;;
    9|random) selected="random" ;;
    *) die 'Choose a number from 1 to 9 or enter one of the displayed names.' ;;
  esac
  printf -v "$variable" '%s' "$selected"
}

validate_public_key_text() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || die 'The public key must be exactly one line.'
  [[ "$1" == ssh-ed25519\ * || "$1" == sk-ssh-ed25519@openssh.com\ * ]] || \
    die 'Use an Ed25519 OpenSSH public key (ssh-ed25519 or hardware-backed sk-ssh-ed25519).'
}

prompt_value() {
  local variable="$1" prompt="$2" default_value="${3:-}" current answer
  current="${!variable:-}"
  [[ -n "$current" ]] && return
  [[ -t 0 ]] || die "Missing required option: ${prompt}"
  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt} [${default_value}]: " answer
    answer="${answer:-$default_value}"
  else
    read -r -p "${prompt}: " answer
  fi
  printf -v "$variable" '%s' "$answer"
}

collect_install_settings() {
  local detected_ip=""
  if command -v ip >/dev/null 2>&1; then
    detected_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  prompt_value ADMIN_USER 'Administrative user' 'vpnadmin'
  prompt_value ADMIN_PUBLIC_KEY 'OpenSSH public key (one line)'
  prompt_value SERVER_IPV4 'Public VPS IPv4' "$detected_ip"
  prompt_value TLS_DOMAIN 'TLS domain whose A record points to this VPS'
  prompt_value ACME_EMAIL 'ACME email'
  prompt_value SSH_PORT 'Current SSH port' '22'
  if [[ -z "$REALITY_TARGET" ]]; then
    printf '%s\n' \
      'No REALITY target is universally safe. Prefer a TLS 1.3 / HTTP/2 hostname' \
      'reachable from this VPS and, where practical, hosted by the same network/ASN.' \
      'The installer checks TLS properties, not resistance to a specific censor.'
  fi
  prompt_value REALITY_TARGET 'REALITY target (explicit choice required)'
  prompt_value COUNTRY_EMOJI 'Country/server emoji' '🌐'
  if [[ -z "$CLIENT_FINGERPRINT" ]]; then
    if [[ -t 0 ]]; then
      select_client_fingerprint CLIENT_FINGERPRINT
    else
      CLIENT_FINGERPRINT="$DEFAULT_CLIENT_FINGERPRINT"
    fi
  fi
  CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT,,}"

  validate_admin_user "$ADMIN_USER"
  validate_public_key_text "$ADMIN_PUBLIC_KEY"
  validate_ipv4 "$SERVER_IPV4"
  validate_domain "$TLS_DOMAIN"
  validate_email "$ACME_EMAIL"
  validate_ssh_port "$SSH_PORT"
  validate_domain "$REALITY_TARGET"
  validate_emoji "$COUNTRY_EMOJI"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
}

render_settings() {
  local candidate="$1"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
  jq -n \
    --arg admin_user "$ADMIN_USER" \
    --arg admin_public_key "$ADMIN_PUBLIC_KEY" \
    --arg server_ipv4 "$SERVER_IPV4" \
    --arg tls_domain "$TLS_DOMAIN" \
    --arg acme_email "$ACME_EMAIL" \
    --arg ssh_port "$SSH_PORT" \
    --arg reality_target "$REALITY_TARGET" \
    --arg country_emoji "$COUNTRY_EMOJI" \
    --arg client_fingerprint "$CLIENT_FINGERPRINT" \
    '{schema_version: 1, admin_user: $admin_user, admin_public_key: $admin_public_key,
      server_ipv4: $server_ipv4, tls_domain: $tls_domain, acme_email: $acme_email,
      ssh_port: $ssh_port, reality_target: $reality_target,
      country_emoji: $country_emoji, client_fingerprint: $client_fingerprint}' >"$candidate"
}

save_settings() {
  local candidate
  install -d -o root -g root -m 0700 "$STATE_DIR"
  candidate="$(mktemp)"
  render_settings "$candidate"
  write_atomic "$SETTINGS_FILE" root root 0600 "$candidate"
  rm -f -- "$candidate"
}

load_settings() {
  require_root
  [[ -r "$SETTINGS_FILE" ]] || die 'VPN settings are unavailable; install the server first.'
  jq -e '.schema_version == 1' "$SETTINGS_FILE" >/dev/null || die 'Unsupported settings schema.'
  ADMIN_USER="$(jq -r '.admin_user' "$SETTINGS_FILE")"
  ADMIN_PUBLIC_KEY="$(jq -r '.admin_public_key' "$SETTINGS_FILE")"
  SERVER_IPV4="$(jq -r '.server_ipv4' "$SETTINGS_FILE")"
  TLS_DOMAIN="$(jq -r '.tls_domain' "$SETTINGS_FILE")"
  ACME_EMAIL="$(jq -r '.acme_email' "$SETTINGS_FILE")"
  SSH_PORT="$(jq -r '.ssh_port' "$SETTINGS_FILE")"
  REALITY_TARGET="$(jq -r '.reality_target' "$SETTINGS_FILE")"
  COUNTRY_EMOJI="$(jq -r '.country_emoji' "$SETTINGS_FILE")"
  CLIENT_FINGERPRINT="$(jq -r --arg default "$DEFAULT_CLIENT_FINGERPRINT" \
    '.client_fingerprint // $default' "$SETTINGS_FILE")"

  validate_admin_user "$ADMIN_USER"
  validate_public_key_text "$ADMIN_PUBLIC_KEY"
  validate_ipv4 "$SERVER_IPV4"
  validate_domain "$TLS_DOMAIN"
  validate_email "$ACME_EMAIL"
  validate_ssh_port "$SSH_PORT"
  validate_domain "$REALITY_TARGET"
  validate_emoji "$COUNTRY_EMOJI"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
}

load_resume_settings() {
  local requested_admin="$ADMIN_USER"
  local requested_key="$ADMIN_PUBLIC_KEY"
  local requested_ip="$SERVER_IPV4"
  local requested_domain="$TLS_DOMAIN"
  local requested_email="$ACME_EMAIL"
  local requested_ssh_port="$SSH_PORT"
  local requested_target="$REALITY_TARGET"
  local requested_emoji="$COUNTRY_EMOJI"
  local requested_fingerprint="$CLIENT_FINGERPRINT"

  load_settings

  [[ -z "$requested_admin" || "$requested_admin" == "$ADMIN_USER" ]] || \
    die "--admin-user conflicts with the saved installation state (${ADMIN_USER})."
  [[ -z "$requested_key" || "$requested_key" == "$ADMIN_PUBLIC_KEY" ]] || \
    die '--public-key conflicts with the saved installation state.'
  [[ -z "$requested_ip" || "$requested_ip" == "$SERVER_IPV4" ]] || \
    die "--server-ipv4 conflicts with the saved installation state (${SERVER_IPV4})."
  [[ -z "$requested_domain" || "$requested_domain" == "$TLS_DOMAIN" ]] || \
    die "--domain conflicts with the saved installation state (${TLS_DOMAIN})."
  [[ -z "$requested_email" || "$requested_email" == "$ACME_EMAIL" ]] || \
    die "--email conflicts with the saved installation state (${ACME_EMAIL})."
  [[ -z "$requested_ssh_port" || "$requested_ssh_port" == "$SSH_PORT" ]] || \
    die "--ssh-port conflicts with the saved installation state (${SSH_PORT})."
  [[ -z "$requested_target" || "$requested_target" == "$REALITY_TARGET" ]] || \
    die "--reality-target conflicts with the saved installation state (${REALITY_TARGET})."
  [[ -z "$requested_emoji" || "$requested_emoji" == "$COUNTRY_EMOJI" ]] || \
    die "--emoji conflicts with the saved installation state (${COUNTRY_EMOJI})."
  [[ -z "$requested_fingerprint" || "$requested_fingerprint" == "$CLIENT_FINGERPRINT" ]] || \
    die "--fingerprint conflicts with the saved installation state (${CLIENT_FINGERPRINT})."
}

write_atomic() {
  local target="$1"
  local owner="$2"
  local group="$3"
  local mode="$4"
  local staged="$5"

  install -D -o "$owner" -g "$group" -m "$mode" "$staged" "${target}.new"
  mv -f -- "${target}.new" "$target"
}

script_version_from_file() {
  local file="$1"
  sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)"$/\1/p' "$file" | head -n1
}

project_name_from_file() {
  local file="$1"
  sed -n 's/^readonly PROJECT_NAME="\([^"]*\)"$/\1/p' "$file" | head -n1
}

installed_helper_version() {
  if [[ -r "$INSTALLED_HELPER" ]]; then
    script_version_from_file "$INSTALLED_HELPER"
  fi
}

installed_state_version() {
  if [[ -r "$INSTALL_COMPLETE_FILE" ]]; then
    sed -n 's/.*[[:space:]]version=\([^[:space:]]*\).*/\1/p' "$INSTALL_COMPLETE_FILE" | head -n1
  fi
}

validate_installer_file() {
  local file="$1" version project
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || die "Installer candidate is not a readable regular file: $file"
  bash -n "$file" || die 'Installer candidate failed bash syntax validation.'
  version="$(script_version_from_file "$file")"
  project="$(project_name_from_file "$file")"
  [[ -n "$version" ]] || die 'Installer candidate does not declare SCRIPT_VERSION.'
  [[ "$project" == "$PROJECT_NAME" ]] || die 'Installer candidate belongs to a different project.'
  dpkg --validate-version "$version" >/dev/null 2>&1 || die "Installer candidate has an invalid version: $version"
  printf '%s\n' "$version"
}

show_plan() {
  local plan_admin="${ADMIN_USER:-<interactive>}"
  local plan_ip="${SERVER_IPV4:-<interactive>}"
  local plan_domain="${TLS_DOMAIN:-<interactive>}"
  local plan_target="${REALITY_TARGET:-<explicit choice required>}"
  local plan_emoji="${COUNTRY_EMOJI:-<interactive>}"
  local plan_fingerprint="${CLIENT_FINGERPRINT:-$DEFAULT_CLIENT_FINGERPRINT}"
  local plan_ssh_port="${SSH_PORT:-22}"
  cat <<EOF
VPN installer ${SCRIPT_VERSION} — reviewed plan (no changes performed)

Target:
  OS/arch:              Debian 13, Ubuntu 24.04 LTS, or Ubuntu 26.04 LTS / amd64
  Minimum RAM:          1 GB VPS plan (at least 900 MiB visible)
  Minimum free disk:    2.5 GiB
  Init/runtime:         real systemd boot; containers without systemd and WSL unsupported
  Admin account:        ${plan_admin}
  SSH:                  TCP/${plan_ssh_port}, public key only after explicit lockdown
  Server IPv4:          ${plan_ip}
  Server core:          latest stable sing-box from its signed official APT repository
  Primary inbound:      VLESS + REALITY + Vision, TCP/443
  Reserve inbound:      Hysteria2 + TLS + Salamander, UDP/443
  TLS hostname:         ${plan_domain}
  REALITY target:       ${plan_target}
  Client fingerprint:   ${plan_fingerprint} (selectable; stored in subscriptions)
  Profile labels:       ${plan_emoji} Reality / ${plan_emoji} Hysteria2
  Firewall:             native nftables
  Swap:                 1 GiB only when no swap exists
  TCP optimization:     BBR + fq only when tcp_bbr is available
  UDP optimization:     raise QUIC socket-buffer ceilings to 7 MiB only when lower
  Subscription:         private HTTPS URL per client on TCP/${SUBSCRIPTION_PORT}
  Subscription formats: URI/Base64 fallback and Mihomo profile, selected per client
  Web panel:            none; nginx-light serves static read-only files only
  Client management:    sudo vpn add/show/delete/list
  REALITY target change: sudo vpn set-target DOMAIN (transactional)
  Fingerprint change:   sudo vpn set-fingerprint [VALUE] (transactional)
  Core update:          sudo vpn update (validated with package rollback)
  Installer update:     local verified file; atomic replacement with previous-version backup
  Diagnostics:          sudo vpn diagnostic (health summary plus redacted details)
  Compatibility check: sudo vpn check (read-only)
  Install error log:    detailed root-only file under ${LOG_DIR}
  Initial client:       ${INITIAL_CLIENT_NAME}

Package commands:
  apt-get update
  apt-get install ca-certificates curl jq openssl nftables sudo certbot dnsutils qrencode nginx-light unattended-upgrades
  configure the official signed SagerNet APT repository
  apt-get download and install the latest stable sing-box package
  apt-mark hold sing-box (updates only through "sudo vpn update")

Account and SSH commands:
  useradd/usermod/chpasswd/install/visudo
  sshd -t
  systemctl reload ssh (only in the later lockdown-ssh command)

Certificate commands:
  dig A ${plan_domain} using 1.1.1.1 and 8.8.8.8
  certbot certonly --standalone --preferred-challenges http
  install certificate copies readable only by root:sing-box

Network and service commands:
  nft -c -f, nft -f
  modprobe tcp_bbr, sysctl -p <project file>
  systemctl restart systemd-journald
  systemctl daemon-reload/enable/start/reload
  sing-box check

Files changed by install:
  ${CONFIG_FILE}
  ${SYSTEMD_DROPIN}
  ${JOURNAL_DROPIN}
  ${NFT_CONFIG}
  ${NGINX_SITE}
  ${NGINX_SITE_ENABLED}
  ${SUBSCRIPTION_ROOT} (static tokenized client profiles)
  /etc/letsencrypt/* for ${plan_domain}
  /etc/apt/apt.conf.d/52-vpn-unattended-upgrades
  ${SAGERNET_KEY_FILE}
  ${SAGERNET_SOURCE_FILE}
  /etc/modules-load.d/90-vpn-bbr.conf (only if supported)
  /etc/sysctl.d/90-vpn-network.conf (only if BBR is supported)
  ${UDP_SYSCTL_FILE} (7 MiB floor; higher existing ceilings are retained)
  /etc/fstab and /swapfile (only if swap is absent)
  /home/${plan_admin}/.ssh/authorized_keys
  /etc/sudoers.d/90-${plan_admin}
  ${INSTALLED_HELPER}
  ${SETTINGS_FILE}
  ${CLIENTS_FILE} (root-only client database)

Files changed only by lockdown-ssh:
  ${SSH_DROPIN}

Secret handling:
  Each client receives an independent VLESS UUID, Hysteria2 password, and
  256-bit subscription bearer token. Shared REALITY and Hysteria2 obfuscation
  secrets are generated locally on the VPS. Private material is shown only by
  an explicit "sudo vpn show NAME" command. nginx cannot list directories or
  write subscription files, and access logging is disabled.

Safety gates:
  * install refuses unreviewed OS releases, non-amd64 hosts, non-systemd boots,
    insufficient memory/disk, implausible system time, and read-only paths;
  * DNS must resolve the requested TLS domain to the requested VPS IPv4;
  * occupied TCP/443, UDP/443, or TCP/${SUBSCRIPTION_PORT} aborts installation
    unless owned by the expected managed service;
  * an unknown non-empty nftables ruleset aborts installation;
  * configs are validated before replacement;
  * interrupted installs save their validated settings and can be resumed by
    running the same install command again;
  * existing accounts, packages, certificates, secrets, and client databases
    are verified and reused instead of being recreated;
  * each installation attempt writes a detailed root-only log with the failed
    step, exit code, command, source location, and shell call stack;
  * firewall automatically rolls back after five minutes unless confirmed from
    a second SSH session;
  * root/password SSH is not disabled by install; lockdown-ssh must be run from
    a verified administrative sudo session.
EOF
}

preflight_os() {
  [[ -r /etc/os-release ]] || die '/etc/os-release is missing.'
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
  case "${OS_ID}:${OS_VERSION}" in
    debian:13|ubuntu:24.04|ubuntu:26.04)
      ;;
    *)
      die "Unsupported operating system: ${OS_PRETTY_NAME}. Supported: Debian 13, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS."
      ;;
  esac
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die 'This installer supports only the amd64 package architecture.'
  [[ "$(uname -m)" == "x86_64" ]] || die 'Unexpected kernel architecture; expected x86_64.'
  log "Operating system compatibility: ${OS_PRETTY_NAME} / amd64."
}

preflight_hardware_and_runtime() {
  local mem_kib min_mem_kib min_mem_label cpu_count virtualization pid_one
  local epoch ntp_state

  [[ -r /proc/1/comm ]] || die 'Unable to inspect the init process through /proc/1/comm.'
  pid_one="$(</proc/1/comm)"
  pid_one="${pid_one//[[:space:]]/}"
  [[ "$pid_one" == "systemd" && -d /run/systemd/system ]] || \
    die 'A real systemd boot is required; containers without systemd and WSL are unsupported.'

  mem_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine installed memory.'
  # Providers commonly market a VM as 1 GB while the guest sees slightly less
  # after firmware and hypervisor reservations. Keep the public requirement at
  # 1 GB without rejecting a normal 1 GB plan for a small reporting difference.
  min_mem_kib=921600
  min_mem_label='900 MiB visible (a 1 GB VPS plan)'
  (( mem_kib >= min_mem_kib )) || \
    die "Insufficient RAM for ${OS_PRETTY_NAME}: found $((mem_kib / 1024)) MiB, require at least ${min_mem_label}."

  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    die 'No online CPU was detected.'
  fi
  [[ -r /proc/sys/kernel/random/uuid ]] || die 'Kernel UUID entropy source is unavailable.'
  [[ -w /etc && -w /var && -w /tmp ]] || die 'The installer requires writable /etc, /var, and /tmp filesystems.'

  epoch="$(date +%s 2>/dev/null || true)"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]] || (( epoch < 1704067200 || epoch > 4102444800 )); then
    die 'System clock is implausible; correct date/time before TLS and ACME operations.'
  fi
  ntp_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ "$ntp_state" == "yes" ]] || warn 'System clock is not currently reported as NTP-synchronized.'

  virtualization="$(systemd-detect-virt 2>/dev/null || true)"
  virtualization="${virtualization:-none}"
  log "Runtime compatibility: CPU=${cpu_count}, RAM=$((mem_kib / 1024)) MiB, kernel=$(uname -r), virtualization=${virtualization}, systemd=yes."
}

preflight_public_ip() {
  if ip -4 address show | grep -Fq "${SERVER_IPV4}/"; then
    log "Configured public IPv4 ${SERVER_IPV4} is present on a local interface."
  else
    warn "IPv4 ${SERVER_IPV4} is not present on a local interface; continuing for a possible provider-managed 1:1 NAT setup. DNS and ACME validation must still reach this VPS."
  fi
}

port_is_listening() {
  local protocol="$1"
  local port="$2"
  if [[ "$protocol" == "tcp" ]]; then
    ss -H -lntp | awk -v port="$port" '$4 ~ (":" port "$") { print }'
  else
    ss -H -lnup | awk -v port="$port" '$4 ~ (":" port "$") { print }'
  fi
}

preflight_ports() {
  local listeners
  listeners="$(port_is_listening tcp 443 || true)"
  if [[ -n "$listeners" && "$listeners" != *sing-box* ]]; then
    printf '%s\n' "$listeners" >&2
    die 'TCP/443 is already occupied by another process.'
  fi

  listeners="$(port_is_listening udp 443 || true)"
  if [[ -n "$listeners" && "$listeners" != *sing-box* ]]; then
    printf '%s\n' "$listeners" >&2
    die 'UDP/443 is already occupied by another process.'
  fi

  listeners="$(port_is_listening tcp "$SUBSCRIPTION_PORT" || true)"
  if [[ -n "$listeners" && ( "$listeners" != *nginx* || ! -f "$NGINX_SITE" ) ]]; then
    printf '%s\n' "$listeners" >&2
    die "TCP/${SUBSCRIPTION_PORT} is occupied by an unmanaged process."
  fi
}

preflight_disk() {
  local available_kib total_kib
  available_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  total_kib="$(df -Pk / | awk 'NR==2 {print $2}')"
  [[ "$available_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine free disk space.'
  [[ "$total_kib" =~ ^[0-9]+$ ]] || die 'Unable to determine root filesystem size.'
  (( available_kib >= 2500000 )) || die 'At least 2.5 GiB of free disk space is required.'
  log "Storage compatibility: root filesystem total=$((total_kib / 1024)) MiB, free=$((available_kib / 1024)) MiB."
}

compatibility_check() {
  require_root
  CURRENT_STEP='read-only compatibility check'
  require_command dpkg
  require_command ss
  require_command systemctl
  require_command systemd-detect-virt
  require_command timedatectl

  preflight_os
  preflight_hardware_and_runtime
  preflight_disk
  preflight_ports

  printf '\nCompatibility check: PASS\n'
  printf 'Supported host: %s / amd64\n' "$OS_PRETTY_NAME"
  printf 'TCP/443 and UDP/443: available or already owned by sing-box\n'
  printf 'TCP/%s: available or already owned by nginx\n' "$SUBSCRIPTION_PORT"
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
     grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    printf 'BBR: available\n'
  else
    printf 'BBR: not currently available (optional; installation can use the kernel default)\n'
  fi
  printf 'No packages, services, accounts, firewall rules, or configuration files were changed.\n'
}

preflight_key() {
  local key_file
  key_file="$(mktemp)"
  printf '%s\n' "$ADMIN_PUBLIC_KEY" >"$key_file"
  ssh-keygen -l -f "$key_file" >/dev/null || die 'The supplied admin public key is invalid.'
  rm -f -- "$key_file"
}

install_base_packages() {
  log 'Refreshing Debian package metadata.'
  apt-get update
  log 'Installing the reviewed dependency set.'
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl jq openssl nftables sudo certbot dnsutils qrencode \
    nginx-light unattended-upgrades openssh-client openssh-server iproute2 procps kmod util-linux
  # Debian/Ubuntu may start the packaged default HTTP site immediately. Keep
  # nginx stopped until the certificate and restricted subscription site exist.
  systemctl disable --now nginx.service >/dev/null 2>&1 || true
}

configure_sing_box_repository() {
  local key_candidate source_candidate
  install -d -o root -g root -m 0755 /etc/apt/keyrings
  key_candidate="$(mktemp)"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 3 --connect-timeout 20 --output "$key_candidate" "$SAGERNET_KEY_URL"
  grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$key_candidate" || die 'The SagerNet repository key is malformed.'
  write_atomic "$SAGERNET_KEY_FILE" root root 0644 "$key_candidate"
  rm -f -- "$key_candidate"

  source_candidate="$(mktemp)"
  cat >"$source_candidate" <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: ${SAGERNET_KEY_FILE}
EOF
  write_atomic "$SAGERNET_SOURCE_FILE" root root 0644 "$source_candidate"
  rm -f -- "$source_candidate"
}

sing_box_candidate_version() {
  apt-cache policy sing-box | awk '/Candidate:/ {print $2; exit}'
}

download_sing_box_package() {
  local version="$1" destination="$2" package
  install -d -o root -g root -m 0700 "$destination"
  (
    cd "$destination"
    apt-get download "sing-box=${version}" >/dev/null
  )
  package="$(find "$destination" -maxdepth 1 -type f -name 'sing-box_*.deb' -print -quit)"
  [[ -n "$package" ]] || die "Could not download sing-box ${version}."
  [[ "$(dpkg-deb -f "$package" Package)" == "sing-box" ]] || die 'Downloaded package name is not sing-box.'
  [[ "$(dpkg-deb -f "$package" Version)" == "$version" ]] || die 'Downloaded sing-box version does not match APT metadata.'
  printf '%s\n' "$package"
}

archive_sing_box_package() {
  local package="$1" version architecture destination
  version="$(dpkg-deb -f "$package" Version)"
  architecture="$(dpkg-deb -f "$package" Architecture)"
  install -d -o root -g root -m 0700 "$PACKAGE_CACHE_DIR"
  destination="${PACKAGE_CACHE_DIR}/sing-box_${version}_${architecture}.deb"
  install -o root -g root -m 0600 "$package" "${destination}.new"
  mv -f -- "${destination}.new" "$destination"
  printf '%s\n' "$destination"
}

find_cached_sing_box_package() {
  local version="$1" package
  while IFS= read -r -d '' package; do
    if [[ "$(dpkg-deb -f "$package" Version 2>/dev/null || true)" == "$version" ]]; then
      printf '%s\n' "$package"
      return 0
    fi
  done < <(find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name 'sing-box_*.deb' -print0 2>/dev/null)
  return 1
}

prune_sing_box_packages() {
  local -a packages=()
  local index package
  while IFS= read -r package; do
    packages+=("$package")
  done < <(find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name 'sing-box_*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  for (( index=2; index<${#packages[@]}; index++ )); do
    rm -f -- "${packages[$index]}"
  done
}

install_sing_box() {
  local candidate package_path installed_version
  configure_sing_box_repository
  apt-get update
  candidate="$(sing_box_candidate_version)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die 'No stable sing-box candidate is available from the official repository.'

  installed_version="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  if [[ "$installed_version" == "$candidate" ]]; then
    if ! find_cached_sing_box_package "$installed_version" >/dev/null; then
      TMP_DIR="$(mktemp -d)"
      package_path="$(download_sing_box_package "$candidate" "$TMP_DIR")"
      archive_sing_box_package "$package_path" >/dev/null
    fi
    apt-mark hold sing-box >/dev/null
    log "Verified existing stable sing-box ${installed_version}; reusing it."
    return
  fi

  TMP_DIR="$(mktemp -d)"
  package_path="$(download_sing_box_package "$candidate" "$TMP_DIR")"
  package_path="$(archive_sing_box_package "$package_path")"

  apt-mark unhold sing-box >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages "$package_path"
  installed_version="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  [[ "$installed_version" == "$candidate" ]] || die "Unexpected installed sing-box version: ${installed_version:-missing}"
  apt-mark hold sing-box >/dev/null
  log "Installed and held stable sing-box ${installed_version}; use 'sudo vpn update' for reviewed updates."
}

create_admin_account() {
  local user_home user_shell primary_group sudoers_stage account_password
  local authorized_keys created_account=0

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    log "Creating administrative user ${ADMIN_USER}."
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
    created_account=1
  else
    log "Administrative user ${ADMIN_USER} already exists; validating and reusing it."
  fi

  user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  user_shell="$(getent passwd "$ADMIN_USER" | cut -d: -f7)"
  [[ -n "$user_home" && -d "$user_home" ]] || die "Home directory for ${ADMIN_USER} is unavailable."
  [[ "$user_shell" != */nologin && "$user_shell" != */false ]] || \
    die "Existing account ${ADMIN_USER} has a non-login shell (${user_shell})."
  primary_group="$(id -gn "$ADMIN_USER")"
  [[ -n "$primary_group" ]] || die "Primary group for ${ADMIN_USER} is unavailable."

  if ! id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -Fxq sudo; then
    usermod --append --groups sudo "$ADMIN_USER"
  fi

  install -d -o "$ADMIN_USER" -g "$primary_group" -m 0700 "${user_home}/.ssh"
  authorized_keys="${user_home}/.ssh/authorized_keys"
  [[ ! -e "$authorized_keys" || -f "$authorized_keys" ]] || \
    die "${authorized_keys} exists but is not a regular file."
  if [[ -f "$authorized_keys" ]]; then
    install -o "$ADMIN_USER" -g "$primary_group" -m 0600 \
      "$authorized_keys" "${authorized_keys}.new"
  else
    install -o "$ADMIN_USER" -g "$primary_group" -m 0600 /dev/null "${authorized_keys}.new"
  fi
  if ! grep -Fxq -- "$ADMIN_PUBLIC_KEY" "${authorized_keys}.new"; then
    printf '%s\n' "$ADMIN_PUBLIC_KEY" >>"${authorized_keys}.new"
  fi
  mv -f -- "${authorized_keys}.new" "$authorized_keys"

  sudoers_stage="$(mktemp)"
  printf '%s\n' "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" >"$sudoers_stage"
  chmod 0440 "$sudoers_stage"
  visudo -cf "$sudoers_stage" >/dev/null
  if [[ -e "/etc/sudoers.d/90-${ADMIN_USER}" ]]; then
    visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}" >/dev/null || \
      die "Existing sudoers file for ${ADMIN_USER} is invalid."
    cmp -s "$sudoers_stage" "/etc/sudoers.d/90-${ADMIN_USER}" || \
      die "Existing sudoers file /etc/sudoers.d/90-${ADMIN_USER} conflicts with this installer."
  else
    install -o root -g root -m 0440 "$sudoers_stage" "/etc/sudoers.d/90-${ADMIN_USER}"
  fi
  rm -f -- "$sudoers_stage"

  if (( created_account == 1 )); then
    # Keep the PAM account usable for public-key SSH while making its password
    # unknown and computationally infeasible to guess. The value is never logged
    # or stored outside /etc/shadow and global SSH password auth is disabled later.
    account_password="$(openssl rand -base64 48)"
    printf '%s:%s\n' "$ADMIN_USER" "$account_password" | chpasswd
    unset account_password
    log "Installed public-key account ${ADMIN_USER}; no usable password was disclosed."
  else
    log "Verified administrative account ${ADMIN_USER}; its existing password state was not changed."
  fi
}

configure_swap() {
  local swap_type created_swap=0 staged_swap="/swapfile.new"
  if [[ -n "$(swapon --noheadings --show=NAME 2>/dev/null)" ]]; then
    log 'Swap already exists; leaving it unchanged.'
    return
  fi

  if [[ ! -e /swapfile ]]; then
    log 'Creating a 1 GiB swap file.'
    rm -f -- "$staged_swap"
    if ! fallocate -l 1G "$staged_swap"; then
      rm -f -- "$staged_swap"
      dd if=/dev/zero of="$staged_swap" bs=1M count=1024 status=progress
    fi
    chmod 0600 "$staged_swap"
    if ! mkswap "$staged_swap" >/dev/null; then
      rm -f -- "$staged_swap"
      die 'Could not format the staged swap file.'
    fi
    mv -f -- "$staged_swap" /swapfile
    created_swap=1
  else
    [[ -f /swapfile ]] || die '/swapfile exists but is not a regular file.'
    swap_type="$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)"
    [[ "$swap_type" == "swap" ]] || die '/swapfile already exists and is not a recognized swap file.'
  fi
  chmod 0600 /swapfile
  if ! swapon /swapfile; then
    if (( created_swap == 1 )); then
      rm -f -- /swapfile
    fi
    die 'Could not activate /swapfile; the filesystem or VPS kernel may not support swap files.'
  fi
  grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || \
    printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
}

configure_bbr_if_available() {
  local available
  if ! modprobe tcp_bbr 2>/dev/null; then
    warn 'tcp_bbr module is unavailable; retaining CUBIC + fq_codel.'
    return
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    warn 'Kernel did not expose BBR after module load; retaining existing congestion control.'
    return
  fi

  log 'Enabling BBR and making fq the default qdisc for new/recreated interfaces.'
  printf '%s\n' 'tcp_bbr' >/etc/modules-load.d/90-vpn-bbr.conf
  cat >/etc/sysctl.d/90-vpn-network.conf <<'EOF'
# VPN setup: only the reviewed TCP settings. No buffer or MTU tuning.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/90-vpn-network.conf >/dev/null
}

configure_udp_buffer_ceilings() {
  local current_rmem current_wmem desired_rmem desired_wmem candidate
  current_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || true)"
  current_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || true)"
  [[ "$current_rmem" =~ ^[0-9]+$ && "$current_wmem" =~ ^[0-9]+$ ]] || \
    die 'Unable to read the current UDP socket-buffer ceilings.'

  desired_rmem="$current_rmem"
  desired_wmem="$current_wmem"
  (( desired_rmem >= UDP_BUFFER_MAX )) || desired_rmem="$UDP_BUFFER_MAX"
  (( desired_wmem >= UDP_BUFFER_MAX )) || desired_wmem="$UDP_BUFFER_MAX"

  candidate="$(mktemp)"
  cat >"$candidate" <<EOF
# VPN setup: conservative QUIC/Hysteria2 socket-buffer ceilings.
# These are maximums, not preallocated memory; higher existing values are preserved.
net.core.rmem_max = ${desired_rmem}
net.core.wmem_max = ${desired_wmem}
EOF
  write_atomic "$UDP_SYSCTL_FILE" root root 0644 "$candidate"
  sysctl -p "$UDP_SYSCTL_FILE" >/dev/null
  if (( current_rmem < UDP_BUFFER_MAX || current_wmem < UDP_BUFFER_MAX )); then
    log "Raised lower UDP socket-buffer ceilings to ${UDP_BUFFER_MAX} bytes without reducing higher values."
  else
    log "Existing UDP socket-buffer ceilings already meet or exceed ${UDP_BUFFER_MAX} bytes; persisted them unchanged."
  fi
  rm -f -- "$candidate"
}

configure_journal_limits() {
  local candidate
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=30day
EOF
  install -d -o root -g root -m 0755 "$JOURNAL_DROPIN_DIR"
  write_atomic "$JOURNAL_DROPIN" root root 0644 "$candidate"
  rm -f -- "$candidate"
  systemctl restart systemd-journald.service
  systemctl is-active --quiet systemd-journald.service || die 'systemd-journald did not become active after applying limits.'
  log 'Limited persistent journal storage to 200 MiB with a 30-day retention ceiling.'
}

configure_unattended_upgrades() {
  cat >/etc/apt/apt.conf.d/52-vpn-unattended-upgrades <<'EOF'
// VPN setup: security updates without automatic reboot.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
}

verify_dns() {
  local resolver answer caa_status caa_output
  for resolver in 1.1.1.1 8.8.8.8; do
    answer="$(dig +short A "$TLS_DOMAIN" "@${resolver}" | sed '/^$/d')"
    if ! grep -Fxq "$SERVER_IPV4" <<<"$answer"; then
      printf 'Resolver %s returned:\n%s\n' "$resolver" "${answer:-<no A record>}" >&2
      die "${TLS_DOMAIN} must resolve directly to ${SERVER_IPV4} before installation; disable DNS-provider/CDN proxying for this record."
    fi

    caa_output="$(dig CAA "$TLS_DOMAIN" "@${resolver}" +noall +comments 2>&1 || true)"
    caa_status="$(sed -n 's/.*status: \([A-Z]*\),.*/\1/p' <<<"$caa_output" | head -n1)"
    if [[ "$caa_status" != "NOERROR" ]]; then
      printf 'Resolver %s returned CAA status %s:\n%s\n' \
        "$resolver" "${caa_status:-unknown}" "$caa_output" >&2
      die "CAA lookup for ${TLS_DOMAIN} is unhealthy; fix DNS before requesting a certificate."
    fi
  done
  log "DNS A and CAA responses for ${TLS_DOMAIN} are healthy on both public resolvers."
}

verify_reality_target() {
  local tls_probe
  log "Checking TLS 1.3 reachability of the reviewed REALITY target ${REALITY_TARGET}."
  if ! tls_probe="$(timeout 15 openssl s_client \
    -connect "${REALITY_TARGET}:443" \
    -servername "$REALITY_TARGET" \
    -tls1_3 -alpn h2 -verify_return_error </dev/null 2>&1)"; then
    die "REALITY target ${REALITY_TARGET} did not pass the TLS 1.3 verification test."
  fi
  if ! grep -Eiq 'ALPN protocol:[[:space:]]*h2|ALPN[^[:alnum:]]+h2' <<<"$tls_probe"; then
    die "REALITY target ${REALITY_TARGET} did not negotiate HTTP/2 (ALPN h2)."
  fi
  log "REALITY target ${REALITY_TARGET} passed the basic certificate, TLS 1.3, and ALPN h2 checks."
}

deploy_certificate() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]] || die 'Certificate files are unavailable.'
  install -d -o root -g sing-box -m 0750 "$CERT_DIR"
  install -o root -g sing-box -m 0640 "${live_dir}/fullchain.pem" "${CERT_DIR}/fullchain.pem.new"
  install -o root -g sing-box -m 0640 "${live_dir}/privkey.pem" "${CERT_DIR}/privkey.pem.new"
  mv -f -- "${CERT_DIR}/fullchain.pem.new" "${CERT_DIR}/fullchain.pem"
  mv -f -- "${CERT_DIR}/privkey.pem.new" "${CERT_DIR}/privkey.pem"
}

certificate_key_pair_matches() {
  local certificate="$1" private_key="$2" work
  [[ -r "$certificate" && -r "$private_key" ]] || return 1
  work="$(mktemp -d)"
  if ! openssl x509 -in "$certificate" -pubkey -noout >"${work}/certificate.pub" 2>/dev/null ||
     ! openssl pkey -pubin -in "${work}/certificate.pub" -outform DER >"${work}/certificate.der" 2>/dev/null ||
     ! openssl pkey -in "$private_key" -pubout -outform DER >"${work}/private-key.der" 2>/dev/null ||
     ! cmp -s "${work}/certificate.der" "${work}/private-key.der"; then
    rm -rf -- "$work"
    return 1
  fi
  rm -rf -- "$work"
}

render_certificate_hook() {
  local candidate="$1"
  cat >"$candidate" <<EOF
#!/bin/sh
set -eu
umask 077

live_dir='/etc/letsencrypt/live/${TLS_DOMAIN}'
cert_dir='${CERT_DIR}'
config_file='${CONFIG_FILE}'
service='sing-box.service'
nginx_service='nginx.service'
lock_file='${STATE_DIR}/certificate-deploy.lock'

if [ -n "\${RENEWED_LINEAGE:-}" ] && [ "\$RENEWED_LINEAGE" != "\$live_dir" ]; then
  exit 0
fi

exec 9>"\$lock_file"
flock -x 9
install -d -o root -g sing-box -m 0750 "\$cert_dir"
work_dir="\$(mktemp -d "\${cert_dir}/.renew.XXXXXX")"
had_previous=0
commit_active=0

cleanup() {
  status=\$?
  trap - EXIT HUP INT TERM
  if [ "\$commit_active" -eq 1 ]; then
    set +e
    restore_previous
    restore_status=\$?
    set -e
    [ "\$restore_status" -eq 0 ] || status=1
  fi
  rm -f -- "\${cert_dir}/fullchain.pem.new" "\${cert_dir}/privkey.pem.new" \
    "\${cert_dir}/fullchain.pem.restore" "\${cert_dir}/privkey.pem.restore"
  rm -rf -- "\$work_dir"
  exit "\$status"
}

restore_previous() {
  restore_failed=0
  if [ "\$had_previous" -eq 1 ]; then
    install -o root -g sing-box -m 0640 "\${work_dir}/previous-fullchain.pem" "\${cert_dir}/fullchain.pem.restore" || restore_failed=1
    install -o root -g sing-box -m 0640 "\${work_dir}/previous-privkey.pem" "\${cert_dir}/privkey.pem.restore" || restore_failed=1
    mv -f -- "\${cert_dir}/fullchain.pem.restore" "\${cert_dir}/fullchain.pem" || restore_failed=1
    mv -f -- "\${cert_dir}/privkey.pem.restore" "\${cert_dir}/privkey.pem" || restore_failed=1
    systemctl restart "\$service" >/dev/null 2>&1 || restore_failed=1
    systemctl reload-or-restart "\$nginx_service" >/dev/null 2>&1 || restore_failed=1
    systemctl is-active --quiet "\$nginx_service" || restore_failed=1
  else
    rm -f -- "\${cert_dir}/fullchain.pem" "\${cert_dir}/privkey.pem" || restore_failed=1
  fi
  return "\$restore_failed"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

install -o root -g root -m 0600 "\${live_dir}/fullchain.pem" "\${work_dir}/new-fullchain.pem"
install -o root -g root -m 0600 "\${live_dir}/privkey.pem" "\${work_dir}/new-privkey.pem"
openssl x509 -in "\${work_dir}/new-fullchain.pem" -noout -checkend 0
openssl x509 -in "\${work_dir}/new-fullchain.pem" -pubkey -noout >"\${work_dir}/certificate.pub"
openssl pkey -pubin -in "\${work_dir}/certificate.pub" -outform DER >"\${work_dir}/certificate.der"
openssl pkey -in "\${work_dir}/new-privkey.pem" -pubout -outform DER >"\${work_dir}/private-key.der"
cmp -s "\${work_dir}/certificate.der" "\${work_dir}/private-key.der"
nginx -t >/dev/null 2>&1

if [ -e "\${cert_dir}/fullchain.pem" ] || [ -e "\${cert_dir}/privkey.pem" ]; then
  [ -r "\${cert_dir}/fullchain.pem" ] && [ -r "\${cert_dir}/privkey.pem" ]
  install -o root -g root -m 0600 "\${cert_dir}/fullchain.pem" "\${work_dir}/previous-fullchain.pem"
  install -o root -g root -m 0600 "\${cert_dir}/privkey.pem" "\${work_dir}/previous-privkey.pem"
  had_previous=1
fi

install -o root -g sing-box -m 0640 "\${work_dir}/new-fullchain.pem" "\${cert_dir}/fullchain.pem.new"
install -o root -g sing-box -m 0640 "\${work_dir}/new-privkey.pem" "\${cert_dir}/privkey.pem.new"
commit_active=1
mv -f -- "\${cert_dir}/fullchain.pem.new" "\${cert_dir}/fullchain.pem"
mv -f -- "\${cert_dir}/privkey.pem.new" "\${cert_dir}/privkey.pem"

if ! sing-box check -c "\$config_file" >/dev/null 2>&1; then
  exit 1
fi
if ! systemctl reload-or-restart "\$service" || ! systemctl is-active --quiet "\$service"; then
  exit 1
fi
if ! systemctl reload "\$nginx_service" || ! systemctl is-active --quiet "\$nginx_service"; then
  exit 1
fi
commit_active=0
EOF
  sh -n "$candidate" || die 'Generated certificate deploy hook failed shell syntax validation.'
}

configure_certificate_hook() {
  local candidate
  install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  candidate="$(mktemp)"
  render_certificate_hook "$candidate"
  write_atomic "$CERT_HOOK" root root 0750 "$candidate"
  rm -f -- "$candidate"
}

verify_certificate_automation() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]] || die 'Live ACME certificate material is unavailable.'
  [[ -r "${CERT_DIR}/fullchain.pem" && -r "${CERT_DIR}/privkey.pem" ]] || die 'Deployed sing-box certificate material is unavailable.'
  [[ -f "$CERT_HOOK" && -x "$CERT_HOOK" ]] || die 'Certificate deploy hook is missing or not executable.'
  sh -n "$CERT_HOOK" || die 'Certificate deploy hook failed shell syntax validation.'
  systemctl is-enabled --quiet certbot.timer || die 'certbot.timer is not enabled.'
  systemctl is-active --quiet certbot.timer || die 'certbot.timer is not active.'
  nginx -t >/dev/null 2>&1 || die 'nginx rejects the subscription configuration.'
  systemctl is-active --quiet nginx.service || die 'nginx subscription service is inactive.'
  certificate_key_pair_matches "${live_dir}/fullchain.pem" "${live_dir}/privkey.pem" || die 'Live ACME certificate and private key do not match.'
  certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" || die 'Deployed certificate and private key do not match.'
  cmp -s "${live_dir}/fullchain.pem" "${CERT_DIR}/fullchain.pem" || die 'Deployed certificate differs from the current ACME certificate.'
  cmp -s "${live_dir}/privkey.pem" "${CERT_DIR}/privkey.pem" || die 'Deployed private key differs from the current ACME private key.'
}

smoke_test_certificate_hook() {
  "$CERT_HOOK"
  verify_certificate_automation
  systemctl is-active --quiet sing-box.service || die 'sing-box is inactive after the certificate deploy-hook smoke test.'
  systemctl is-active --quiet nginx.service || die 'nginx is inactive after the certificate deploy-hook smoke test.'
  log 'Certificate renewal hook, key pair, deployed copy, timer, sing-box, and nginx reload paths passed verification.'
}

obtain_certificate() {
  local live_dir="/etc/letsencrypt/live/${TLS_DOMAIN}"
  if [[ -r "${live_dir}/fullchain.pem" && -r "${live_dir}/privkey.pem" ]]; then
    log 'Existing ACME certificate found; reusing it.'
  else
    if [[ -n "$(port_is_listening tcp 80 || true)" ]]; then
      die 'TCP/80 is occupied; certbot standalone cannot complete HTTP-01.'
    fi
    log "Requesting a Let's Encrypt certificate for ${TLS_DOMAIN}."
    certbot certonly --standalone --non-interactive --agree-tos \
      --preferred-challenges http --email "$ACME_EMAIL" --domain "$TLS_DOMAIN"
  fi
  deploy_certificate
  configure_certificate_hook
  systemctl enable --now certbot.timer >/dev/null
}

validate_client_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z][A-Za-z0-9._-]{0,31}$ ]] || \
    die 'Client name must start with a letter and contain only A-Z, a-z, 0-9, dot, underscore, or hyphen (maximum 32 characters).'
}

validate_client_database() {
  local database="$1"
  jq -e '
    (.schema_version == 2) and
    (.clients | type == "array" and length > 0) and
    (all(.clients[];
      (.name | type == "string" and test("^[A-Za-z][A-Za-z0-9._-]{0,31}$")) and
      (.vless_uuid | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      (.hy2_password | type == "string" and test("^[0-9a-f]{48}$")) and
      (.subscription_token | type == "string" and test("^[0-9a-f]{64}$")) and
      (.created_at | type == "string" and length > 0)
    )) and
    (([.clients[].name | ascii_downcase] | length) ==
     ([.clients[].name | ascii_downcase] | unique | length)) and
    (([.clients[].subscription_token] | length) ==
     ([.clients[].subscription_token] | unique | length))
  ' "$database" >/dev/null || die 'Client database validation failed.'
}

generate_or_load_server_secrets() {
  local keypair
  install -d -o root -g root -m 0700 "$STATE_DIR" "$ROLLBACK_DIR"

  if [[ ! -f "$SECRETS_FILE" ]]; then
    log 'Generating shared server credentials locally (values will not be printed).'
    keypair="$(sing-box generate reality-keypair)"
    REALITY_PRIVATE_KEY="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$keypair")"
    REALITY_PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$keypair")"
    REALITY_SHORT_ID="$(openssl rand -hex 4)"
    HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"

    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die 'Credential generation failed.'
    [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{8}$ ]] || die 'Invalid generated REALITY short ID.'

    {
      printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
      printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
      printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
      printf 'HY2_OBFS_PASSWORD=%q\n' "$HY2_OBFS_PASSWORD"
    } >"${SECRETS_FILE}.new"
    chmod 0600 "${SECRETS_FILE}.new"
    mv -f -- "${SECRETS_FILE}.new" "$SECRETS_FILE"
  fi

  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  : "${REALITY_PRIVATE_KEY:?missing REALITY private key}"
  : "${REALITY_PUBLIC_KEY:?missing REALITY public key}"
  : "${REALITY_SHORT_ID:?missing REALITY short ID}"
  : "${HY2_OBFS_PASSWORD:?missing Hysteria2 obfuscation password}"
}

initialize_client_database() {
  local initial_name initial_uuid initial_hy2 initial_token candidate
  generate_or_load_server_secrets
  if [[ -f "$CLIENTS_FILE" ]]; then
    validate_client_database "$CLIENTS_FILE"
    return
  fi

  initial_name="$INITIAL_CLIENT_NAME"
  initial_uuid="$(cat /proc/sys/kernel/random/uuid)"
  initial_hy2="$(openssl rand -hex 24)"
  initial_token="$(openssl rand -hex 32)"

  validate_client_name "$initial_name"

  candidate="$(mktemp)"
  jq -n \
    --arg name "$initial_name" \
    --arg uuid "$initial_uuid" \
    --arg hy2 "$initial_hy2" \
    --arg token "$initial_token" \
    --arg created "$(date --iso-8601=seconds)" \
    '{
      schema_version: 2,
      clients: [{
        name: $name,
        vless_uuid: $uuid,
        hy2_password: $hy2,
        subscription_token: $token,
        created_at: $created
      }]
    }' >"$candidate"
  validate_client_database "$candidate"
  write_atomic "$CLIENTS_FILE" root root 0600 "$candidate"
  rm -f -- "$candidate"
  log "Created initial independent VPN client: ${initial_name}."
}

build_sing_box_config() {
  local database="$1"
  local output="$2"
  local vless_users_json hy2_users_json
  generate_or_load_server_secrets
  validate_client_database "$database"

  vless_users_json="$(jq '[.clients[] | {
    name: .name,
    uuid: .vless_uuid,
    flow: "xtls-rprx-vision"
  }]' "$database")"
  hy2_users_json="$(jq '[.clients[] | {
    name: .name,
    password: .hy2_password
  }]' "$database")"

  cat >"$output" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local",
        "prefer_go": true
      }
    ],
    "final": "local",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": ${vless_users_json},
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_TARGET}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_TARGET}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ],
          "max_time_difference": "1m"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "users": ${hy2_users_json},
      "tls": {
        "enabled": true,
        "server_name": "${TLS_DOMAIN}",
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "certificate_path": "${CERT_DIR}/fullchain.pem",
        "key_path": "${CERT_DIR}/privkey.pem"
      },
      "masquerade": {
        "type": "string",
        "status_code": 404,
        "headers": {
          "server": "nginx",
          "content-type": "text/html; charset=utf-8"
        },
        "content": "<!doctype html><html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": {
      "server": "local",
      "strategy": "ipv4_only"
    },
    "final": "direct"
  }
}
EOF
  sing-box check -c "$output"
}

write_sing_box_config() {
  local candidate
  initialize_client_database
  install -d -o root -g sing-box -m 0750 "$CONFIG_DIR"
  candidate="$(mktemp)"
  build_sing_box_config "$CLIENTS_FILE" "$candidate"
  if [[ -f "$CONFIG_FILE" && ! -f "${ROLLBACK_DIR}/config.before.json" ]]; then
    install -o root -g root -m 0600 "$CONFIG_FILE" "${ROLLBACK_DIR}/config.before.json"
  fi
  write_atomic "$CONFIG_FILE" root sing-box 0640 "$candidate"
  rm -f -- "$candidate"
}

write_systemd_hardening() {
  local candidate
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
[Service]
# Reset the broad upstream server/client capability set. This deployment only
# listens on privileged ports and does not provide TUN, packet capture, or API.
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectProc=invisible
ProcSubset=pid
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ReadWritePaths=/var/lib/sing-box
EOF
  write_atomic "$SYSTEMD_DROPIN" root root 0644 "$candidate"
  rm -f -- "$candidate"
}

require_client_runtime() {
  require_root
  require_command base64
  require_command curl
  require_command flock
  require_command jq
  require_command nginx
  require_command openssl
  require_command sing-box
  require_command systemctl
  [[ -f "$CLIENTS_FILE" ]] || die 'Client database is unavailable; install the server first.'
  [[ -f "$SECRETS_FILE" ]] || die 'Server secrets are unavailable; install the server first.'
  [[ -f "$CONFIG_FILE" ]] || die 'sing-box configuration is unavailable; install the server first.'
  validate_client_database "$CLIENTS_FILE"
}

find_client_json() {
  local name="$1"
  jq -c --arg name "$name" \
    '.clients[] | select((.name | ascii_downcase) == ($name | ascii_downcase))' \
    "$CLIENTS_FILE"
}

restore_client_transaction() {
  local database_backup="$1"
  local config_backup="$2"
  warn 'Client change failed; restoring the previous database and sing-box configuration.'
  install -o root -g root -m 0600 "$database_backup" "${CLIENTS_FILE}.rollback"
  mv -f -- "${CLIENTS_FILE}.rollback" "$CLIENTS_FILE"
  install -o root -g sing-box -m 0640 "$config_backup" "${CONFIG_FILE}.rollback"
  mv -f -- "${CONFIG_FILE}.rollback" "$CONFIG_FILE"
  publish_subscription_tree "$CLIENTS_FILE"
  sing-box check -c "$CONFIG_FILE" || die 'Rollback configuration validation failed.'
  systemctl restart sing-box.service || die 'Rollback restored the files, but sing-box could not be restarted.'
  systemctl is-active --quiet sing-box.service || die 'Rollback restored the files, but sing-box is not active.'
}

apply_client_database() {
  local candidate_database="$1"
  local candidate_config candidate_subscriptions database_backup config_backup
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] || die 'Internal client transaction directory is unavailable.'
  candidate_config="${TMP_DIR}/config.candidate.json"
  database_backup="${TMP_DIR}/clients.before.json"
  config_backup="${TMP_DIR}/config.before.json"
  candidate_subscriptions="${TMP_DIR}/subscriptions.candidate"

  validate_client_database "$candidate_database"
  build_sing_box_config "$candidate_database" "$candidate_config"
  render_subscription_tree "$candidate_database" "$candidate_subscriptions"
  install -o root -g root -m 0600 "$CLIENTS_FILE" "$database_backup"
  install -o root -g root -m 0600 "$CONFIG_FILE" "$config_backup"

  install -o root -g root -m 0600 "$candidate_database" "${CLIENTS_FILE}.new"
  install -o root -g sing-box -m 0640 "$candidate_config" "${CONFIG_FILE}.new"

  begin_mutation_commit
  if ! mv -f -- "${CLIENTS_FILE}.new" "$CLIENTS_FILE"; then
    rm -f -- "${CONFIG_FILE}.new"
    finish_mutation_commit
    die 'Could not activate the new client database; no live configuration was changed.'
  fi
  if ! mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE"; then
    restore_client_transaction "$database_backup" "$config_backup"
    finish_mutation_commit
    die 'Could not activate the new sing-box configuration; the previous state was restored.'
  fi

  if ! activate_subscription_tree "$candidate_subscriptions"; then
    restore_client_transaction "$database_backup" "$config_backup"
    finish_mutation_commit
    die 'Could not publish the client subscriptions; the previous state was restored.'
  fi

  if ! systemctl restart sing-box.service || ! systemctl is-active --quiet sing-box.service; then
    restore_client_transaction "$database_backup" "$config_backup"
    finish_mutation_commit
    die 'sing-box rejected the client change at runtime; the previous state was restored.'
  fi
  if ! sing-box check -c "$CONFIG_FILE"; then
    restore_client_transaction "$database_backup" "$config_backup"
    finish_mutation_commit
    die 'The active client configuration failed its final validation; the previous state was restored.'
  fi
  if ! subscription_service_healthy; then
    restore_client_transaction "$database_backup" "$config_backup"
    finish_mutation_commit
    die 'The subscription self-test failed after the client change; the previous state was restored.'
  fi
  finish_mutation_commit
}

client_add() {
  local candidate uuid hy2 token client
  require_client_runtime
  acquire_operation_lock
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9

  if [[ -n "$(find_client_json "$CLIENT_NAME")" ]]; then
    die "Client ${CLIENT_NAME} already exists (names are case-insensitive)."
  fi

  TMP_DIR="$(mktemp -d)"
  candidate="${TMP_DIR}/clients.candidate.json"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  hy2="$(openssl rand -hex 24)"
  token="$(openssl rand -hex 32)"
  jq \
    --arg name "$CLIENT_NAME" \
    --arg uuid "$uuid" \
    --arg hy2 "$hy2" \
    --arg token "$token" \
    --arg created "$(date --iso-8601=seconds)" \
    '.clients += [{
      name: $name,
      vless_uuid: $uuid,
      hy2_password: $hy2,
      subscription_token: $token,
      created_at: $created
    }]' "$CLIENTS_FILE" >"$candidate"
  apply_client_database "$candidate"
  log "Client ${CLIENT_NAME} added with independent VLESS and Hysteria2 credentials."
  client="$(find_client_json "$CLIENT_NAME")"
  show_client_material "$client"
}

build_client_uris() {
  local client="$1" uuid hy2 reality_label hy2_label
  generate_or_load_server_secrets
  EXPORTED_CLIENT_NAME="$(jq -r '.name' <<<"$client")"
  uuid="$(jq -r '.vless_uuid' <<<"$client")"
  hy2="$(jq -r '.hy2_password' <<<"$client")"
  reality_label="$(jq -rn --arg value "${COUNTRY_EMOJI} Reality" '$value | @uri')"
  hy2_label="$(jq -rn --arg value "${COUNTRY_EMOJI} Hysteria2" '$value | @uri')"
  VLESS_URI="vless://${uuid}@${SERVER_IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET}&fp=${CLIENT_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${reality_label}"
  HY2_URI="hysteria2://${hy2}@${TLS_DOMAIN}:443/?sni=${TLS_DOMAIN}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#${hy2_label}"
}

render_client_subscription_files() {
  local client="$1" output_dir="$2" token reality_name hy2_name links_file mihomo_file
  build_client_uris "$client"
  token="$(jq -r '.subscription_token' <<<"$client")"
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid subscription token in client database.'
  reality_name="${COUNTRY_EMOJI} Reality"
  hy2_name="${COUNTRY_EMOJI} Hysteria2"
  links_file="${output_dir}/${token}.links"
  mihomo_file="${output_dir}/${token}.mihomo"

  printf '%s\n%s\n' "$VLESS_URI" "$HY2_URI" | base64 | tr -d '\n' >"$links_file"
  printf '\n' >>"$links_file"

  # JSON is a valid YAML 1.2 document and avoids unsafe ad-hoc YAML quoting.
  # FlClash and other Mihomo frontends parse this as a complete Mihomo profile.
  jq -n \
    --arg reality_name "$reality_name" \
    --arg hy2_name "$hy2_name" \
    --arg server_ipv4 "$SERVER_IPV4" \
    --arg uuid "$(jq -r '.vless_uuid' <<<"$client")" \
    --arg target "$REALITY_TARGET" \
    --arg fingerprint "$CLIENT_FINGERPRINT" \
    --arg public_key "$REALITY_PUBLIC_KEY" \
    --arg short_id "$REALITY_SHORT_ID" \
    --arg tls_domain "$TLS_DOMAIN" \
    --arg hy2_password "$(jq -r '.hy2_password' <<<"$client")" \
    --arg hy2_obfs_password "$HY2_OBFS_PASSWORD" \
    '{
      "mixed-port": 7890,
      "allow-lan": false,
      mode: "rule",
      "log-level": "warning",
      ipv6: false,
      proxies: [
        {
          name: $reality_name,
          type: "vless",
          server: $server_ipv4,
          port: 443,
          uuid: $uuid,
          network: "tcp",
          tls: true,
          udp: true,
          flow: "xtls-rprx-vision",
          servername: $target,
          "client-fingerprint": $fingerprint,
          "reality-opts": {
            "public-key": $public_key,
            "short-id": $short_id
          }
        },
        {
          name: $hy2_name,
          type: "hysteria2",
          server: $tls_domain,
          port: 443,
          password: $hy2_password,
          sni: $tls_domain,
          "skip-cert-verify": false,
          obfs: "salamander",
          "obfs-password": $hy2_obfs_password
        }
      ],
      "proxy-groups": [
        {
          name: "PROXY",
          type: "select",
          proxies: [$reality_name, $hy2_name]
        }
      ],
      rules: [
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR6,::1/128,DIRECT,no-resolve",
        "MATCH,PROXY"
      ]
    }' >"$mihomo_file"
  jq -e '.proxies | length == 2' "$mihomo_file" >/dev/null || die 'Generated Mihomo profile validation failed.'
}

render_subscription_tree() {
  local database="$1" output_dir="$2" client
  validate_client_database "$database"
  generate_or_load_server_secrets
  install -d -o root -g root -m 0700 "$output_dir"
  while IFS= read -r client; do
    render_client_subscription_files "$client" "$output_dir"
  done < <(jq -c '.clients[]' "$database")
}

activate_subscription_tree() {
  local staged="$1" new_root="${SUBSCRIPTION_ROOT}.new.$$" old_root="${SUBSCRIPTION_ROOT}.old.$$" file
  [[ -d "$staged" ]] || return 1
  getent passwd www-data >/dev/null 2>&1 || return 1
  install -d -o root -g root -m 0755 "$(dirname "$SUBSCRIPTION_ROOT")"
  rm -rf -- "$new_root" "$old_root"
  install -d -o root -g www-data -m 0750 "$new_root"
  while IFS= read -r -d '' file; do
    install -o root -g www-data -m 0640 "$file" "${new_root}/$(basename "$file")"
  done < <(find "$staged" -maxdepth 1 -type f -print0)

  if [[ -d "$SUBSCRIPTION_ROOT" ]]; then
    mv -- "$SUBSCRIPTION_ROOT" "$old_root" || return 1
  fi
  if ! mv -- "$new_root" "$SUBSCRIPTION_ROOT"; then
    [[ ! -d "$old_root" ]] || mv -- "$old_root" "$SUBSCRIPTION_ROOT"
    return 1
  fi
  rm -rf -- "$old_root"
}

publish_subscription_tree() {
  local database="$1" work
  work="$(mktemp -d)"
  render_subscription_tree "$database" "$work"
  if ! activate_subscription_tree "$work"; then
    rm -rf -- "$work"
    die 'Could not atomically publish subscription files.'
  fi
  rm -rf -- "$work"
}

render_nginx_subscription_site() {
  local candidate="$1"
  cat >"$candidate" <<EOF
map \$http_user_agent \$vpn_subscription_format {
    default links;
    ~*(clash|mihomo|flclash|clash-verge|clashverge|stash) mihomo;
}

server {
    listen ${SUBSCRIPTION_PORT} ssl;
    server_name ${TLS_DOMAIN};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:VPNSubscriptions:1m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    root ${SUBSCRIPTION_ROOT};
    default_type text/plain;
    charset off;
    access_log off;
    # Avoid request-path logging: the path itself contains a bearer token.
    error_log /var/log/nginx/error.log crit;

    add_header Cache-Control "no-store" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Vary "User-Agent" always;
    add_header profile-update-interval "24" always;

    location ~ "^/s/(?<vpn_token>[0-9a-f]{64})$" {
        limit_except GET HEAD { deny all; }
        try_files /\$vpn_token.\$vpn_subscription_format =404;
    }

    location ~ "^/s/(?<vpn_token>[0-9a-f]{64})/(?<vpn_requested_format>links|mihomo)$" {
        limit_except GET HEAD { deny all; }
        try_files /\$vpn_token.\$vpn_requested_format =404;
    }

    location ~ "^/[0-9a-f]{64}\.(links|mihomo)$" {
        internal;
    }

    location / { return 404; }
}
EOF
}

configure_subscription_service() {
  local candidate
  require_command nginx
  candidate="$(mktemp)"
  render_nginx_subscription_site "$candidate"
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  write_atomic "$NGINX_SITE" root root 0644 "$candidate"
  rm -f -- "$candidate"
  rm -f -- /etc/nginx/sites-enabled/default "$NGINX_SITE_ENABLED"
  ln -s "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  nginx -t
}

start_subscription_service() {
  systemctl enable nginx.service >/dev/null
  if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
  else
    systemctl start nginx.service
  fi
  systemctl is-active --quiet nginx.service || die 'nginx subscription service did not become active.'
}

subscription_service_healthy() {
  local token url links_payload decoded_links mihomo_payload
  token="$(jq -r '.clients[0].subscription_token' "$CLIENTS_FILE")"
  url="https://${TLS_DOMAIN}:${SUBSCRIPTION_PORT}/s/${token}"
  nginx -t >/dev/null 2>&1 || return 1
  systemctl is-active --quiet nginx.service || return 1
  # Pass the bearer-token URL through curl's stdin config so it never appears
  # in the process argument list visible to other local users.
  links_payload="$(printf 'url = "%s"\n' "$url" | curl --noproxy '*' \
    --fail --silent --show-error --connect-timeout 10 \
    --resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:${SERVER_IPV4}" \
    --user-agent 'Shadowrocket' --config -)" || return 1
  decoded_links="$(printf '%s' "$links_payload" | base64 --decode 2>/dev/null)" || return 1
  grep -Fq 'vless://' <<<"$decoded_links" || return 1
  grep -Fq 'hysteria2://' <<<"$decoded_links" || return 1
  grep -Fq "&fp=${CLIENT_FINGERPRINT}&" <<<"$decoded_links" || return 1
  mihomo_payload="$(printf 'url = "%s"\n' "$url" | curl --noproxy '*' \
    --fail --silent --show-error --connect-timeout 10 \
    --resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:${SERVER_IPV4}" \
    --user-agent 'FlClash' --config -)" || return 1
  jq -e --arg fingerprint "$CLIENT_FINGERPRINT" \
    '(.proxies | length == 2) and
     (any(.proxies[]; .type == "vless" and .["client-fingerprint"] == $fingerprint))' \
    <<<"$mihomo_payload" >/dev/null || \
    return 1
}

verify_subscription_service() {
  subscription_service_healthy || die 'Subscription service self-test failed.'
}

show_client_material() {
  local client="$1" token subscription_url
  require_command qrencode
  build_client_uris "$client"
  token="$(jq -r '.subscription_token' <<<"$client")"
  subscription_url="https://${TLS_DOMAIN}:${SUBSCRIPTION_PORT}/s/${token}"

  cat <<EOF
VPN CLIENT MATERIAL — KEEP PRIVATE
Client: ${EXPORTED_CLIENT_NAME}

Universal subscription (recommended):
${subscription_url}

Scan this QR code as a subscription, not as a single server:
EOF
  printf '%s' "$subscription_url" | qrencode -t ANSIUTF8
  cat <<EOF

Direct fallback links:
${VLESS_URI}
${HY2_URI}

If a Mihomo client is not detected automatically, use:
${subscription_url}/mihomo

The subscription URL and direct links contain private client credentials.
Do not publish them in Git, screenshots, logs, or chats.
EOF
}

client_show() {
  local client
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  exec 9>"$CLIENT_LOCK_FILE"
  flock -s 9
  client="$(find_client_json "$CLIENT_NAME")"
  [[ -n "$client" ]] || die "Client ${CLIENT_NAME} does not exist."
  show_client_material "$client"
}

client_delete() {
  local candidate stored_name count
  require_client_runtime
  acquire_operation_lock
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  stored_name="$(find_client_json "$CLIENT_NAME" | jq -r '.name')"
  [[ -n "$stored_name" ]] || die "Client ${CLIENT_NAME} does not exist."
  count="$(jq '.clients | length' "$CLIENTS_FILE")"
  (( count > 1 )) || die 'Refusing to delete the last VPN client. Add a replacement client first.'

  TMP_DIR="$(mktemp -d)"
  candidate="${TMP_DIR}/clients.candidate.json"
  jq --arg name "$stored_name" \
    '.clients |= map(select((.name | ascii_downcase) != ($name | ascii_downcase)))' \
    "$CLIENTS_FILE" >"$candidate"
  apply_client_database "$candidate"
  log "Client ${stored_name} deleted; its VLESS UUID and Hysteria2 password are no longer accepted."
}

client_list() {
  require_client_runtime
  exec 9>"$CLIENT_LOCK_FILE"
  flock -s 9
  printf 'CLIENT\tCREATED\n'
  jq -r '.clients | sort_by(.name | ascii_downcase)[] | [.name, .created_at] | @tsv' "$CLIENTS_FILE"
}

restore_target_transaction() {
  local settings_backup="$1" config_backup="$2" subscriptions_backup="$3" old_target="$4"
  warn 'REALITY target change failed; restoring the previous settings, configuration, and subscriptions.'
  REALITY_TARGET="$old_target"
  install -o root -g root -m 0600 "$settings_backup" "${SETTINGS_FILE}.rollback"
  install -o root -g sing-box -m 0640 "$config_backup" "${CONFIG_FILE}.rollback"
  mv -f -- "${SETTINGS_FILE}.rollback" "$SETTINGS_FILE"
  mv -f -- "${CONFIG_FILE}.rollback" "$CONFIG_FILE"
  activate_subscription_tree "$subscriptions_backup" || die 'Subscription rollback failed.'
  sing-box check -c "$CONFIG_FILE" || die 'Restored sing-box configuration validation failed.'
  systemctl restart sing-box.service || die 'Restored sing-box service could not be restarted.'
  systemctl is-active --quiet sing-box.service || die 'Restored sing-box service is inactive.'
}

set_reality_target() {
  local old_target candidate_settings candidate_config candidate_subscriptions old_subscriptions
  local settings_backup config_backup failed=0
  require_client_runtime
  validate_domain "$NEW_REALITY_TARGET"
  old_target="$REALITY_TARGET"
  if [[ "$NEW_REALITY_TARGET" == "$old_target" ]]; then
    printf 'REALITY target is already %s; nothing changed.\n' "$old_target"
    return
  fi

  printf 'REALITY target change: %s -> %s\n' "$old_target" "$NEW_REALITY_TARGET"
  printf 'All client subscriptions will be regenerated; their URLs will stay unchanged.\n'
  require_confirmation

  acquire_operation_lock
  load_settings
  require_client_runtime
  old_target="$REALITY_TARGET"
  if [[ "$NEW_REALITY_TARGET" == "$old_target" ]]; then
    printf 'REALITY target became %s while waiting; nothing changed.\n' "$old_target"
    return
  fi
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  TMP_DIR="$(mktemp -d)"
  candidate_settings="${TMP_DIR}/settings.candidate.json"
  candidate_config="${TMP_DIR}/config.candidate.json"
  candidate_subscriptions="${TMP_DIR}/subscriptions.candidate"
  old_subscriptions="${TMP_DIR}/subscriptions.before"
  settings_backup="${TMP_DIR}/settings.before.json"
  config_backup="${TMP_DIR}/config.before.json"

  render_subscription_tree "$CLIENTS_FILE" "$old_subscriptions"
  install -o root -g root -m 0600 "$SETTINGS_FILE" "$settings_backup"
  install -o root -g root -m 0600 "$CONFIG_FILE" "$config_backup"

  REALITY_TARGET="$NEW_REALITY_TARGET"
  verify_reality_target
  render_settings "$candidate_settings"
  build_sing_box_config "$CLIENTS_FILE" "$candidate_config"
  render_subscription_tree "$CLIENTS_FILE" "$candidate_subscriptions"

  install -o root -g root -m 0600 "$candidate_settings" "${SETTINGS_FILE}.new"
  install -o root -g sing-box -m 0640 "$candidate_config" "${CONFIG_FILE}.new"
  begin_mutation_commit
  mv -f -- "${SETTINGS_FILE}.new" "$SETTINGS_FILE" || failed=1
  if (( failed == 0 )); then
    mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE" || failed=1
  fi
  if (( failed == 0 )); then
    activate_subscription_tree "$candidate_subscriptions" || failed=1
  fi
  if (( failed == 0 )); then
    systemctl restart sing-box.service || failed=1
    systemctl is-active --quiet sing-box.service || failed=1
  fi
  if (( failed == 0 )); then
    subscription_service_healthy || failed=1
  fi
  if (( failed == 0 )); then
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
  fi

  if (( failed == 1 )); then
    restore_target_transaction "$settings_backup" "$config_backup" "$old_subscriptions" "$old_target"
    finish_mutation_commit
    die 'REALITY target was not changed; the previous state was restored.'
  fi

  finish_mutation_commit
  log "REALITY target changed transactionally: ${old_target} -> ${REALITY_TARGET}."
  printf 'Subscription URLs are unchanged. Refresh the subscription on each device.\n'
}

restore_fingerprint_transaction() {
  local settings_backup="$1" subscriptions_backup="$2" old_fingerprint="$3"
  warn 'Client fingerprint change failed; restoring the previous settings and subscriptions.'
  CLIENT_FINGERPRINT="$old_fingerprint"
  install -o root -g root -m 0600 "$settings_backup" "${SETTINGS_FILE}.rollback"
  mv -f -- "${SETTINGS_FILE}.rollback" "$SETTINGS_FILE"
  activate_subscription_tree "$subscriptions_backup" || die 'Subscription rollback failed.'
  subscription_service_healthy || die 'Restored subscriptions failed their health check.'
}

set_client_fingerprint() {
  local old_fingerprint candidate_settings candidate_subscriptions old_subscriptions
  local settings_backup failed=0
  require_client_runtime

  if [[ -z "$NEW_CLIENT_FINGERPRINT" ]]; then
    select_client_fingerprint NEW_CLIENT_FINGERPRINT
  fi
  NEW_CLIENT_FINGERPRINT="${NEW_CLIENT_FINGERPRINT,,}"
  validate_client_fingerprint "$NEW_CLIENT_FINGERPRINT"
  old_fingerprint="$CLIENT_FINGERPRINT"
  if [[ "$NEW_CLIENT_FINGERPRINT" == "$old_fingerprint" ]]; then
    printf 'Client fingerprint is already %s; nothing changed.\n' "$old_fingerprint"
    return
  fi

  printf 'Client fingerprint change: %s -> %s\n' "$old_fingerprint" "$NEW_CLIENT_FINGERPRINT"
  printf 'All client subscriptions will be regenerated; their URLs will stay unchanged.\n'
  printf 'Connected clients keep their current profile until their subscription is refreshed.\n'
  require_confirmation

  acquire_operation_lock
  load_settings
  require_client_runtime
  old_fingerprint="$CLIENT_FINGERPRINT"
  if [[ "$NEW_CLIENT_FINGERPRINT" == "$old_fingerprint" ]]; then
    printf 'Client fingerprint became %s while waiting; nothing changed.\n' "$old_fingerprint"
    return
  fi
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  TMP_DIR="$(mktemp -d)"
  candidate_settings="${TMP_DIR}/settings.candidate.json"
  candidate_subscriptions="${TMP_DIR}/subscriptions.candidate"
  old_subscriptions="${TMP_DIR}/subscriptions.before"
  settings_backup="${TMP_DIR}/settings.before.json"

  render_subscription_tree "$CLIENTS_FILE" "$old_subscriptions"
  install -o root -g root -m 0600 "$SETTINGS_FILE" "$settings_backup"

  CLIENT_FINGERPRINT="$NEW_CLIENT_FINGERPRINT"
  render_settings "$candidate_settings"
  render_subscription_tree "$CLIENTS_FILE" "$candidate_subscriptions"

  install -o root -g root -m 0600 "$candidate_settings" "${SETTINGS_FILE}.new"
  begin_mutation_commit
  mv -f -- "${SETTINGS_FILE}.new" "$SETTINGS_FILE" || failed=1
  if (( failed == 0 )); then
    activate_subscription_tree "$candidate_subscriptions" || failed=1
  fi
  if (( failed == 0 )); then
    systemctl is-active --quiet sing-box.service || failed=1
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
    subscription_service_healthy || failed=1
  fi

  if (( failed == 1 )); then
    restore_fingerprint_transaction "$settings_backup" "$old_subscriptions" "$old_fingerprint"
    finish_mutation_commit
    die 'Client fingerprint was not changed; the previous state was restored.'
  fi

  finish_mutation_commit
  log "Client fingerprint changed transactionally: ${old_fingerprint} -> ${CLIENT_FINGERPRINT}."
  printf 'Subscription URLs are unchanged. Refresh the subscription on each device.\n'
  printf 'If REALITY still fails, run "sudo vpn diagnostic" before changing other settings.\n'
}

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

  if [[ -n "$backup" ]]; then
    find "$INSTALLER_BACKUP_DIR" -maxdepth 1 -type f -name 'vpn-*' -printf '%T@ %p\n' \
      | sort -rn | cut -d' ' -f2- | sed -n '4,$p' | while IFS= read -r obsolete; do
          rm -f -- "$obsolete"
        done
  fi
  LAST_HELPER_BACKUP="$backup"
}

restore_installed_helper() {
  local backup="$1"
  [[ -n "$backup" && -r "$backup" ]] || return 1
  install -o root -g root -m 0750 "$backup" "${INSTALLED_HELPER}.restore"
  bash -n "${INSTALLED_HELPER}.restore" || return 1
  mv -f -- "${INSTALLED_HELPER}.restore" "$INSTALLED_HELPER"
}

self_update_from_file() {
  local source_path candidate candidate_version current_version
  require_root
  require_command dpkg
  source_path="$(readlink -f "$SELF_UPDATE_SOURCE" 2>/dev/null || true)"
  [[ -n "$source_path" ]] || die 'Unable to resolve the installer candidate path.'

  TMP_DIR="$(mktemp -d)"
  candidate="${TMP_DIR}/installer-candidate"
  install -o root -g root -m 0700 "$source_path" "$candidate"
  candidate_version="$(validate_installer_file "$candidate")"
  current_version="$(installed_helper_version)"
  [[ -n "$current_version" ]] || die 'The installed management helper version cannot be determined.'
  dpkg --compare-versions "$candidate_version" gt "$current_version" || \
    die "Self-update requires a newer version (installed ${current_version}, candidate ${candidate_version})."

  printf 'Installer self-update: %s -> %s\n' "$current_version" "$candidate_version"
  printf 'Candidate was copied to a root-only temporary file and passed syntax/project/version validation.\n'
  require_confirmation
  bash "$candidate" upgrade --yes
  [[ "$(installed_helper_version)" == "$candidate_version" ]] || die 'Self-update command completed without activating the candidate version.'
  log "Installer self-update completed successfully: ${current_version} -> ${candidate_version}."
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

save_firewall_baseline() {
  install -d -o root -g root -m 0700 "$ROLLBACK_DIR"
  if [[ ! -f "${ROLLBACK_DIR}/nftables.rules.before" ]]; then
    nft list ruleset >"${ROLLBACK_DIR}/nftables.rules.before"
    chmod 0600 "${ROLLBACK_DIR}/nftables.rules.before"
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
  fi
}

unknown_firewall_present() {
  local current
  current="$(nft list ruleset 2>/dev/null || true)"
  [[ -n "${current//[[:space:]]/}" && ! -f "${STATE_DIR}/firewall.managed" ]]
}

write_firewall_candidate() {
  local candidate="$1"
  cat >"$candidate" <<EOF
#!/usr/sbin/nft -f
# Managed by VPN setup. Review before editing.
flush ruleset

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

cancel_pending_firewall_rollback_strict() {
  local unit_base
  unit_base="$(cat "$FIREWALL_UNIT_STATE" 2>/dev/null || true)"
  [[ -n "$unit_base" ]] || return 1

  systemctl stop "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || return 1
  if systemctl is-active --quiet "${unit_base}.timer" ||
     systemctl is-active --quiet "${unit_base}.service"; then
    return 1
  fi
  systemctl reset-failed "${unit_base}.timer" "${unit_base}.service" >/dev/null 2>&1 || true
  rm -f -- "$FIREWALL_UNIT_STATE"
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
  if unknown_firewall_present; then
    nft list ruleset >&2 || true
    die 'An unmanaged non-empty nftables ruleset exists; refusing to replace it.'
  fi

  save_firewall_baseline
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
  local rules_backup="${ROLLBACK_DIR}/nftables.rules.before"
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

  [[ -f "$rules_backup" ]] || die 'No firewall rollback state exists.'
  if (( AUTOMATIC == 0 )); then
    stop_pending_firewall_rollback
  fi
  log 'Restoring the previous firewall state.'
  nft flush ruleset
  if [[ -s "$rules_backup" ]]; then
    nft --file "$rules_backup"
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
  nft --check --file "$NFT_CONFIG"
  [[ -n "$(port_is_listening tcp "$SSH_PORT" || true)" ]] || die 'SSH is not listening; refusing confirmation.'
  systemctl enable nftables.service >/dev/null
  cancel_pending_firewall_rollback_strict || \
    die 'Could not prove that the automatic rollback timer was cancelled; firewall confirmation was not recorded.'
  printf '%s\n' "confirmed $(date --iso-8601=seconds)" >"$confirmed_candidate"
  chmod 0600 "$confirmed_candidate"
  mv -f -- "$confirmed_candidate" "${STATE_DIR}/firewall.confirmed"
  log 'Firewall persistence confirmed; automatic rollback cancelled.'
}

lockdown_ssh() {
  local candidate invoking_user effective
  require_root
  require_confirmation
  invoking_user="${SUDO_USER:-}"
  [[ "$invoking_user" == "$ADMIN_USER" ]] || die "Run this command from a verified ${ADMIN_USER} session using sudo."
  [[ -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] || die 'Admin authorized_keys is missing.'
  ssh-keygen -l -f "/home/${ADMIN_USER}/.ssh/authorized_keys" >/dev/null

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
  systemctl reload ssh.service
  log 'SSH lockdown applied: key-only, no root login, no password login.'
}

update_sing_box() {
  local installed candidate old_package new_package candidate_root failed=0
  require_client_runtime
  require_confirmation
  require_command apt-cache
  require_command apt-get
  require_command dpkg-deb

  acquire_operation_lock
  load_settings
  require_client_runtime
  installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  [[ -n "$installed" ]] || die 'sing-box is not installed.'
  old_package="$(find_cached_sing_box_package "$installed" || true)"
  [[ -n "$old_package" ]] || die 'The current sing-box rollback package is missing; refusing an unsafe update.'

  configure_sing_box_repository
  apt-get update
  candidate="$(sing_box_candidate_version)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die 'No stable sing-box update candidate is available.'
  if [[ "$candidate" == "$installed" ]]; then
    log "sing-box ${installed} is already the latest stable release."
    return
  fi
  dpkg --compare-versions "$candidate" gt "$installed" || die "Refusing non-upgrade candidate ${candidate} over ${installed}."

  TMP_DIR="$(mktemp -d)"
  new_package="$(download_sing_box_package "$candidate" "${TMP_DIR}/download")"
  candidate_root="${TMP_DIR}/candidate-root"
  mkdir -p "$candidate_root"
  dpkg-deb -x "$new_package" "$candidate_root"
  [[ -x "${candidate_root}/usr/bin/sing-box" ]] || die 'Candidate package does not contain the sing-box binary.'
  "${candidate_root}/usr/bin/sing-box" check -c "$CONFIG_FILE"
  new_package="$(archive_sing_box_package "$new_package")"

  log "Installing validated sing-box ${candidate} (rollback: ${installed})."
  dpkg --force-confold -i "$new_package" >/dev/null 2>&1 || failed=1
  if (( failed == 0 )); then
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
    systemctl restart sing-box.service >/dev/null 2>&1 || failed=1
    systemctl is-active --quiet sing-box.service || failed=1
  fi

  if (( failed == 1 )); then
    warn "sing-box ${candidate} failed validation or startup; restoring ${installed}."
    dpkg --force-confold -i "$old_package" >/dev/null || die 'Automatic package rollback failed during dpkg installation.'
    sing-box check -c "$CONFIG_FILE" >/dev/null || die 'Rollback package cannot validate the existing configuration.'
    systemctl restart sing-box.service
    systemctl is-active --quiet sing-box.service || die 'Rollback package was restored, but sing-box is not active.'
    apt-mark hold sing-box >/dev/null
    die "Update failed; sing-box ${installed} was restored."
  fi

  apt-mark hold sing-box >/dev/null
  prune_sing_box_packages
  log "sing-box updated successfully: ${installed} -> ${candidate}."
}

redact_diagnostic_stream() {
  sed -E \
    -e 's#(vless|hysteria2)://[^[:space:]]+#\1://[REDACTED]#g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{64}/[TOKEN-REDACTED]/g' \
    -e 's/[0-9a-fA-F]{48}/[SECRET-REDACTED]/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g' \
    -e 's/\[[0-9a-fA-F:]+\]/[IPv6-REDACTED]/g' \
    -e 's/((password|private_key|public_key|short_id|secret|pbk|sid)[^:=]*[:=][[:space:]]*)[^, }"]+/\1[REDACTED]/Ig'
}

print_fragmentation_guidance() {
  cat <<'EOF'
### Client-side REALITY fragmentation guidance
Server-enforced fragmentation: disabled (this is a client-side troubleshooting option)
Subscription-enforced fragmentation: disabled (client syntax is not portable)

Leave fragmentation disabled while REALITY works. If Hysteria2 works but
REALITY repeatedly times out on one network, first test another supported TLS
fingerprint with "sudo vpn set-fingerprint" and refresh the subscription.
Only then, in one affected client, temporarily test TLS-record/TLSHello
fragmentation if that client explicitly supports it. Do not enable ordinary
packet fragmentation globally: it can increase latency, battery use, and
breakage, and it cannot repair an IP block or an unreachable TCP/443 path.
Record the client name/version, access network, and result before keeping it.
EOF
}

diagnostic_report() {
  local config_result dns_one dns_two cert_status target_status service_status
  local timer_enabled timer_active hook_status renewal_status sync_status keypair_status
  local health_status=0
  require_root
  printf '### Health summary\n'
  health_check || health_status=$?
  printf '\n'
  printf 'VPN diagnostic report (share-safe)\n'
  printf 'Generated: %s\n' "$(date --iso-8601=seconds)"
  printf 'Installer: %s\n\n' "$SCRIPT_VERSION"

  printf '### Client profiles\n'
  printf 'REALITY fingerprint: %s\n' "$CLIENT_FINGERPRINT"
  printf 'Hysteria2 obfuscation: salamander\n'
  printf 'Subscription URLs: stable across target/fingerprint changes\n\n'

  printf '### System\n'
  sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'
  printf 'Kernel: %s\n' "$(uname -r)"
  uptime -p 2>/dev/null || true
  free -h 2>/dev/null | sed -n '1,2p' || true
  df -h / 2>/dev/null | tail -n 1 || true
  swapon --show 2>/dev/null || true
  timedatectl show -p NTPSynchronized -p Timezone 2>/dev/null || true

  printf '\n### Core\n'
  printf 'Installed: %s\n' "$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || printf missing)"
  printf 'APT hold: %s\n' "$(apt-mark showhold 2>/dev/null | grep -Fx sing-box || printf missing)"
  service_status="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  printf 'Service: %s\n' "${service_status:-unknown}"
  if config_result="$(sing-box check -c "$CONFIG_FILE" 2>&1)"; then
    printf 'Config validation: PASS\n'
  else
    printf 'Config validation: FAIL\n%s\n' "$config_result" | redact_diagnostic_stream
  fi
  jq -r '.inbounds[] | "Inbound: \(.type) tag=\(.tag) port=\(.listen_port) users=\(.users | length)"' \
    "$CONFIG_FILE" 2>/dev/null || true

  printf '\n### Network\n'
  printf 'Configured public IPv4: [REDACTED]\n'
  dns_one="$(dig +short A "$TLS_DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)"
  dns_two="$(dig +short A "$TLS_DOMAIN" @8.8.8.8 2>/dev/null | sed '/^$/d' || true)"
  if grep -Fxq "$SERVER_IPV4" <<<"$dns_one" && grep -Fxq "$SERVER_IPV4" <<<"$dns_two"; then
    printf 'DNS A consistency: PASS\n'
  else
    printf 'DNS A consistency: FAIL\n'
  fi
  if timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" -servername "$REALITY_TARGET" \
      -tls1_3 -alpn h2 -verify_return_error </dev/null >/dev/null 2>&1; then
    target_status=PASS
  else
    target_status=FAIL
  fi
  printf 'REALITY target TLS reachability: %s\n' "$target_status"
  printf 'Listeners (addresses redacted):\n'
  ss -H -lntup 2>/dev/null | awk -v ssh_port="$SSH_PORT" -v subscription_port="$SUBSCRIPTION_PORT" \
    '$5 ~ (":" ssh_port "$") || $5 ~ (":" subscription_port "$") || $5 ~ /:(80|443)$/ {print}' | redact_diagnostic_stream
  printf 'UDP receive ceiling: %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || printf unknown)"
  printf 'UDP send ceiling: %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || printf unknown)"

  printf '\n'
  print_fragmentation_guidance

  printf '\n### Certificate\n'
  if [[ -r "${CERT_DIR}/fullchain.pem" ]]; then
    openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -dates 2>/dev/null || true
    if openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1; then
      cert_status='PASS (valid for more than 7 days)'
    else
      cert_status='WARN (expired or expires within 7 days)'
    fi
  else
    cert_status='FAIL (certificate copy missing)'
  fi
  printf 'Certificate status: %s\n' "$cert_status"
  timer_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  timer_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
  printf 'Certbot timer enabled: %s\n' "${timer_enabled:-unknown}"
  printf 'Certbot timer active: %s\n' "${timer_active:-unknown}"
  if [[ -f "$CERT_HOOK" && -x "$CERT_HOOK" ]] && sh -n "$CERT_HOOK" >/dev/null 2>&1; then
    hook_status='PASS (present, executable, syntax valid)'
  else
    hook_status='FAIL'
  fi
  printf 'Deploy hook: %s\n' "$hook_status"
  if [[ -r "/etc/letsencrypt/renewal/${TLS_DOMAIN}.conf" ]]; then
    renewal_status='PASS'
  else
    renewal_status='FAIL'
  fi
  printf 'Renewal configuration: %s\n' "$renewal_status"
  if [[ -r "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" &&
        -r "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" &&
        -r "${CERT_DIR}/fullchain.pem" && -r "${CERT_DIR}/privkey.pem" ]] &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" "${CERT_DIR}/fullchain.pem" &&
     cmp -s "/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem" "${CERT_DIR}/privkey.pem"; then
    sync_status='PASS'
  else
    sync_status='FAIL'
  fi
  printf 'Live/deployed certificate sync: %s\n' "$sync_status"
  if certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"; then
    keypair_status='PASS'
  else
    keypair_status='FAIL'
  fi
  printf 'Deployed certificate/key pair: %s\n' "$keypair_status"

  printf '\n### Firewall and services\n'
  if nft list table inet vpn_filter >/dev/null 2>&1; then
    printf 'nftables vpn_filter: PASS\n'
  else
    printf 'nftables vpn_filter: FAIL\n'
  fi
  systemctl --failed --no-pager --no-legend 2>/dev/null || true
  journalctl --disk-usage 2>/dev/null || true

  printf '\n### Recent sing-box warnings/errors (redacted)\n'
  journalctl -u sing-box.service --since '-30 minutes' -p warning..alert -n 80 \
    --no-pager --output=short-iso 2>/dev/null | redact_diagnostic_stream || true
  printf '\nSecrets, client UUIDs, connection URIs, and IP addresses are redacted. Review before sharing.\n'
  return "$health_status"
}

health_check() {
  local failures=0 dns_one dns_two firewall_input

  require_root
  printf 'VPN health check (read-only)\n'
  printf 'Generated: %s\n' "$(date --iso-8601=seconds)"
  printf 'INFO  client REALITY fingerprint: %s\n' "$CLIENT_FINGERPRINT"

  if systemctl is-active --quiet sing-box.service; then
    printf 'PASS  sing-box service is active\n'
  else
    printf 'FAIL  sing-box service is not active\n'
    (( failures += 1 ))
  fi

  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    printf 'PASS  sing-box configuration is valid\n'
  else
    printf 'FAIL  sing-box configuration is invalid\n'
    (( failures += 1 ))
  fi

  if jq -e '
      any(.inbounds[];
        .type == "vless" and .listen_port == 443 and
        .tls.enabled == true and .tls.reality.enabled == true and
        ((.users | length) > 0))' "$CONFIG_FILE" >/dev/null 2>&1 &&
     ss -H -lntp 2>/dev/null |
       awk '$4 ~ /:443$/ && $0 ~ /sing-box/ { found=1 } END { exit !found }'; then
    printf 'PASS  VLESS/REALITY is configured and owns TCP/443\n'
  else
    printf 'FAIL  VLESS/REALITY configuration or TCP/443 listener is unhealthy\n'
    (( failures += 1 ))
  fi

  if subscription_service_healthy; then
    printf 'PASS  HTTPS subscription returns URI and Mihomo profiles\n'
  else
    printf 'FAIL  HTTPS subscription service or generated profiles are unhealthy\n'
    (( failures += 1 ))
  fi

  if jq -e '
      any(.inbounds[];
        .type == "hysteria2" and .listen_port == 443 and
        .tls.enabled == true and ((.users | length) > 0))' \
      "$CONFIG_FILE" >/dev/null 2>&1 &&
     ss -H -lnup 2>/dev/null |
       awk '$4 ~ /:443$/ && $0 ~ /sing-box/ { found=1 } END { exit !found }'; then
    printf 'PASS  Hysteria2 is configured and owns UDP/443\n'
  else
    printf 'FAIL  Hysteria2 configuration or UDP/443 listener is unhealthy\n'
    (( failures += 1 ))
  fi

  dns_one="$(dig +short A "$TLS_DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)"
  dns_two="$(dig +short A "$TLS_DOMAIN" @8.8.8.8 2>/dev/null | sed '/^$/d' || true)"
  if grep -Fxq "$SERVER_IPV4" <<<"$dns_one" && grep -Fxq "$SERVER_IPV4" <<<"$dns_two"; then
    printf 'PASS  public DNS resolvers return the configured IPv4\n'
  else
    printf 'FAIL  public DNS resolvers do not consistently return the configured IPv4\n'
    (( failures += 1 ))
  fi

  if [[ -r "${CERT_DIR}/fullchain.pem" ]] &&
     openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1 &&
     certificate_key_pair_matches "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"; then
    printf 'PASS  TLS certificate is valid for more than seven days and matches its key\n'
  else
    printf 'FAIL  TLS certificate is missing, mismatched, expired, or expires within seven days\n'
    (( failures += 1 ))
  fi

  if systemctl is-enabled --quiet certbot.timer 2>/dev/null &&
     systemctl is-active --quiet certbot.timer 2>/dev/null &&
     [[ -x "$CERT_HOOK" ]] && sh -n "$CERT_HOOK" >/dev/null 2>&1; then
    printf 'PASS  certificate renewal timer and deploy hook are ready\n'
  else
    printf 'FAIL  certificate renewal timer or deploy hook is unhealthy\n'
    (( failures += 1 ))
  fi

  if timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" \
      -servername "$REALITY_TARGET" -tls1_3 -alpn h2 -verify_return_error \
      </dev/null >/dev/null 2>&1; then
    printf 'PASS  REALITY target is reachable with verified TLS 1.3 and h2\n'
  else
    printf 'FAIL  REALITY target TLS probe failed\n'
    (( failures += 1 ))
  fi

  firewall_input="$(nft list chain inet vpn_filter input 2>/dev/null || true)"
  if grep -Eq 'tcp dport.*443.*accept' <<<"$firewall_input" &&
     grep -Eq "tcp dport.*${SUBSCRIPTION_PORT}.*accept" <<<"$firewall_input" &&
     grep -Eq 'udp dport 443.*accept' <<<"$firewall_input"; then
    printf 'PASS  nftables permits TCP/443, UDP/443, and TCP/%s\n' "$SUBSCRIPTION_PORT"
  else
    printf 'FAIL  a managed VPN or subscription firewall rule is missing\n'
    (( failures += 1 ))
  fi

  if (( failures == 0 )); then
    printf 'RESULT: HEALTHY\n'
    return 0
  fi
  printf 'RESULT: UNHEALTHY (%d failed checks)\n' "$failures"
  return 1
}

show_status() {
  local configured_target="unknown" timer_enabled timer_active
  require_root
  if [[ -r "$CONFIG_FILE" ]]; then
    configured_target="$(jq -r \
      '[.inbounds[] | select(.tag == "vless-reality-in") | .tls.reality.handshake.server][0] // "unknown"' \
      "$CONFIG_FILE" 2>/dev/null || printf unknown)"
  fi
  printf 'VPN setup version: %s\n' "$SCRIPT_VERSION"
  printf 'sing-box package: '
  dpkg-query -W -f='${Version}\n' sing-box 2>/dev/null || printf 'not installed\n'
  printf 'sing-box APT hold: '
  if apt-mark showhold 2>/dev/null | grep -Fxq sing-box; then
    printf 'active (use vpn update)\n'
  else
    printf 'missing\n'
  fi
  printf 'sing-box service: '
  systemctl is-active sing-box.service 2>/dev/null || true
  printf 'subscription service: '
  systemctl is-active nginx.service 2>/dev/null || true
  printf 'nftables persistent: '
  if [[ -f "${STATE_DIR}/firewall.confirmed" ]]; then
    printf 'confirmed\n'
  else
    printf 'not confirmed\n'
  fi
  printf 'SSH lockdown: '
  [[ -f "$SSH_DROPIN" ]] && printf 'installed\n' || printf 'not installed\n'
  printf 'REALITY target: %s\n' "$configured_target"
  printf 'Client fingerprint: %s\n' "$CLIENT_FINGERPRINT"
  printf 'Profile labels: %s Reality / %s Hysteria2\n' "$COUNTRY_EMOJI" "$COUNTRY_EMOJI"
  printf 'TCP congestion control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  printf 'Default qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
  printf 'UDP receive ceiling: %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || printf unknown)"
  printf 'UDP send ceiling: %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || printf unknown)"
  timer_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  timer_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
  printf 'Certbot timer: %s / %s\n' "${timer_enabled:-unknown}" "${timer_active:-unknown}"
  printf 'Active qdisc(s):\n'
  tc qdisc show 2>/dev/null || true
  printf 'Swap:\n'
  swapon --show || true
  printf 'Journal disk usage:\n'
  journalctl --disk-usage 2>/dev/null || true
  printf 'Failed systemd units:\n'
  if ! systemctl --failed --no-pager --no-legend; then
    warn 'systemctl could not query failed units.'
  fi
  printf 'Running systemd services:\n'
  if ! systemctl list-units --type=service --state=running --no-pager --no-legend; then
    warn 'systemctl could not query running services.'
  fi
  printf 'Listeners on SSH/80/443/%s:\n' "$SUBSCRIPTION_PORT"
  ss -H -lntup | awk -v ssh_port="$SSH_PORT" -v subscription_port="$SUBSCRIPTION_PORT" \
    '$5 ~ (":" ssh_port "$") || $5 ~ (":" subscription_port "$") || $5 ~ /:(80|443)$/ {print}' || true
  printf 'DNS A record:\n'
  dig +short A "$TLS_DOMAIN" @1.1.1.1 || true
  if command -v sing-box >/dev/null 2>&1 && [[ -r "$CONFIG_FILE" ]]; then
    sing-box check -c "$CONFIG_FILE"
  fi
  printf 'VPN clients: '
  if [[ -r "$CLIENTS_FILE" ]]; then
    jq '.clients | length' "$CLIENTS_FILE"
  else
    printf 'database unavailable\n'
  fi
}

write_install_completion_marker() {
  printf '%s\n' "completed $(date --iso-8601=seconds) version=${SCRIPT_VERSION}" >"${INSTALL_COMPLETE_FILE}.new"
  chmod 0600 "${INSTALL_COMPLETE_FILE}.new"
  mv -f -- "${INSTALL_COMPLETE_FILE}.new" "$INSTALL_COMPLETE_FILE"
}

backup_upgrade_file() {
  local source="$1" label="$2" mode="$3"
  if [[ -e "$source" ]]; then
    [[ -f "$source" && ! -L "$source" ]] || die "Unexpected managed path cannot be backed up safely: $source"
    install -o root -g root -m "$mode" "$source" "${UPGRADE_BACKUP_DIR}/${label}"
    printf '%s\n' present >"${UPGRADE_BACKUP_DIR}/${label}.state"
  else
    printf '%s\n' absent >"${UPGRADE_BACKUP_DIR}/${label}.state"
  fi
}

restore_upgrade_file() {
  local target="$1" label="$2" owner="$3" group="$4" mode="$5" state
  state="$(<"${UPGRADE_BACKUP_DIR}/${label}.state")"
  if [[ "$state" == "present" ]]; then
    install -o "$owner" -g "$group" -m "$mode" "${UPGRADE_BACKUP_DIR}/${label}" "${target}.rollback"
    mv -f -- "${target}.rollback" "$target"
  else
    rm -f -- "$target" "${target}.new" "${target}.rollback"
  fi
}

prepare_upgrade_transaction() {
  UPGRADE_BACKUP_DIR="$(mktemp -d)"
  chmod 0700 "$UPGRADE_BACKUP_DIR"
  UPGRADE_ORIGINAL_RMEM="$(sysctl -n net.core.rmem_max)"
  UPGRADE_ORIGINAL_WMEM="$(sysctl -n net.core.wmem_max)"
  backup_upgrade_file "$UDP_SYSCTL_FILE" udp-sysctl 0644
  backup_upgrade_file "$CERT_HOOK" certificate-hook 0750
  backup_upgrade_file "$INSTALLED_HELPER" vpn-helper 0750
  backup_upgrade_file "$INSTALL_COMPLETE_FILE" completion-marker 0600
  UPGRADE_ROLLBACK_FAILED=0
  UPGRADE_ROLLBACK_ACTIVE=1
}

rollback_upgrade_transaction() {
  local restore_failed=0
  (( UPGRADE_ROLLBACK_ACTIVE == 1 )) || return 0
  printf '[WARN] Overlay update did not complete; restoring its previous managed files and runtime UDP ceilings.\n' >&2
  set +e
  restore_upgrade_file "$UDP_SYSCTL_FILE" udp-sysctl root root 0644 || restore_failed=1
  restore_upgrade_file "$CERT_HOOK" certificate-hook root root 0750 || restore_failed=1
  restore_upgrade_file "$INSTALLED_HELPER" vpn-helper root root 0750 || restore_failed=1
  restore_upgrade_file "$INSTALL_COMPLETE_FILE" completion-marker root root 0600 || restore_failed=1
  if [[ "$UPGRADE_ORIGINAL_RMEM" =~ ^[0-9]+$ ]]; then
    sysctl -q -w "net.core.rmem_max=${UPGRADE_ORIGINAL_RMEM}" >/dev/null 2>&1 || restore_failed=1
  fi
  if [[ "$UPGRADE_ORIGINAL_WMEM" =~ ^[0-9]+$ ]]; then
    sysctl -q -w "net.core.wmem_max=${UPGRADE_ORIGINAL_WMEM}" >/dev/null 2>&1 || restore_failed=1
  fi
  UPGRADE_ROLLBACK_ACTIVE=0
  set -e
  if (( restore_failed == 1 )); then
    UPGRADE_ROLLBACK_FAILED=1
    printf '[FATAL] Overlay rollback was incomplete. Do not reboot; inspect %s and restore the reported managed files manually.\n' \
      "$UPGRADE_BACKUP_DIR" >&2
  else
    UPGRADE_ROLLBACK_FAILED=0
  fi
}

upgrade_existing_installation() {
  local current_helper_version current_state_version helper_backup=""
  require_command dpkg
  require_command sysctl
  require_client_runtime
  [[ -f "$INSTALL_COMPLETE_FILE" ]] || die 'Installation completion marker is missing; resume the install command instead of upgrading.'
  [[ -f "${STATE_DIR}/firewall.confirmed" ]] || \
    die 'Firewall is not confirmed; run the install command to reapply it, then confirm it from a second SSH session before upgrading.'

  current_helper_version="$(installed_helper_version)"
  current_state_version="$(installed_state_version)"
  [[ -n "$current_helper_version" ]] || die 'Installed management helper version is unavailable.'
  [[ -n "$current_state_version" ]] || die 'Installed state version is unavailable.'
  dpkg --validate-version "$current_helper_version" >/dev/null 2>&1 || die 'Installed helper reports an invalid version.'
  dpkg --validate-version "$current_state_version" >/dev/null 2>&1 || die 'Installed state reports an invalid version.'
  dpkg --compare-versions "$SCRIPT_VERSION" ge "$current_helper_version" || \
    die "Refusing installer downgrade from ${current_helper_version} to ${SCRIPT_VERSION}."
  dpkg --compare-versions "$SCRIPT_VERSION" ge "$current_state_version" || \
    die "Refusing state downgrade from ${current_state_version} to ${SCRIPT_VERSION}."

  if [[ "$current_helper_version" == "$SCRIPT_VERSION" && "$current_state_version" == "$SCRIPT_VERSION" ]]; then
    log "Installer and managed state are already at ${SCRIPT_VERSION}; no overlay update is required."
    return
  fi

  cat <<EOF
VPN installer overlay update

  Installed helper: ${current_helper_version}
  Managed state:    ${current_state_version}
  Candidate:        ${SCRIPT_VERSION}

The update preserves settings, clients, UUIDs, passwords, REALITY keys,
certificates, SSH configuration, and firewall policy. It applies only reviewed
managed migrations, smoke-tests certificate deployment, then atomically replaces
the vpn helper while retaining the previous helper backup.
EOF
  require_confirmation

  set_step 'existing installation validation'
  sing-box check -c "$CONFIG_FILE" >/dev/null
  systemctl is-active --quiet sing-box.service || die 'sing-box must be active before an overlay update.'
  validate_client_database "$CLIENTS_FILE"
  prepare_upgrade_transaction

  set_step 'Hysteria2 UDP socket-buffer ceilings'
  configure_udp_buffer_ceilings
  set_step 'certificate renewal hook migration'
  configure_certificate_hook
  smoke_test_certificate_hook
  set_step 'management helper atomic replacement'
  install_helper
  helper_backup="$LAST_HELPER_BACKUP"
  if ! "$INSTALLED_HELPER" status >/dev/null 2>&1; then
    restore_installed_helper "$helper_backup" || die 'New helper failed its post-install check and automatic helper rollback also failed.'
    die 'New helper failed its post-install check; the previous helper was restored.'
  fi
  set_step 'managed state version marker'
  write_install_completion_marker
  UPGRADE_ROLLBACK_ACTIVE=0
  log "Overlay update completed: ${current_state_version} -> ${SCRIPT_VERSION}."
  [[ -z "$helper_backup" ]] || log "Previous helper backup: ${helper_backup}"
}

run_upgrade() {
  require_root
  require_command tee
  start_install_log
  set_step 'upgrade state and concurrency lock'
  require_command flock
  install -d -o root -g root -m 0700 "$STATE_DIR"
  exec 7>"$INSTALL_LOCK_FILE"
  flock -n 7 || die 'Another VPN installation or upgrade process is already running.'
  upgrade_existing_installation
}

run_install() {
  require_root
  require_command tee
  start_install_log
  set_step 'installation state and concurrency lock'
  require_command flock
  install -d -o root -g root -m 0700 "$STATE_DIR"
  exec 7>"$INSTALL_LOCK_FILE"
  flock -n 7 || die 'Another VPN installation process is already running.'

  if [[ -r "$SETTINGS_FILE" ]]; then
    load_resume_settings
    if [[ -f "$INSTALL_COMPLETE_FILE" && -f "${STATE_DIR}/firewall.confirmed" ]]; then
      log 'A completed and firewall-confirmed VPN installation exists; switching install to safe overlay-update mode.'
      upgrade_existing_installation
      return
    fi
    if [[ -f "$INSTALL_COMPLETE_FILE" ]]; then
      warn 'The installation payload is complete, but the firewall is not confirmed; reapplying it and restarting the five-minute rollback window.'
      show_plan
      require_confirmation
      require_command nft
      require_command systemctl
      require_command systemd-run
      set_step 'nftables firewall recovery deployment'
      apply_firewall
      cat <<EOF

Firewall reapplied with automatic rollback in five minutes.
From a SECOND verified SSH session run:
  sudo vpn confirm-firewall --yes
  sudo vpn status
EOF
      return
    fi
    log 'Found an interrupted installation; resuming with its validated saved settings.'
  else
    [[ ! -e "$SETTINGS_FILE" ]] || die "${SETTINGS_FILE} exists but is not a readable regular file."
    collect_install_settings
  fi
  show_plan
  require_confirmation

  set_step 'required command availability'
  require_command apt-get
  require_command dpkg
  require_command ip
  require_command ss
  require_command ssh-keygen
  require_command systemctl
  require_command systemd-run

  set_step 'operating system compatibility'
  preflight_os
  set_step 'hardware and system runtime compatibility'
  preflight_hardware_and_runtime
  set_step 'public IPv4 validation'
  preflight_public_ip
  set_step 'port availability'
  preflight_ports
  set_step 'storage capacity'
  preflight_disk
  set_step 'Debian/Ubuntu dependency installation'
  install_base_packages
  set_step 'administrator public-key validation'
  preflight_key
  set_step 'TLS domain DNS validation'
  verify_dns
  set_step 'REALITY target validation'
  verify_reality_target
  set_step 'saving resumable installation settings'
  save_settings
  log 'Saved validated installation settings; a failed installation can now be resumed safely.'
  set_step 'sing-box repository and package installation'
  install_sing_box
  set_step 'administrative account configuration'
  create_admin_account
  set_step 'swap configuration'
  configure_swap
  set_step 'optional BBR configuration'
  configure_bbr_if_available
  set_step 'Hysteria2 UDP socket-buffer ceilings'
  configure_udp_buffer_ceilings
  set_step 'journal storage limits'
  configure_journal_limits
  set_step 'automatic security updates'
  configure_unattended_upgrades
  set_step 'ACME certificate acquisition and deployment'
  obtain_certificate
  set_step 'sing-box configuration generation'
  write_sing_box_config
  set_step 'private multi-format subscription generation'
  publish_subscription_tree "$CLIENTS_FILE"
  set_step 'restricted nginx subscription configuration'
  configure_subscription_service
  set_step 'sing-box systemd hardening'
  write_systemd_hardening
  set_step 'sing-box service startup'
  start_sing_box
  set_step 'subscription service startup and self-test'
  start_subscription_service
  verify_subscription_service
  set_step 'certificate renewal hook smoke test'
  smoke_test_certificate_hook
  set_step 'management command installation'
  install_helper >/dev/null
  set_step 'nftables firewall deployment'
  apply_firewall
  set_step 'installation completion marker'
  write_install_completion_marker

  cat <<EOF

Installation payload completed, but two safety confirmations remain.

Within five minutes, open a SECOND local terminal and test:
  ssh -p ${SSH_PORT} ${ADMIN_USER}@${SERVER_IPV4}

From that new ${ADMIN_USER} session run:
  sudo vpn confirm-firewall --yes
  sudo vpn status

Only after that session works, disable root/password SSH:
  sudo vpn lockdown-ssh --yes

An independent ${INITIAL_CLIENT_NAME} VPN profile was created. Its credentials
were NOT printed. Manage profiles from the verified ${ADMIN_USER} session:
  sudo vpn list
  sudo vpn show ${INITIAL_CLIENT_NAME}
  sudo vpn add WorkPC
EOF
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    plan|check|install|help)
      ;;
    *)
      load_settings
      ;;
  esac
  case "$COMMAND" in
    plan)
      show_plan
      ;;
    check)
      compatibility_check
      ;;
    install)
      run_install
      ;;
    upgrade)
      run_upgrade
      ;;
    update)
      update_sing_box
      ;;
    self-update)
      self_update_from_file
      ;;
    diagnostic)
      if ! diagnostic_report; then
        exit 1
      fi
      ;;
    status)
      show_status
      ;;
    confirm-firewall)
      confirm_firewall
      ;;
    rollback-firewall)
      rollback_firewall
      ;;
    lockdown-ssh)
      lockdown_ssh
      ;;
    client-add)
      client_add
      ;;
    client-show)
      client_show
      ;;
    client-delete)
      client_delete
      ;;
    client-list)
      client_list
      ;;
    set-target)
      set_reality_target
      ;;
    set-fingerprint)
      set_client_fingerprint
      ;;
    help)
      usage
      ;;
    *)
      usage >&2
      die "Unknown command: $COMMAND"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
