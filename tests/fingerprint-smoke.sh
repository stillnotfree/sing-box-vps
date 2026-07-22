#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

[[ "$SCRIPT_VERSION" == "1.0.5" ]]
(( ${#SUPPORTED_CLIENT_FINGERPRINTS[@]} == 9 ))
(( ${#SUPPORTED_HY2_OBFS_MODES[@]} == 2 ))

parse_args set-fingerprint firefox --yes
[[ "$COMMAND" == "set-fingerprint" ]]
[[ "$NEW_CLIENT_FINGERPRINT" == "firefox" ]]
(( ASSUME_YES == 1 ))

(
  COMMAND="plan"
  NEW_HY2_OBFS_MODE=""
  ASSUME_YES=0
  parse_args set-obfs salamander --yes
  [[ "$COMMAND" == "set-obfs" ]]
  [[ "$NEW_HY2_OBFS_MODE" == "salamander" ]]
  (( ASSUME_YES == 1 ))
)

(
  COMMAND="plan"
  ASSUME_YES=0
  parse_args finalize --yes
  [[ "$COMMAND" == "finalize" ]]
  (( ASSUME_YES == 1 ))
)

for fingerprint in chrome firefox safari ios android edge 360 qq random; do
  client_fingerprint_is_supported "$fingerprint"
  validate_client_fingerprint "$fingerprint"
done

for mode in off salamander; do
  hy2_obfs_mode_is_supported "$mode"
  validate_hy2_obfs_mode "$mode"
done
if (validate_hy2_obfs_mode gecko >/dev/null 2>&1); then
  printf 'gecko unexpectedly passed the stable cross-client compatibility set\n' >&2
  exit 1
fi

if (validate_client_fingerprint randomized >/dev/null 2>&1); then
  printf 'randomized unexpectedly passed the cross-client compatibility set\n' >&2
  exit 1
fi

ADMIN_USER="vpnadmin"
ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButStructurallySingleLine test@example"
SERVER_IPV4="203.0.113.10"
TLS_DOMAIN="vpn.example.com"
ACME_EMAIL="admin@vpn-mail.net"
SSH_PORT="22"
REALITY_TARGET="www.example.com"
COUNTRY_EMOJI="🇩🇪"
CLIENT_FINGERPRINT="random"
HY2_OBFS_MODE="salamander"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
render_settings "${work}/settings.json"
jq -e '
  .schema_version == 1 and
  .client_fingerprint == "random" and
  .hy2_obfs_mode == "salamander" and
  .reality_target == "www.example.com"
' "${work}/settings.json" >/dev/null

validate_email 'admin@vpn-mail.net'
for reserved_email in \
  random@example.com \
  admin@example.org \
  admin@host.invalid \
  admin@service.test
do
  if (validate_email "$reserved_email" >/dev/null 2>&1); then
    printf 'Reserved ACME email unexpectedly passed validation: %s\n' "$reserved_email" >&2
    exit 1
  fi
done

# A corrected --email must be able to replace a syntax-valid but ACME-rejected
# address saved by an interrupted v1.0.0 installation.
(
  ADMIN_USER=""
  ADMIN_PUBLIC_KEY=""
  SERVER_IPV4=""
  TLS_DOMAIN=""
  ACME_EMAIL="admin@vpn-mail.net"
  SSH_PORT=""
  REALITY_TARGET=""
  COUNTRY_EMOJI=""
  CLIENT_FINGERPRINT=""
  HY2_OBFS_MODE=""
  load_settings() {
    ADMIN_USER="vpnadmin"
    ADMIN_PUBLIC_KEY="ssh-ed25519 test"
    SERVER_IPV4="203.0.113.10"
    TLS_DOMAIN="vpn.example.com"
    ACME_EMAIL="random@example.com"
    SSH_PORT="22"
    REALITY_TARGET="www.example.com"
    COUNTRY_EMOJI="🇩🇪"
    CLIENT_FINGERPRINT="chrome"
    HY2_OBFS_MODE="off"
  }
  load_resume_settings
  [[ "$ACME_EMAIL" == "admin@vpn-mail.net" ]]
)

if declare -F configure_first_login_hook >/dev/null || declare -F render_first_login_hook >/dev/null; then
  printf 'Obsolete automatic first-login finalization hook is still present.\n' >&2
  exit 1
fi
render_auto_finalize_wrapper "${work}/auto-finalize-login"
sh -n "${work}/auto-finalize-login"
grep -Fq 'SSH_ORIGINAL_COMMAND' "${work}/auto-finalize-login"
grep -Fq 'sudo -n "/usr/local/sbin/vpn" finalize --yes' "${work}/auto-finalize-login"
grep -Fq 'exec "$login_shell" -l' "${work}/auto-finalize-login"
render_auto_finalize_ssh_dropin "${work}/auto-finalize.conf"
grep -Fxq 'Match User vpnadmin' "${work}/auto-finalize.conf"
grep -Fxq '    DisableForwarding yes' "${work}/auto-finalize.conf"
grep -Fxq '    ForceCommand /usr/local/libexec/vpn-auto-finalize-login' "${work}/auto-finalize.conf"
grep -Fxq 'Match all' "${work}/auto-finalize.conf"

finalize_body="$(declare -f finalize_installation)"
grep -Fq 'ASSUME_YES=1' <<<"$finalize_body"
grep -Fq 'apply_firewall' <<<"$finalize_body"
grep -Fq 'confirm_firewall' <<<"$finalize_body"
grep -Fq 'remove_auto_finalization' <<<"$finalize_body"
if grep -Fq 'Open one more new SSH session' <<<"$finalize_body"; then
  printf 'Finalization still requires a second authorization cycle.\n' >&2
  exit 1
fi
configure_auto_body="$(declare -f configure_auto_finalization)"
grep -Fq '/usr/sbin/sshd -t' <<<"$configure_auto_body"
grep -Fq '/usr/sbin/sshd -T -C' <<<"$configure_auto_body"
grep -Fq 'forcecommand ${AUTO_FINALIZE_WRAPPER}' <<<"$configure_auto_body"
grep -Fq 'systemctl reload ssh.service' <<<"$configure_auto_body"
create_admin_body="$(declare -f create_admin_account)"
grep -Fq 'sudo -u "$ADMIN_USER" sudo -n /bin/true' <<<"$create_admin_body"

# Firewall confirmation must verify transient unit state instead of trusting a
# combined `systemctl stop timer service` exit code.  The service is commonly
# not loaded before the timer fires on both Debian and Ubuntu.
cancel_body="$(declare -f cancel_pending_firewall_rollback_strict)"
grep -Fq 'systemctl show --property=ActiveState --value' <<<"$cancel_body"
if grep -Fq 'systemctl stop "${unit_base}.timer" "${unit_base}.service"' <<<"$cancel_body"; then
  printf 'Firewall rollback cancellation still couples timer success to an absent transient service.\n' >&2
  exit 1
fi

(
  state_file="${work}/firewall.rollback.unit"
  printf '%s\n' 'vpn-nft-rollback-123-456' >"$state_file"
  systemctl() {
    case "$1" in
      show) printf '%s\n' inactive ;;
      stop|reset-failed) return 0 ;;
      is-active) return 3 ;;
      *) return 1 ;;
    esac
  }
  cancel_pending_firewall_rollback_strict "$state_file"
  [[ ! -e "$state_file" ]]
)

upgrade_body="$(declare -f upgrade_existing_installation)"
grep -Fq 'reconcile_managed_runtime' <<<"$upgrade_body"
grep -Fq 'write_runtime_version_marker' <<<"$upgrade_body"

printf 'Fingerprint state smoke test: PASS\n'
