#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fixture="${work}/installer.sh"
cp "${repo_root}/install-sing-box-server.sh" "$fixture"
for mapping in \
  "STATE_DIR:${work}/state" \
  "CONFIG_DIR:${work}/config" \
  "INSTALLED_HELPER:${work}/installed-helper" \
  "USER_COMMAND:${work}/user-command" \
  "SUBSCRIPTION_ROOT:${work}/subscriptions" \
  "NFTABLES_SYSTEMD_DROPIN_DIR:${work}/nftables.service.d" \
  "NFTABLES_SYSTEMD_DROPIN:${work}/nftables.service.d/90-vpn-table-boundary.conf"
do
  constant="${mapping%%:*}"
  path="${mapping#*:}"
  sed -i.bak "s|^readonly ${constant}=.*|readonly ${constant}=\"${path}\"|" "$fixture"
  rm -f -- "${fixture}.bak"
done

# shellcheck disable=SC1090 # The generated fixture is the artifact under test.
source "$fixture"

operation_log="${work}/operations.log"
systemd_log="${work}/systemd.log"
masquerade_state=healthy
effective_execstop_mode=healthy

portable_install() {
  local directory=0 mode="" source destination
  while (( $# > 0 )); do
    case "$1" in
      -d) directory=1; shift ;;
      -D) directory=2; shift ;;
      -o|-g) shift 2 ;;
      -m) mode="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  if (( directory == 1 )); then
    for destination in "$@"; do
      mkdir -p "$destination"
      [[ -z "$mode" ]] || command chmod "$mode" "$destination"
    done
    return 0
  fi
  if (( directory == 2 )); then
    source="$1"
    destination="$2"
    mkdir -p "$(dirname -- "$destination")"
    cp "$source" "$destination"
    [[ -z "$mode" ]] || command chmod "$mode" "$destination"
    return 0
  fi
  source="$1"
  destination="$2"
  mkdir -p "$(dirname -- "$destination")"
  cp "$source" "$destination"
  [[ -z "$mode" ]] || command chmod "$mode" "$destination"
}

install() {
  printf 'install %s\n' "$*" >>"$operation_log"
  portable_install "$@"
}

chown() {
  printf 'chown %s %s\n' "$1" "$2" >>"$operation_log"
}

chmod() {
  printf 'chmod %s %s\n' "$1" "$2" >>"$operation_log"
  if [[ "${1:-}" == 0750 && "${2:-}" == "$HY2_MASQUERADE_ROOT" ]]; then
    masquerade_state=healthy
  fi
}

stat() {
  [[ "${1:-}" == -c && "${2:-}" == '%a:%U:%G' ]] || return 1
  case "${3:-}" in
    "$HY2_MASQUERADE_ROOT")
      if [[ "$masquerade_state" == healthy ]]; then
        printf '%s\n' '750:root:sing-box'
      else
        printf '%s\n' '700:root:root'
      fi
      ;;
    "${HY2_MASQUERADE_ROOT}/index.html")
      if [[ "$masquerade_state" == healthy ]]; then
        printf '%s\n' '644:root:sing-box'
      else
        printf '%s\n' '600:root:root'
      fi
      ;;
    *) return 1 ;;
  esac
}

dpkg() {
  case "${1:-}" in
    --validate-version) [[ "${2:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    --compare-versions) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() { :; }
require_command() { :; }
require_client_runtime() { :; }
acquire_operation_lock() { :; }
systemctl() {
  if [[ "${1:-}" != show ]]; then
    printf '%s\n' "$*" >>"$systemd_log"
  fi
  if [[ "${1:-}" == show && "$*" == *ExecStop* ]]; then
    case "$effective_execstop_mode" in
      healthy)
        printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft delete table inet vpn_filter ; ignore_errors=yes ; start_time=[n/a] ; }'
        ;;
      conflict)
        printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft delete table inet vpn_filter ; ignore_errors=yes ; } { path=/usr/sbin/nft ; argv[]=/usr/sbin/nft flush ruleset ; ignore_errors=no ; }'
        ;;
      unexpected)
        printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft delete table inet vpn_filter ; ignore_errors=yes ; } { path=/usr/bin/true ; argv[]=/usr/bin/true ; ignore_errors=no ; }'
        ;;
      missing)
        printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft delete table inet other_table ; ignore_errors=yes ; }'
        ;;
      malformed)
        printf '%s\n' 'ExecStop is ambiguous'
        ;;
      *)
        return 1
        ;;
    esac
  fi
  return 0
}

mkdir -p "$STATE_DIR" "$CONFIG_DIR/masquerade"
mkdir -p "$NFTABLES_SYSTEMD_DROPIN_DIR"
render_nftables_service_boundary "$NFTABLES_SYSTEMD_DROPIN"

effective_execstop_mode=healthy
nftables_service_boundary_is_healthy
for effective_execstop_mode in conflict unexpected missing malformed; do
  if nftables_service_boundary_is_healthy; then
    printf 'Unsafe effective ExecStop mode was accepted: %s\n' "$effective_execstop_mode" >&2
    exit 1
  fi
done
effective_execstop_mode=healthy

: >"$operation_log"
: >"${STATE_DIR}/firewall.confirmed"
: >"${HY2_MASQUERADE_ROOT}/index.html"
printf '%s\n' 'completed version=1.0.11' >"$INSTALL_COMPLETE_FILE"
printf '%s\n' '1.0.11' >"$RUNTIME_VERSION_FILE"
cat >"$INSTALLED_HELPER" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.0.11"
readonly PROJECT_NAME="vpn-setup"
EOF
for managed_file in "$SETTINGS_FILE" "$SECRETS_FILE" "$CLIENTS_FILE" "$CONFIG_FILE"; do
  mkdir -p "$(dirname -- "$managed_file")"
  printf 'stable-managed-state\n' >"$managed_file"
done

snapshot="${work}/snapshot.sha256"
snapshot_managed_state() {
  sha256sum "$SETTINGS_FILE" "$SECRETS_FILE" "$CLIENTS_FILE" "$CONFIG_FILE" >"$snapshot"
}

run_same_version() {
  # shellcheck disable=SC2034 # Consumed by require_confirmation in the sourced installer.
  ASSUME_YES=1
  upgrade_existing_installation >/dev/null
}

snapshot_managed_state
healthy_operations_before="$(wc -l <"$operation_log" 2>/dev/null || printf 0)"
run_same_version
[[ "$masquerade_state" == healthy ]]
[[ "$(wc -l <"$operation_log" 2>/dev/null || printf 0)" == "$healthy_operations_before" ]]
[[ ! -e "$systemd_log" ]]
cmp -s "$snapshot" <(sha256sum "$SETTINGS_FILE" "$SECRETS_FILE" "$CLIENTS_FILE" "$CONFIG_FILE")
[[ ! -d "$DEFERRED_MUTATION_ROOT" ]]
[[ -f "$NFTABLES_SYSTEMD_DROPIN" ]]

masquerade_state=drift
snapshot_managed_state
drift_operations_before="$(wc -l <"$operation_log" 2>/dev/null || printf 0)"
run_same_version
[[ "$masquerade_state" == healthy ]]
[[ "$(wc -l <"$operation_log")" -gt "$drift_operations_before" ]]
grep -Fq "chown root:sing-box $HY2_MASQUERADE_ROOT" "$operation_log"
grep -Fq "chmod 0750 $HY2_MASQUERADE_ROOT" "$operation_log"
grep -Fq "chown root:sing-box $HY2_MASQUERADE_ROOT/index.html.new" "$operation_log"
grep -Fq "chmod 0644 $HY2_MASQUERADE_ROOT/index.html.new" "$operation_log"
[[ ! -e "$systemd_log" ]]
cmp -s "$snapshot" <(sha256sum "$SETTINGS_FILE" "$SECRETS_FILE" "$CLIENTS_FILE" "$CONFIG_FILE")

repaired_operations="$(wc -l <"$operation_log")"
run_same_version
[[ "$(wc -l <"$operation_log")" == "$repaired_operations" ]]
[[ ! -e "$systemd_log" ]]
[[ "$masquerade_state" == healthy ]]

rm -f -- "$NFTABLES_SYSTEMD_DROPIN"
: >"$systemd_log"
run_same_version
grep -Fxq 'daemon-reload' "$systemd_log"
grep -Fxq 'ExecStop=-/usr/sbin/nft delete table inet vpn_filter' "$NFTABLES_SYSTEMD_DROPIN"
rm -f -- "$systemd_log"

printf 'Same-version reconciliation smoke test: PASS\n'
