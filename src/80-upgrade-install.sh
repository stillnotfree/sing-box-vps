write_install_completion_marker() {
  printf '%s\n' "completed $(date --iso-8601=seconds) version=${SCRIPT_VERSION}" >"${INSTALL_COMPLETE_FILE}.new"
  chmod 0600 "${INSTALL_COMPLETE_FILE}.new"
  mv -f -- "${INSTALL_COMPLETE_FILE}.new" "$INSTALL_COMPLETE_FILE"
}

write_runtime_version_marker() {
  printf '%s\n' "$SCRIPT_VERSION" >"${RUNTIME_VERSION_FILE}.new"
  chmod 0600 "${RUNTIME_VERSION_FILE}.new"
  mv -f -- "${RUNTIME_VERSION_FILE}.new" "$RUNTIME_VERSION_FILE"
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
  backup_upgrade_file "$USER_COMMAND" vpn-command 0755
  backup_upgrade_file "$INSTALL_COMPLETE_FILE" completion-marker 0600
  backup_upgrade_file "$RUNTIME_VERSION_FILE" runtime-version-marker 0600
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
  restore_upgrade_file "$USER_COMMAND" vpn-command root root 0755 || restore_failed=1
  restore_upgrade_file "$INSTALL_COMPLETE_FILE" completion-marker root root 0600 || restore_failed=1
  restore_upgrade_file "$RUNTIME_VERSION_FILE" runtime-version-marker root root 0600 || restore_failed=1
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
  local current_helper_version current_state_version current_runtime_version helper_backup=""
  require_command dpkg
  require_command sysctl
  require_client_runtime
  [[ -f "$INSTALL_COMPLETE_FILE" ]] || die 'Installation completion marker is missing; resume the install command instead of upgrading.'
  [[ -f "${STATE_DIR}/firewall.confirmed" ]] || \
    die 'Firewall is not confirmed; rerun the install command to arm automatic first-login finalization before upgrading.'

  current_helper_version="$(installed_helper_version)"
  current_state_version="$(installed_state_version)"
  current_runtime_version="$(cat "$RUNTIME_VERSION_FILE" 2>/dev/null || true)"
  [[ -n "$current_helper_version" ]] || die 'Installed management helper version is unavailable.'
  [[ -n "$current_state_version" ]] || die 'Installed state version is unavailable.'
  [[ -n "$current_runtime_version" ]] || die 'Managed runtime version is unavailable.'
  dpkg --validate-version "$current_helper_version" >/dev/null 2>&1 || die 'Installed helper reports an invalid version.'
  dpkg --validate-version "$current_state_version" >/dev/null 2>&1 || die 'Installed state reports an invalid version.'
  dpkg --validate-version "$current_runtime_version" >/dev/null 2>&1 || \
    die 'Managed runtime marker reports an invalid version.'
  dpkg --compare-versions "$SCRIPT_VERSION" ge "$current_helper_version" || \
    die "Refusing installer downgrade from ${current_helper_version} to ${SCRIPT_VERSION}."
  dpkg --compare-versions "$SCRIPT_VERSION" ge "$current_state_version" || \
    die "Refusing state downgrade from ${current_state_version} to ${SCRIPT_VERSION}."
  dpkg --compare-versions "$SCRIPT_VERSION" ge "$current_runtime_version" || \
    die "Refusing managed runtime downgrade from ${current_runtime_version} to ${SCRIPT_VERSION}."

  if [[ "$current_helper_version" == "$SCRIPT_VERSION" &&
        "$current_state_version" == "$SCRIPT_VERSION" &&
        "$current_runtime_version" == "$SCRIPT_VERSION" ]]; then
    log "Installer and managed state are already at ${SCRIPT_VERSION}; no overlay update is required."
    return
  fi

  cat <<EOF
VPN update ${current_state_version} -> ${SCRIPT_VERSION}
Settings, clients, credentials, certificates, SSH and firewall are preserved.
EOF
  require_confirmation

  set_step 'existing installation validation'
  sing-box check -c "$CONFIG_FILE" >/dev/null
  systemctl is-active --quiet sing-box.service || die 'sing-box must be active before an overlay update.'
  validate_client_database "$CLIENTS_FILE"
  prepare_upgrade_transaction

  set_step 'Hysteria2 UDP socket-buffer ceilings'
  configure_udp_buffer_ceilings
  set_step 'certificate renewal hook refresh'
  configure_certificate_hook
  smoke_test_certificate_hook
  set_step 'management helper atomic replacement'
  install_helper
  helper_backup="$LAST_HELPER_BACKUP"
  remove_auto_finalization
  set_step 'managed state version marker'
  write_install_completion_marker
  set_step 'managed server configuration and subscription reconciliation'
  reconcile_managed_runtime
  set_step 'managed runtime version marker'
  write_runtime_version_marker
  set_step 'upgraded runtime health validation'
  if ! "$INSTALLED_HELPER" health >/dev/null 2>&1; then
    restore_installed_helper "$helper_backup" || die 'New helper failed its post-update check and automatic helper rollback also failed.'
    die 'New helper failed its post-update check; the previous helper and version markers will be restored.'
  fi
  UPGRADE_ROLLBACK_ACTIVE=0
  log "Overlay update completed: ${current_state_version} -> ${SCRIPT_VERSION}."
  [[ -z "$helper_backup" ]] || log "Previous helper backup: ${helper_backup}"
}

run_upgrade() {
  require_root
  require_command mkfifo
  require_command tee
  start_install_log
  set_step 'upgrade state and concurrency lock'
  install -d -o root -g root -m 0700 "$STATE_DIR"
  acquire_install_flock
  upgrade_existing_installation
}

run_install() {
  require_root
  require_command mkfifo
  require_command tee
  start_install_log
  set_step 'installation state and concurrency lock'
  install -d -o root -g root -m 0700 "$STATE_DIR"
  acquire_bootstrap_lock
  if command -v flock >/dev/null 2>&1; then
    acquire_install_flock
    release_bootstrap_lock
  fi

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
      require_install_confirmation
      require_command nft
      require_command systemctl
      require_command systemd-run
      set_step 'management helper recovery update'
      install_helper >/dev/null
      set_step 'automatic first-login security finalization'
      configure_auto_finalization
      set_step 'nftables firewall recovery deployment'
      apply_firewall
      cat <<EOF

Firewall reapplied with automatic rollback in five minutes.
Open one interactive SSH session as ${ADMIN_USER}. It will finish the security
setup automatically and then open the normal shell.
EOF
      return
    fi
    log 'Found an interrupted installation; resuming with its validated saved settings.'
  else
    [[ ! -e "$SETTINGS_FILE" ]] || die "${SETTINGS_FILE} exists but is not a readable regular file."
    set_step 'interactive installation settings'
    collect_install_settings
  fi
  show_plan
  require_install_confirmation

  set_step 'bootstrap command availability'
  require_command apt-get
  require_command dpkg

  set_step 'operating system compatibility'
  preflight_os
  set_step 'hardware and system runtime compatibility'
  preflight_hardware_and_runtime
  set_step 'storage capacity'
  preflight_disk
  set_step 'Debian/Ubuntu dependency installation'
  install_base_packages
  if (( BOOTSTRAP_LOCK_OWNED == 1 )); then
    acquire_install_flock
    release_bootstrap_lock
  fi
  set_step 'required command availability'
  require_command flock
  require_command gpg
  require_command ip
  require_command jq
  require_command nft
  require_command openssl
  require_command ss
  require_command ssh-keygen
  require_command systemctl
  require_command systemd-run
  set_step 'public IPv4 validation'
  preflight_public_ip
  set_step 'port availability'
  preflight_ports
  set_step 'administrator public-key validation'
  preflight_key
  set_step 'TLS domain DNS validation'
  verify_dns
  set_step 'REALITY target audit and selection'
  if (( REALITY_TARGET_AUDITED == 0 )); then
    select_audited_reality_target_for_install
  else
    log "REALITY target ${REALITY_TARGET} was already audited during initial settings."
  fi
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
  write_runtime_version_marker
  set_step 'automatic first-login security finalization'
  configure_auto_finalization

  cat <<EOF

Installation complete.

Keep this terminal open. In a new terminal, log in once:
  ssh -p ${SSH_PORT} ${ADMIN_USER}@${SERVER_IPV4}

That login finalizes the firewall and key-only SSH automatically.
Then run:
  vpn health
  vpn show ${INITIAL_CLIENT_NAME}
EOF
}
