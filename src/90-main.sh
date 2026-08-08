main() {
  parse_args "$@"
  case "$COMMAND" in
    plan|check|install|upgrade|update|self-update|health|finalize|confirm-firewall|rollback-firewall|lockdown-ssh|client-add|client-show|client-delete|client-list|audit-target|set-target|set-fingerprint|set-obfs|help)
      ;;
    *)
      usage >&2
      die "Unknown command: $COMMAND"
      ;;
  esac
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
    health)
      if (( VERBOSE == 1 )); then
        health_details || exit 1
      else
        health_check || exit 1
      fi
      ;;
    finalize)
      finalize_installation
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
    audit-target)
      audit_reality_target || exit 1
      ;;
    set-target)
      set_reality_target
      ;;
    set-fingerprint)
      set_client_fingerprint
      ;;
    set-obfs)
      set_hy2_obfs
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
