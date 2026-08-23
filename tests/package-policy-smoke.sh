#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/install-sing-box-server.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
distro_macro="\${distro_codename}"

debian_config="${work}/debian.conf"
ubuntu_config="${work}/ubuntu.conf"
render_unattended_upgrades_config "$debian_config" debian
render_unattended_upgrades_config "$ubuntu_config" ubuntu

for config in "$debian_config" "$ubuntu_config"; do
  grep -Fxq '#clear Unattended-Upgrade::Origins-Pattern;' "$config"
  grep -Fxq '#clear Unattended-Upgrade::Allowed-Origins;' "$config"
  grep -Fq 'APT::Periodic::Update-Package-Lists "1";' "$config"
  grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' "$config"
  grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' "$config"
done
grep -Fq "origin=Debian,codename=${distro_macro},label=Debian-Security" \
  "$debian_config"
grep -Fq "origin=Debian,codename=${distro_macro}-security,label=Debian-Security" \
  "$debian_config"
[[ "$(<"$debian_config")" != *'label=Debian"'* ]]
grep -Fq "origin=Ubuntu,archive=${distro_macro}-security,label=Ubuntu" \
  "$ubuntu_config"
[[ "$(<"$ubuntu_config")" != *"archive=${distro_macro}-updates"* ]]

debian_dump="$(printf '%s\n' \
  'APT::Periodic::Update-Package-Lists "1";' \
  'APT::Periodic::Unattended-Upgrade "1";' \
  "Unattended-Upgrade::Origins-Pattern:: \"origin=Debian,codename=${distro_macro},label=Debian-Security\";" \
  "Unattended-Upgrade::Origins-Pattern:: \"origin=Debian,codename=${distro_macro}-security,label=Debian-Security\";" \
  'Unattended-Upgrade::Automatic-Reboot "false";')"
ubuntu_dump="$(printf '%s\n' \
  'APT::Periodic::Update-Package-Lists "1";' \
  'APT::Periodic::Unattended-Upgrade "1";' \
  "Unattended-Upgrade::Origins-Pattern:: \"origin=Ubuntu,archive=${distro_macro}-security,label=Ubuntu\";" \
  'Unattended-Upgrade::Automatic-Reboot "false";')"
unattended_policy_dump_is_security_only debian "$debian_dump"
unattended_policy_dump_is_security_only ubuntu "$ubuntu_dump"

ordinary_debian_dump="${debian_dump}"$'\n'"Unattended-Upgrade::Origins-Pattern:: \"origin=Debian,codename=${distro_macro},label=Debian\";"
if unattended_policy_dump_is_security_only debian "$ordinary_debian_dump"; then
  printf 'Ordinary Debian updates unexpectedly passed the security-only policy.\n' >&2
  exit 1
fi
[[ "$UNATTENDED_POLICY_REASON" == 'a non-security Debian origin is allowed' ]]

ordinary_ubuntu_dump="${ubuntu_dump}"$'\n'"Unattended-Upgrade::Allowed-Origins:: \"Ubuntu:${distro_macro}\";"
if unattended_policy_dump_is_security_only ubuntu "$ordinary_ubuntu_dump"; then
  printf 'Ordinary Ubuntu updates unexpectedly passed the security-only policy.\n' >&2
  exit 1
fi
[[ "$UNATTENDED_POLICY_REASON" == 'a non-security Ubuntu origin is allowed' ]]
ubuntu_updates_dump="${ubuntu_dump}"$'\n'"Unattended-Upgrade::Origins-Pattern:: \"origin=Ubuntu,archive=${distro_macro}-updates,label=Ubuntu\";"
if unattended_policy_dump_is_security_only ubuntu "$ubuntu_updates_dump"; then
  printf 'Ubuntu updates pocket unexpectedly passed the security-only policy.\n' >&2
  exit 1
fi

repeated_config="${work}/repeated.conf"
render_unattended_upgrades_config "$repeated_config" debian
cmp -s "$debian_config" "$repeated_config"

(
  apt-config() { printf '%s\n' "$debian_dump"; }
  systemctl() { return 0; }
  apt-mark() { printf 'sing-box\n'; }
  health_reset_state
  health_collect_update_policy debian
  [[ "$HEALTH_SECURITY_UPDATES_STATE" == PASS ]]
  [[ "$HEALTH_SECURITY_UPDATES_DETAIL" == \
    'automatic · security-only · no automatic reboot' ]]
  [[ "$HEALTH_CORE_UPDATES_STATE" == PASS ]]
  [[ "$HEALTH_CORE_UPDATES_DETAIL" == \
    'sing-box apt-held · update through vpn update' ]]
)

(
  apt-config() {
    printf '%s\n' "${debian_dump/APT::Periodic::Unattended-Upgrade \"1\"/APT::Periodic::Unattended-Upgrade \"0\"}"
  }
  systemctl() { return 0; }
  apt-mark() { :; }
  health_reset_state
  health_collect_update_policy debian
  [[ "$HEALTH_SECURITY_UPDATES_STATE" == WARN ]]
  [[ "$HEALTH_SECURITY_UPDATES_DETAIL" == 'unattended upgrades are disabled' ]]
  [[ "$HEALTH_CORE_UPDATES_STATE" == FAIL ]]
  [[ "$HEALTH_CORE_UPDATES_DETAIL" == 'sing-box apt hold unavailable' ]]
)

configure_body="$(declare -f configure_unattended_upgrades)"
[[ "$configure_body" == *'apt-config dump'* ]]
[[ "$configure_body" == *'systemctl enable --now apt-daily.timer apt-daily-upgrade.timer'* ]]
[[ "$configure_body" == *'systemctl is-enabled --quiet apt-daily.timer'* ]]
[[ "$configure_body" == *'systemctl is-active --quiet apt-daily-upgrade.timer'* ]]
[[ "$configure_body" != *'50unattended-upgrades'* ]]

apt_install_body="$(declare -f apt_install_with_lock_timeout)"
base_install_body="$(declare -f install_base_packages)"
sing_box_install_body="$(declare -f install_sing_box)"
lock_option="DPkg::Lock::Timeout=\${APT_DPKG_LOCK_TIMEOUT_SECONDS}"
[[ "$APT_DPKG_LOCK_TIMEOUT_SECONDS" == '300' ]]
[[ "$apt_install_body" == *"$lock_option"* ]]
[[ "$base_install_body" == *'apt_install_with_lock_timeout -y --no-install-recommends'* ]]
[[ "$sing_box_install_body" == *'apt_install_with_lock_timeout -y --allow-change-held-packages'* ]]

(
  apt_calls=()
  apt-get() {
    apt_calls=("$@")
    return 37
  }
  if apt_install_with_lock_timeout -y --no-install-recommends package-under-test; then
    printf 'A mocked APT failure unexpectedly reported success.\n' >&2
    exit 1
  else
    apt_status=$?
  fi
  [[ "$apt_status" == 37 ]]
  [[ "${apt_calls[0]}" == '-o' ]]
  [[ "${apt_calls[1]}" == "DPkg::Lock::Timeout=${APT_DPKG_LOCK_TIMEOUT_SECONDS}" ]]
  [[ "${apt_calls[2]}" == 'install' ]]
)

package_source="$(<"${repo_root}/src/30-preflight-packages.sh")"
[[ "$package_source" != *'/var/lib/dpkg/lock'* ]]
[[ "$package_source" != *'lock-frontend'* ]]
[[ "$package_source" != *'pkill'* ]]
[[ "$package_source" != *'killall'* ]]
[[ "$package_source" != *'systemctl stop apt-daily'* ]]
[[ "$package_source" != *'systemctl disable apt-daily'* ]]
[[ "$package_source" != *'systemctl stop unattended-upgrades'* ]]
[[ "$package_source" != *'systemctl disable unattended-upgrades'* ]]

staging_body="$(declare -f prepare_apt_download_dir)"
download_body="$(declare -f download_sing_box_package)"
install_body="$(declare -f install_sing_box)"
[[ "$staging_body" == *'install -d -o root -g root -m 0711'* ]]
[[ "$staging_body" == *'chown _apt:root'* ]]
[[ "$staging_body" == *'chmod 0700'* ]]
[[ "$staging_body" != *'0777'* ]]
[[ "$staging_body" != *'chmod 777'* ]]
[[ "$download_body" == *"apt-get download \"sing-box=\${version}\""* ]]
[[ "$download_body" != *'APT::Sandbox::User'* ]]
[[ "$install_body" == *"\"sing-box=\${candidate}\""* ]]
[[ "$install_body" == *'ensure_sing_box_package_hold'* ]]

# A package update must not report success when apt-mark hold has not become a
# verified postcondition. The failed case must restore the old package.
(
  old_package="${work}/sing-box-old.deb"
  new_package="${work}/sing-box-new.deb"
  installed_marker="${work}/installed-package"
  printf old >"$old_package"
  printf new >"$new_package"
  if (
    apt-mark() {
      case "$1" in
        hold) return 0 ;;
        showhold) return 0 ;;
        *) return 1 ;;
      esac
    }
    dpkg() {
      if [[ "$1" == --force-confold && "$2" == -i ]]; then
        cp "$3" "$installed_marker"
        return 0
      fi
      return 0
    }
    sing-box() { return 0; }
    systemctl() { return 0; }
    prune_sing_box_packages() { :; }
    log() { :; }
    activate_sing_box_package_update 1.13.16 1.13.17 \
      "$new_package" "$old_package" >/dev/null 2>&1
  ); then
    printf 'Missing apt hold unexpectedly reported clean success.\n' >&2
    exit 1
  fi
  cmp -s "$old_package" "$installed_marker"
)

(
  held=0
  old_package="${work}/sing-box-old-held.deb"
  new_package="${work}/sing-box-new-held.deb"
  installed_marker="${work}/installed-held-package"
  printf old >"$old_package"
  printf new >"$new_package"
  apt-mark() {
    case "$1" in
      hold) held=1; return 0 ;;
      showhold) (( held == 1 )) && printf 'sing-box\n' ;;
      *) return 1 ;;
    esac
  }
  dpkg() {
    if [[ "$1" == --force-confold && "$2" == -i ]]; then
      cp "$3" "$installed_marker"
      return 0
    fi
    return 0
  }
  sing-box() { return 0; }
  systemctl() { return 0; }
  prune_sing_box_packages() { :; }
  log() { :; }
  activate_sing_box_package_update 1.13.16 1.13.17 \
    "$new_package" "$old_package" >/dev/null
  cmp -s "$new_package" "$installed_marker"
  (( held == 1 ))
)

help_output="$(usage)"
[[ "$help_output" != *'vpn list'* ]]
[[ "$help_output" != *'vpn status'* ]]
grep -Fq 'vpn show [NAME]' <<<"$help_output"
for removed_command in list status; do
  trap - ERR
  if removed_output="$(bash "${repo_root}/install-sing-box-server.sh" "$removed_command" 2>&1)"; then
    printf 'Removed command %s unexpectedly succeeded.\n' "$removed_command" >&2
    exit 1
  fi
  trap on_error ERR
  grep -Fq "Unknown command: ${removed_command}" <<<"$removed_output"
done

printf 'Package and update policy smoke test: PASS\n'
