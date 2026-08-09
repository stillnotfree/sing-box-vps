require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this command as root (sudo).'
}

require_confirmation() {
  local answer
  (( ASSUME_YES == 1 )) && return
  interactive_stdin || cli_error 'Mutating non-interactive commands require --yes.'
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || cancel_command
}

require_install_confirmation() {
  local answer
  (( ASSUME_YES == 1 )) && return
  interactive_stdin || die 'Non-interactive installation requires --yes.'
  read -r -p '[Step 10 / 10] Install now? [Y/n] ' answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] || cancel_command
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

domain_is_valid() {
  local value="$1" label
  local -a labels=()
  (( ${#value} <= 253 )) || return 1
  [[ "$value" == *.* && "$value" != *..* ]] || return 1
  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_domain() {
  domain_is_valid "$1" || die "Invalid fully qualified domain: $1"
}

email_is_valid() {
  local value="$1" domain
  [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || return 1
  domain="${value##*@}"
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  case "$domain" in
    example.com|example.net|example.org|test|invalid|localhost|example|\
    *.test|*.invalid|*.localhost|*.example)
      return 1
      ;;
  esac
}

validate_email() {
  email_is_valid "$1" || \
    die 'Provide a real reachable ACME email; reserved example/test domains are not accepted.'
}

ipv4_is_valid() {
  local value="$1" octet
  local -a octets=()
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

validate_ipv4() {
  ipv4_is_valid "$1" || die "Invalid IPv4 address: $1"
}

admin_user_is_valid() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != "root" ]]
}

validate_admin_user() {
  admin_user_is_valid "$1" || \
    die 'Admin user must be a lower-case Debian account name other than root (maximum 32 characters).'
}

ssh_port_is_valid() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 )) || return 1
  [[ "$1" != "80" && "$1" != "443" && "$1" != "$SUBSCRIPTION_PORT" ]]
}

validate_ssh_port() {
  ssh_port_is_valid "$1" || \
    die "SSH port must be 1-65535 and cannot be 80, 443, or ${SUBSCRIPTION_PORT}."
}

validate_emoji() {
  [[ -n "$1" && ${#1} -le 16 && "$1" != *[[:cntrl:]]* ]] || \
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

hy2_obfs_mode_is_supported() {
  local value="$1" item
  for item in "${SUPPORTED_HY2_OBFS_MODES[@]}"; do
    [[ "$value" == "$item" ]] && return 0
  done
  return 1
}

validate_hy2_obfs_mode() {
  hy2_obfs_mode_is_supported "$1" || die \
    "Unsupported Hysteria2 obfuscation mode: $1 (supported: off, salamander)."
}

select_hy2_obfs_mode() {
  local variable="$1" answer selected
  interactive_stdin || die 'An obfuscation mode is required in non-interactive mode.'
  cat <<'EOF'
Select the Hysteria2 obfuscation mode:
  1) off         — native QUIC/HTTP/3 appearance (default)
  2) salamander  — password-based UDP obfuscation for networks that filter QUIC

This is a global server setting. Every Hysteria2 client must refresh its
subscription after a change. Use Salamander only when testing shows that native
Hysteria2 is filtered or throttled on the affected network.
EOF
  while true; do
    read -r -p 'Hysteria2 obfuscation [1]: ' answer
    answer="${answer:-1}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      1|off) selected="off"; break ;;
      2|salamander) selected="salamander"; break ;;
      *) warn 'Choose 1/off or 2/salamander.' ;;
    esac
  done
  printf -v "$variable" '%s' "$selected"
}

select_client_fingerprint() {
  local variable="$1" answer selected
  interactive_stdin || die 'A fingerprint value is required in non-interactive mode.'
  cat <<'EOF'
Select the client TLS fingerprint written to REALITY subscriptions:
  1) chrome   — broad compatibility; default profile
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
  while true; do
    read -r -p '[Step 9 / 10] Fingerprint [1]: ' answer
    answer="${answer:-1}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      1|chrome) selected="chrome"; break ;;
      2|firefox) selected="firefox"; break ;;
      3|safari) selected="safari"; break ;;
      4|ios) selected="ios"; break ;;
      5|android) selected="android"; break ;;
      6|edge) selected="edge"; break ;;
      7|360) selected="360"; break ;;
      8|qq) selected="qq"; break ;;
      9|random) selected="random"; break ;;
      *) warn 'Choose a number from 1 to 9 or enter one of the displayed names.' ;;
    esac
  done
  printf -v "$variable" '%s' "$selected"
}

select_country_emoji() {
  local variable="$1" answer selected
  interactive_stdin || die 'A country emoji is required in non-interactive mode.'
  cat <<'EOF'
Select the VPS location used in generated profile names:
  1) 🇩🇪  Germany
  2) 🇳🇱  Netherlands
  3) 🇫🇮  Finland
  4) 🇸🇪  Sweden
  5) 🇱🇻  Latvia
  6) 🇱🇹  Lithuania
  7) 🇫🇷  France
  8) 🇺🇸  United States
  9) 🌐  Other / neutral
EOF
  while true; do
    read -r -p '[Step 8 / 10] Location [9]: ' answer
    answer="${answer:-9}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    case "$answer" in
      1) selected="🇩🇪"; break ;;
      2) selected="🇳🇱"; break ;;
      3) selected="🇫🇮"; break ;;
      4) selected="🇸🇪"; break ;;
      5) selected="🇱🇻"; break ;;
      6) selected="🇱🇹"; break ;;
      7) selected="🇫🇷"; break ;;
      8) selected="🇺🇸"; break ;;
      9) selected="🌐"; break ;;
      *) warn 'Choose a location number from 1 to 9.' ;;
    esac
  done
  printf -v "$variable" '%s' "$selected"
}

public_key_text_is_valid() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
  [[ "$1" == ssh-ed25519\ * || "$1" == sk-ssh-ed25519@openssh.com\ * ]]
}

validate_public_key_text() {
  public_key_text_is_valid "$1" || \
    die 'Use exactly one Ed25519 OpenSSH public-key line (ssh-ed25519 or sk-ssh-ed25519).'
}

interactive_stdin() {
  [[ -t 0 ]]
}

prompt_value() {
  local variable="$1" prompt="$2" default_value="${3:-}" validator="$4" current answer
  current="${!variable:-}"
  [[ -n "$current" ]] && return
  interactive_stdin || die "Missing required option: ${prompt}"
  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "${prompt} [${default_value}]: " answer
      answer="${answer:-$default_value}"
    else
      read -r -p "${prompt}: " answer
    fi
    if "$validator" "$answer"; then
      printf -v "$variable" '%s' "$answer"
      return
    fi
    warn "Invalid value for ${prompt}. Try again."
  done
}

collect_install_settings() {
  local detected_ip=""
  if command -v ip >/dev/null 2>&1; then
    detected_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
      !found {
        for (i=1; i<=NF; i++) {
          if ($i == "src" && (i + 1) <= NF) {
            address=$(i + 1)
            found=1
            break
          }
        }
      }
      END { if (found) print address }
    ')"
  fi
  prompt_value ADMIN_USER '[Step 1 / 10] Administrative user' 'vpnadmin' admin_user_is_valid
  prompt_value ADMIN_PUBLIC_KEY '[Step 2 / 10] OpenSSH public key (one line)' '' public_key_text_is_valid
  prompt_value SERVER_IPV4 '[Step 3 / 10] Public VPS IPv4' "$detected_ip" ipv4_is_valid
  prompt_value TLS_DOMAIN '[Step 4 / 10] TLS domain whose A record points to this VPS' '' domain_is_valid
  prompt_value ACME_EMAIL '[Step 5 / 10] ACME email' '' email_is_valid
  prompt_value SSH_PORT '[Step 6 / 10] Current SSH port' '22' ssh_port_is_valid
  if [[ -z "$REALITY_TARGET" ]]; then
    printf '%s\n' \
      'No REALITY target is universally safe. Prefer a TLS 1.3 / HTTP/2 hostname' \
      'reachable from this VPS and, where practical, topologically close to it.' \
      'The installer also checks the Aparecium-class post-handshake signal.'
  fi
  prompt_value REALITY_TARGET '[Step 7 / 10] REALITY target (explicit choice required)' '' domain_is_valid
  if command -v openssl >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    select_audited_reality_target_for_install
  else
    printf 'REALITY target recorded. The audit will run after dependency installation and before settings are saved.\n'
  fi
  if [[ -z "$COUNTRY_EMOJI" ]]; then
    if interactive_stdin; then
      select_country_emoji COUNTRY_EMOJI
    else
      COUNTRY_EMOJI="🌐"
    fi
  fi
  if [[ -z "$CLIENT_FINGERPRINT" ]]; then
    if interactive_stdin; then
      select_client_fingerprint CLIENT_FINGERPRINT
    else
      CLIENT_FINGERPRINT="$DEFAULT_CLIENT_FINGERPRINT"
    fi
  fi
  CLIENT_FINGERPRINT="$(printf '%s' "$CLIENT_FINGERPRINT" | tr '[:upper:]' '[:lower:]')"
  HY2_OBFS_MODE="${HY2_OBFS_MODE:-$DEFAULT_HY2_OBFS_MODE}"

  validate_admin_user "$ADMIN_USER"
  validate_public_key_text "$ADMIN_PUBLIC_KEY"
  validate_ipv4 "$SERVER_IPV4"
  validate_domain "$TLS_DOMAIN"
  validate_email "$ACME_EMAIL"
  validate_ssh_port "$SSH_PORT"
  validate_domain "$REALITY_TARGET"
  validate_emoji "$COUNTRY_EMOJI"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
  validate_hy2_obfs_mode "$HY2_OBFS_MODE"
}

render_settings() {
  local candidate="$1"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
  validate_hy2_obfs_mode "$HY2_OBFS_MODE"
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
    --arg hy2_obfs_mode "$HY2_OBFS_MODE" \
    '{schema_version: 1, admin_user: $admin_user, admin_public_key: $admin_public_key,
      server_ipv4: $server_ipv4, tls_domain: $tls_domain, acme_email: $acme_email,
      ssh_port: $ssh_port, reality_target: $reality_target,
      country_emoji: $country_emoji, client_fingerprint: $client_fingerprint,
      hy2_obfs_mode: $hy2_obfs_mode}' >"$candidate"
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
  CLIENT_FINGERPRINT="$(jq -er '.client_fingerprint' "$SETTINGS_FILE")"
  HY2_OBFS_MODE="$(jq -er '.hy2_obfs_mode' "$SETTINGS_FILE")"

  validate_admin_user "$ADMIN_USER"
  validate_public_key_text "$ADMIN_PUBLIC_KEY"
  validate_ipv4 "$SERVER_IPV4"
  validate_domain "$TLS_DOMAIN"
  validate_email "$ACME_EMAIL"
  validate_ssh_port "$SSH_PORT"
  validate_domain "$REALITY_TARGET"
  validate_emoji "$COUNTRY_EMOJI"
  validate_client_fingerprint "$CLIENT_FINGERPRINT"
  validate_hy2_obfs_mode "$HY2_OBFS_MODE"
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
  awk '
    /^readonly SCRIPT_VERSION="[^"]*"$/ && !found {
      value=$0
      sub(/^readonly SCRIPT_VERSION="/, "", value)
      sub(/"$/, "", value)
      found=1
    }
    END { if (found) print value }
  ' "$file"
}

project_name_from_file() {
  local file="$1"
  awk '
    /^readonly PROJECT_NAME="[^"]*"$/ && !found {
      value=$0
      sub(/^readonly PROJECT_NAME="/, "", value)
      sub(/"$/, "", value)
      found=1
    }
    END { if (found) print value }
  ' "$file"
}

installed_helper_version() {
  if [[ -r "$INSTALLED_HELPER" ]]; then
    script_version_from_file "$INSTALLED_HELPER"
  fi
}

installed_state_version() {
  if [[ -r "$INSTALL_COMPLETE_FILE" ]]; then
    awk '
      !found && match($0, /(^|[[:space:]])version=[^[:space:]]+/) {
        value=substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*version=/, "", value)
        found=1
      }
      END { if (found) print value }
    ' "$INSTALL_COMPLETE_FILE"
  fi
}

sing_box_version_is_supported() {
  local version="$1"
  [[ -n "$version" ]] &&
    dpkg --compare-versions "$version" ge "$SING_BOX_MIN_VERSION" &&
    dpkg --compare-versions "$version" lt "$SING_BOX_MAX_EXCLUSIVE"
}

require_supported_sing_box_version() {
  local version="$1"
  sing_box_version_is_supported "$version" || \
    die "Unsupported sing-box version ${version:-missing}. This installer supports >= ${SING_BOX_MIN_VERSION} and < ${SING_BOX_MAX_EXCLUSIVE}; upgrade the installer before crossing a core compatibility boundary."
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
