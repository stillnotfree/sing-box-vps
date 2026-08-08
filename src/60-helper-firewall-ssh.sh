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

self_update_from_file() {
  local source_path candidate candidate_version current_version
  require_root
  require_command dpkg
  source_path="$(readlink -f "$SELF_UPDATE_SOURCE" 2>/dev/null || true)"
  [[ -n "$source_path" ]] || die 'Unable to resolve the installer candidate path.'

  new_temp_dir
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
