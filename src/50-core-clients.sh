validate_client_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z][A-Za-z0-9._-]{0,31}$ ]] || \
    cli_error 'Client name must start with a letter and contain only A-Z, a-z, 0-9, dot, underscore, or hyphen (maximum 32 characters).'
}

require_client_name_available() {
  local name="$1" existing_client="$2"
  [[ -z "$existing_client" ]] || \
    cli_error "Client ${name} already exists (names are case-insensitive)."
}

require_existing_client() {
  local name="$1" existing_client="$2"
  [[ -n "$existing_client" ]] || cli_error "Client ${name} does not exist."
}

append_client_to_database() {
  local database="$1" client="$2" output="$3"
  jq --argjson client "$client" '.clients += [$client]' "$database" >"$output"
  validate_client_database "$output"
}

remove_client_from_database() {
  local database="$1" name="$2" output="$3"
  jq --arg name "$name" \
    '.clients |= map(select((.name | ascii_downcase) != ($name | ascii_downcase)))' \
    "$database" >"$output"
  validate_client_database "$output"
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
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{8}$ ]] || die 'Invalid stored REALITY short ID.'

  : "${HY2_OBFS_PASSWORD:?missing Hysteria2 obfuscation secret}"
  [[ "$HY2_OBFS_PASSWORD" =~ ^[0-9a-f]{48}$ ]] || die 'Invalid stored Hysteria2 obfuscation secret.'
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
  local vless_users_json hy2_users_json hy2_obfs_block=""
  generate_or_load_server_secrets
  validate_client_database "$database"
  validate_hy2_obfs_mode "$HY2_OBFS_MODE"

  vless_users_json="$(jq '[.clients[] | {
    name: .name,
    uuid: .vless_uuid,
    flow: "xtls-rprx-vision"
  }]' "$database")"
  hy2_users_json="$(jq '[.clients[] | {
    name: .name,
    password: .hy2_password
  }]' "$database")"

  if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
    hy2_obfs_block="$(cat <<EOF
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
EOF
)"
  fi

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
${hy2_obfs_block}
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
    "rules": [
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "ip_cidr": [
          "0.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "::/128",
          "::1/128",
          "fe80::/10"
        ],
        "action": "reject"
      }
    ],
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
  local installed_core
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
  installed_core="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  require_supported_sing_box_version "$installed_core"
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

reconcile_managed_runtime() {
  local candidate_config candidate_subscriptions config_backup subscriptions_backup
  local failed=0 restore_failed=0

  new_temp_dir
  candidate_config="${TMP_DIR}/config.candidate.json"
  candidate_subscriptions="${TMP_DIR}/subscriptions.candidate"
  config_backup="${TMP_DIR}/config.before.json"
  subscriptions_backup="${TMP_DIR}/subscriptions.before"

  build_sing_box_config "$CLIENTS_FILE" "$candidate_config"
  render_subscription_tree "$CLIENTS_FILE" "$candidate_subscriptions"
  install -o root -g root -m 0600 "$CONFIG_FILE" "$config_backup"
  install -d -o root -g root -m 0700 "$subscriptions_backup"
  cp -a -- "${SUBSCRIPTION_ROOT}/." "${subscriptions_backup}/"

  install -o root -g sing-box -m 0640 "$candidate_config" "${CONFIG_FILE}.new"
  begin_mutation_commit
  mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE" || failed=1
  if (( failed == 0 )); then
    activate_subscription_tree "$candidate_subscriptions" || failed=1
  fi
  if (( failed == 0 )); then
    systemctl restart sing-box.service || failed=1
    systemctl is-active --quiet sing-box.service || failed=1
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
    subscription_service_healthy || failed=1
  fi

  if (( failed == 1 )); then
    install -o root -g sing-box -m 0640 "$config_backup" "${CONFIG_FILE}.rollback" || restore_failed=1
    mv -f -- "${CONFIG_FILE}.rollback" "$CONFIG_FILE" || restore_failed=1
    activate_subscription_tree "$subscriptions_backup" || restore_failed=1
    systemctl restart sing-box.service || restore_failed=1
    systemctl is-active --quiet sing-box.service || restore_failed=1
    if (( restore_failed == 1 )); then
      die "Managed runtime reconciliation and its rollback both failed; recovery files are preserved in ${TMP_DIR}."
    fi
    finish_mutation_commit
    die 'Managed runtime reconciliation failed; the previous server configuration and subscriptions were restored.'
  fi

  finish_mutation_commit
  log 'Managed sing-box configuration and all subscription formats were reconciled with this installer release.'
}

client_add() {
  local candidate uuid hy2 token client
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  acquire_operation_lock
  require_client_runtime
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  require_client_name_available "$CLIENT_NAME" "$(find_client_json "$CLIENT_NAME")"

  CURRENT_STEP='client add transaction'
  new_temp_dir
  candidate="${TMP_DIR}/clients.candidate.json"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  hy2="$(openssl rand -hex 24)"
  token="$(openssl rand -hex 32)"
  client="$(jq -cn \
    --arg name "$CLIENT_NAME" \
    --arg uuid "$uuid" \
    --arg hy2 "$hy2" \
    --arg token "$token" \
    --arg created "$(date --iso-8601=seconds)" \
    '{
      name: $name,
      vless_uuid: $uuid,
      hy2_password: $hy2,
      subscription_token: $token,
      created_at: $created
    }')"
  append_client_to_database "$CLIENTS_FILE" "$client" "$candidate"
  apply_client_database "$candidate"
  log "Client ${CLIENT_NAME} added with independent VLESS and Hysteria2 credentials."
  client="$(find_client_json "$CLIENT_NAME")"
  show_client_material "$client"
}

build_client_uris() {
  local client="$1" uuid hy2 reality_label hy2_label hy2_query
  generate_or_load_server_secrets
  validate_hy2_obfs_mode "$HY2_OBFS_MODE"
  EXPORTED_CLIENT_NAME="$(jq -r '.name' <<<"$client")"
  uuid="$(jq -r '.vless_uuid' <<<"$client")"
  hy2="$(jq -r '.hy2_password' <<<"$client")"
  reality_label="$(jq -rn --arg value "${COUNTRY_EMOJI} Reality" '$value | @uri')"
  hy2_label="$(jq -rn --arg value "${COUNTRY_EMOJI} Hysteria2" '$value | @uri')"
  hy2_query="sni=${TLS_DOMAIN}"
  if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
    hy2_query+="&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}"
  fi
  VLESS_URI="vless://${uuid}@${SERVER_IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET}&fp=${CLIENT_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${reality_label}"
  HY2_URI="hysteria2://${hy2}@${TLS_DOMAIN}:443/?${hy2_query}#${hy2_label}"
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
    --arg hy2_obfs_mode "$HY2_OBFS_MODE" \
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
          "packet-encoding": "xudp",
          flow: "xtls-rprx-vision",
          servername: $target,
          "client-fingerprint": $fingerprint,
          "reality-opts": {
            "public-key": $public_key,
            "short-id": $short_id
          }
        },
        ({
          name: $hy2_name,
          type: "hysteria2",
          server: $tls_domain,
          port: 443,
          password: $hy2_password,
          sni: $tls_domain,
          "skip-cert-verify": false
        } + if $hy2_obfs_mode == "salamander" then {
          obfs: "salamander",
          "obfs-password": $hy2_obfs_password
        } else {} end)
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
  if ! install -d -o root -g root -m 0755 "$(dirname "$SUBSCRIPTION_ROOT")"; then
    return 1
  fi
  if ! rm -rf -- "$new_root" "$old_root"; then
    return 1
  fi
  if ! install -d -o root -g www-data -m 0750 "$new_root"; then
    rm -rf -- "$new_root"
    return 1
  fi
  while IFS= read -r -d '' file; do
    if ! install -o root -g www-data -m 0640 "$file" "${new_root}/$(basename "$file")"; then
      rm -rf -- "$new_root"
      return 1
    fi
  done < <(find "$staged" -maxdepth 1 -type f -print0)

  if [[ -d "$SUBSCRIPTION_ROOT" ]]; then
    if ! mv -- "$SUBSCRIPTION_ROOT" "$old_root"; then
      rm -rf -- "$new_root"
      return 1
    fi
  fi
  if ! mv -- "$new_root" "$SUBSCRIPTION_ROOT"; then
    [[ ! -d "$old_root" ]] || mv -- "$old_root" "$SUBSCRIPTION_ROOT"
    rm -rf -- "$new_root"
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
    ~*(sing-box|singbox|hiddify|happ|nekobox|xray|v2ray|v2rayn|v2rayng|shadowrocket) links;
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
    --fail --silent --show-error --connect-timeout 10 --max-time 15 \
    --resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:127.0.0.1" \
    --user-agent 'Shadowrocket' --config -)" || return 1
  decoded_links="$(printf '%s' "$links_payload" | base64 --decode 2>/dev/null)" || return 1
  grep -Fq 'vless://' <<<"$decoded_links" || return 1
  grep -Fq 'hysteria2://' <<<"$decoded_links" || return 1
  grep -Fq "&fp=${CLIENT_FINGERPRINT}&" <<<"$decoded_links" || return 1
  if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
    grep -Fq '&obfs=salamander&obfs-password=' <<<"$decoded_links" || return 1
  elif grep -Fq '&obfs=' <<<"$decoded_links"; then
    return 1
  fi
  mihomo_payload="$(printf 'url = "%s"\n' "$url" | curl --noproxy '*' \
    --fail --silent --show-error --connect-timeout 10 --max-time 15 \
    --resolve "${TLS_DOMAIN}:${SUBSCRIPTION_PORT}:127.0.0.1" \
    --user-agent 'FlClash' --config -)" || return 1
  jq -e --arg fingerprint "$CLIENT_FINGERPRINT" --arg hy2_obfs_mode "$HY2_OBFS_MODE" \
    '(.proxies | length == 2) and
     (any(.proxies[]; .type == "vless" and .["client-fingerprint"] == $fingerprint)) and
     (if $hy2_obfs_mode == "salamander" then
        any(.proxies[]; .type == "hysteria2" and .obfs == "salamander" and
          ((.["obfs-password"] // "") | length > 0))
      else
        all(.proxies[]; .type != "hysteria2" or
          ((has("obfs") or has("obfs-password")) | not))
      end)' \
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

  print_title 'VPN client — private material'
  printf '  %-14s %s\n' 'Client' "$EXPORTED_CLIENT_NAME"
  print_section 'Subscription'
  printf '%s\n' "$subscription_url"
  print_section 'QR code'
  printf '%s\n' 'Scan as a subscription, not as a single server:'
  printf '%s' "$subscription_url" | qrencode -t ANSIUTF8
  print_section 'Direct fallback links'
  printf '%s\n%s\n' "$VLESS_URI" "$HY2_URI"
  print_section 'Mihomo fallback'
  printf '%s/mihomo\n' "$subscription_url"
  printf '\n'
  style_text '1;31' 'PRIVATE: subscription URLs and direct links contain client credentials.'
  printf '\nDo not publish them in Git, screenshots, logs, or chats.\n'
}

client_show() {
  local client
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  exec 9>"$CLIENT_LOCK_FILE"
  flock -s 9
  client="$(find_client_json "$CLIENT_NAME")"
  require_existing_client "$CLIENT_NAME" "$client"
  show_client_material "$client"
}

client_delete() {
  local candidate stored_name count existing_client
  require_client_runtime
  validate_client_name "$CLIENT_NAME"
  acquire_operation_lock
  require_client_runtime
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  existing_client="$(find_client_json "$CLIENT_NAME")"
  require_existing_client "$CLIENT_NAME" "$existing_client"
  stored_name="$(jq -r '.name' <<<"$existing_client")"
  count="$(jq '.clients | length' "$CLIENTS_FILE")"
  (( count > 1 )) || cli_error 'Refusing to delete the last VPN client. Add a replacement client first.'

  CURRENT_STEP='client delete transaction'
  new_temp_dir
  candidate="${TMP_DIR}/clients.candidate.json"
  remove_client_from_database "$CLIENTS_FILE" "$stored_name" "$candidate"
  apply_client_database "$candidate"
  log "Client ${stored_name} deleted; its VLESS UUID and Hysteria2 password are no longer accepted."
}

client_list() {
  local name created
  require_client_runtime
  exec 9>"$CLIENT_LOCK_FILE"
  flock -s 9
  print_title 'VPN clients'
  style_text '1' '  CLIENT                           CREATED'
  printf '\n'
  while IFS=$'\t' read -r name created; do
    printf '  %-32s %s\n' "$name" "$created"
  done < <(jq -r '.clients | sort_by(.name | ascii_downcase)[] | [.name, .created_at] | @tsv' "$CLIENTS_FILE")
  printf '\nUse "vpn show NAME" to display private links and QR codes.\n'
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
  local settings_backup config_backup previous_audit_target audit_status=0 failed=0
  require_client_runtime
  domain_is_valid "$NEW_REALITY_TARGET" || \
    cli_error "Invalid fully qualified domain: $NEW_REALITY_TARGET"
  old_target="$REALITY_TARGET"
  if [[ "$NEW_REALITY_TARGET" == "$old_target" ]]; then
    printf 'REALITY target is already %s; nothing changed.\n' "$old_target"
    return
  fi

  previous_audit_target="$AUDIT_TARGET"
  AUDIT_TARGET="$NEW_REALITY_TARGET"
  if audit_reality_target; then
    audit_status=0
  else
    audit_status=$?
  fi
  AUDIT_TARGET="$previous_audit_target"
  if (( audit_status == 2 )); then
    cli_error "REALITY target ${NEW_REALITY_TARGET} failed the shared audit; no changes were made."
  fi

  printf 'REALITY target change: %s -> %s\n' "$old_target" "$NEW_REALITY_TARGET"
  printf 'All client subscriptions will be regenerated; their URLs will stay unchanged.\n'
  if (( audit_status == 1 )); then
    printf 'The target is usable but has the comparison-heuristic warning shown above.\n'
  fi
  require_confirmation

  CURRENT_STEP='REALITY target transaction'
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
  new_temp_dir
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
  NEW_CLIENT_FINGERPRINT="$(printf '%s' "$NEW_CLIENT_FINGERPRINT" | tr '[:upper:]' '[:lower:]')"
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

  CURRENT_STEP='client fingerprint transaction'
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
  new_temp_dir
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
  printf 'If REALITY still fails, run "vpn health --verbose" before changing other settings.\n'
}

restore_hy2_obfs_transaction() {
  local settings_backup="$1" config_backup="$2" subscriptions_backup="$3" old_mode="$4"
  warn 'Hysteria2 obfuscation change failed; restoring the previous server and subscriptions.'
  HY2_OBFS_MODE="$old_mode"
  install -o root -g root -m 0600 "$settings_backup" "${SETTINGS_FILE}.rollback"
  install -o root -g sing-box -m 0640 "$config_backup" "${CONFIG_FILE}.rollback"
  mv -f -- "${SETTINGS_FILE}.rollback" "$SETTINGS_FILE"
  mv -f -- "${CONFIG_FILE}.rollback" "$CONFIG_FILE"
  activate_subscription_tree "$subscriptions_backup" || die 'Subscription rollback failed.'
  sing-box check -c "$CONFIG_FILE" || die 'Restored sing-box configuration validation failed.'
  systemctl restart sing-box.service || die 'Restored sing-box service could not be restarted.'
  systemctl is-active --quiet sing-box.service || die 'Restored sing-box service is inactive.'
  subscription_service_healthy || die 'Restored subscriptions failed their health check.'
}

set_hy2_obfs() {
  local old_mode candidate_settings candidate_config candidate_subscriptions old_subscriptions
  local settings_backup config_backup failed=0
  require_client_runtime

  if [[ -z "$NEW_HY2_OBFS_MODE" ]]; then
    select_hy2_obfs_mode NEW_HY2_OBFS_MODE
  fi
  NEW_HY2_OBFS_MODE="$(printf '%s' "$NEW_HY2_OBFS_MODE" | tr '[:upper:]' '[:lower:]')"
  validate_hy2_obfs_mode "$NEW_HY2_OBFS_MODE"
  old_mode="$HY2_OBFS_MODE"
  if [[ "$NEW_HY2_OBFS_MODE" == "$old_mode" ]]; then
    printf 'Hysteria2 obfuscation is already %s; nothing changed.\n' "$old_mode"
    return
  fi

  printf 'Hysteria2 obfuscation change: %s -> %s\n' "$old_mode" "$NEW_HY2_OBFS_MODE"
  printf 'The Hysteria2 service will restart and all client subscriptions will be regenerated.\n'
  printf 'Subscription URLs will stay unchanged, but every Hysteria2 client must refresh.\n'
  require_confirmation

  CURRENT_STEP='Hysteria2 obfuscation transaction'
  acquire_operation_lock
  load_settings
  require_client_runtime
  old_mode="$HY2_OBFS_MODE"
  if [[ "$NEW_HY2_OBFS_MODE" == "$old_mode" ]]; then
    printf 'Hysteria2 obfuscation became %s while waiting; nothing changed.\n' "$old_mode"
    return
  fi
  exec 9>"$CLIENT_LOCK_FILE"
  flock -x 9
  new_temp_dir
  candidate_settings="${TMP_DIR}/settings.candidate.json"
  candidate_config="${TMP_DIR}/config.candidate.json"
  candidate_subscriptions="${TMP_DIR}/subscriptions.candidate"
  old_subscriptions="${TMP_DIR}/subscriptions.before"
  settings_backup="${TMP_DIR}/settings.before.json"
  config_backup="${TMP_DIR}/config.before.json"

  render_subscription_tree "$CLIENTS_FILE" "$old_subscriptions"
  install -o root -g root -m 0600 "$SETTINGS_FILE" "$settings_backup"
  install -o root -g root -m 0600 "$CONFIG_FILE" "$config_backup"

  HY2_OBFS_MODE="$NEW_HY2_OBFS_MODE"
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
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 || failed=1
    subscription_service_healthy || failed=1
  fi

  if (( failed == 1 )); then
    restore_hy2_obfs_transaction "$settings_backup" "$config_backup" "$old_subscriptions" "$old_mode"
    finish_mutation_commit
    die 'Hysteria2 obfuscation was not changed; the previous state was restored.'
  fi

  finish_mutation_commit
  log "Hysteria2 obfuscation changed transactionally: ${old_mode} -> ${HY2_OBFS_MODE}."
  printf 'Subscription URLs are unchanged. Refresh the subscription on each device.\n'
}
