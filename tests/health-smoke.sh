#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091,SC2030,SC2031,SC2329
source "${repo_root}/install-sing-box-server.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

seed_healthy_health_state() {
  health_reset_state
  CLIENT_FINGERPRINT=firefox
  HY2_OBFS_MODE=off
  SSH_PORT=22
  HEALTH_CORE_STATE=PASS
  HEALTH_CORE_VERSION=1.13.16
  HEALTH_VERSION_STATE=PASS
  HEALTH_RUNTIME_STATE=PASS
  HEALTH_RUNTIME_VERSION="$SCRIPT_VERSION"
  HEALTH_SERVICE_STATE=PASS
  HEALTH_CONFIG_STATE=PASS
  HEALTH_VLESS_STATE=PASS
  HEALTH_HY2_STATE=PASS
  HEALTH_SUBSCRIPTION_STATE=PASS
  HEALTH_SUBSCRIPTION_DETAIL='tcp/8443 · 1 client'
  HEALTH_DNS_STATE=PASS
  HEALTH_CERT_STATE=PASS
  HEALTH_CERT_DETAIL='expires 2026-11-06 (89 days)'
  HEALTH_CERT_HOSTNAME_STATE=PASS
  HEALTH_CERT_KEYPAIR_STATE=PASS
  HEALTH_LIVE_CERT_STATE=PASS
  HEALTH_LIVE_CERT_DETAIL='subscription endpoint serves current ACME certificate'
  HEALTH_RENEWAL_STATE=PASS
  HEALTH_RENEWAL_DETAIL='certbot timer · deploy hook · deployed cert synced'
  HEALTH_TARGET_STATE=PASS
  HEALTH_TARGET_DNS_STATE=PASS
  HEALTH_TARGET_DNS_DETAIL='target resolved from VPS'
  HEALTH_TARGET_TCP_STATE=PASS
  HEALTH_TARGET_TCP_DETAIL='outbound tcp/443 connected'
  HEALTH_TARGET_TLS_STATE=PASS
  HEALTH_TARGET_TLS_DETAIL='TLS 1.3 · certificate/SNI verified'
  HEALTH_TARGET_ALPN_STATE=PASS
  HEALTH_TARGET_ALPN_DETAIL='h2 negotiated'
  HEALTH_FIREWALL_STATE=PASS
  HEALTH_SSH_STATE=PASS
  HEALTH_PERMISSIONS_STATE=PASS
  HEALTH_SECURITY_UPDATES_STATE=PASS
  HEALTH_SECURITY_UPDATES_DETAIL='automatic · security-only · no automatic reboot'
  HEALTH_CORE_UPDATES_STATE=PASS
  HEALTH_CORE_UPDATES_DETAIL='sing-box apt-held · update through vpn update'
  HEALTH_TCP443_STATE=PASS
  HEALTH_UDP443_STATE=PASS
  HEALTH_TCP8443_STATE=PASS
  HEALTH_SSH_LISTENER_STATE=PASS
  HEALTH_TCP443_DETAIL='sing-box listening'
  HEALTH_UDP443_DETAIL='sing-box listening'
  HEALTH_TCP8443_DETAIL='nginx listening'
  HEALTH_SSH_LISTENER_DETAIL='sshd listening'
  HEALTH_CONGESTION_STATE=PASS
  HEALTH_CONGESTION=bbr
  HEALTH_QUEUE_STATE=PASS
  HEALTH_QUEUE_DETAIL='active fq'
  HEALTH_ACTIVE_QDISC=fq
  HEALTH_CONFIGURED_QDISC=fq
  HEALTH_DEFAULT_INTERFACE=ens3
  HEALTH_CLIENT_COUNT=1
  HEALTH_VLESS_CLIENTS=1
  HEALTH_HY2_CLIENTS=1
  HEALTH_OS='Debian GNU/Linux 13 (trixie)'
  HEALTH_KERNEL=6.12.101
  HEALTH_UPTIME=35m
  HEALTH_UPTIME_SECONDS=2100
  HEALTH_RESOURCES='RAM 254 MiB/967 MiB · disk 2.3 GiB/9.8 GiB · swap 0 MiB/1.0 GiB'
  HEALTH_CLOCK_STATE=PASS
  HEALTH_CLOCK_DETAIL='NTP synchronized'
  HEALTH_RECENT_ERRORS_STATE=PASS
  HEALTH_RECENT_ERRORS_FILE="${work}/recent-errors"
  HEALTH_DEBUG_ACTIONABLE_FILE="${work}/actionable-debug"
  HEALTH_REALITY_NOISE_SAMPLES_FILE="${work}/noise-samples"
  : >"$HEALTH_RECENT_ERRORS_FILE"
  : >"$HEALTH_DEBUG_ACTIONABLE_FILE"
  : >"$HEALTH_REALITY_NOISE_SAMPLES_FILE"
  health_recalculate_result
}

seed_healthy_health_state
short_output="$(render_health_short)"
grep -Fq 'Core           PASS · sing-box 1.13.16' <<<"$short_output"
grep -Fq 'Subscription   PASS · 1 client' <<<"$short_output"
grep -Fq 'REALITY target PASS · VPS -> target · TLS 1.3 · certificate/SNI · ALPN h2' \
  <<<"$short_output"
[[ "$short_output" != *$'\n  REALITY        PASS'* ]]
grep -Fq 'Network        PASS · bbr · fq' <<<"$short_output"
grep -Fq 'Server-side health: HEALTHY' <<<"$short_output"
grep -Fq 'Client-path reachability: NOT TESTED' <<<"$short_output"
grep -Fq 'Provider firewall: UNKNOWN' <<<"$short_output"
[[ "$(awk 'NF {count++} END {print count}' <<<"$short_output")" -le 12 ]]
[[ "$short_output" != *Profiles* ]]
[[ "$short_output" != *Fingerprint* ]]
[[ "$short_output" != *$'\033['* ]]

verbose_output="$(render_health_verbose | redact_health_stream)"
grep -Fq 'Server-side health: HEALTHY' <<<"$verbose_output"
for section in SYSTEM VPN NETWORK TLS 'REALITY TARGET (VPS -> TARGET)' SECURITY \
  'RECENT ACTIONABLE ERRORS'; do
  grep -Fxq "$section" <<<"$verbose_output"
done
grep -Fq 'OS             Debian GNU/Linux 13 (trixie) · Linux 6.12.101' <<<"$verbose_output"
grep -Fq 'TCP/443        PASS · sing-box listening' <<<"$verbose_output"
grep -Fq 'Certificate    PASS · expires 2026-11-06 (89 days) · hostname · key pair' <<<"$verbose_output"
grep -Fq 'Live certificate PASS · subscription endpoint serves current ACME certificate' \
  <<<"$verbose_output"
grep -Fq 'Client-path reachability: NOT TESTED' <<<"$verbose_output"
grep -Fq 'Provider firewall: UNKNOWN' <<<"$verbose_output"
grep -Fq 'These probes do not test client-to-VPS reachability or censorship resistance.' \
  <<<"$verbose_output"
grep -A1 -Fx 'RECENT ACTIONABLE ERRORS' <<<"$verbose_output" | grep -Fq 'None'
grep -Fq 'Security updates PASS · automatic · security-only · no automatic reboot' \
  <<<"$verbose_output"
grep -Fq 'Core updates   PASS · sing-box apt-held · update through vpn update' \
  <<<"$verbose_output"
grep -Fq 'Sensitive values are redacted.' <<<"$verbose_output"
for forbidden in 'Listeners (addresses redacted)' 'Queue discipline counters' \
  'UDP receive ceiling' 'notBefore=' 'Client-side REALITY fragmentation guidance' \
  'journal usage'; do
  [[ "$verbose_output" != *"$forbidden"* ]]
done

(
  seed_healthy_health_state
  sysctl() {
    printf '%s\n' \
      'net.ipv4.tcp_congestion_control = bbr' \
      'net.core.default_qdisc = fq' \
      'net.core.rmem_max = 7340032' \
      'net.core.wmem_max = 7340032'
  }
  ss() {
    if [[ "$*" == *-tin* ]]; then
      printf '%s\n' 'bbr wscale:7,7 rto:204 rtt:1.2'
    else
      printf '%s\n' 'LISTEN 0 4096 203.0.113.77:443 0.0.0.0:* users:(("sing-box",pid=7,fd=4))'
    fi
  }
  tc() { printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p'; }
  ip() { printf '%s\n' '2: ens3: <UP>' '    inet 203.0.113.77/24' '    RX: 1234 bytes'; }
  openssl() { printf '%s\n' 'notBefore=Aug  8 00:00:00 2026 GMT' 'notAfter=Nov  6 00:00:00 2026 GMT'; }
  systemctl() { printf '%s\n' 'Id=sing-box.service' 'ActiveState=active'; }
  SERVER_IPV4=203.0.113.77
  TLS_DOMAIN=vpn.example.com
  printf '%s\n' \
    'sing-box[627] connection to 203.0.113.77 vpn.example.com password=abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef' \
    >"$HEALTH_DEBUG_ACTIONABLE_FILE"
  debug_output="$({ render_health_verbose; render_health_debug_details; } | redact_health_stream)"
  grep -Fxq 'DEVELOPMENT DETAILS' <<<"$debug_output"
  grep -Fq 'Relevant sysctl:' <<<"$debug_output"
  grep -Fq 'Listener dump (bounded):' <<<"$debug_output"
  grep -Fq 'Active qdisc for default interface:' <<<"$debug_output"
  grep -Fq 'Default interface counters:' <<<"$debug_output"
  grep -Fq 'Certificate timestamps:' <<<"$debug_output"
  grep -Fxq 'ACTIONABLE ERROR DETAILS' <<<"$debug_output"
  grep -Fxq 'IGNORED INBOUND NOISE' <<<"$debug_output"
  grep -Fq 'sing-box[627] connection' <<<"$debug_output"
  [[ "$debug_output" != *'203.0.113.77'* ]]
  [[ "$debug_output" != *'vpn.example.com'* ]]
  [[ "$debug_output" != *'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef'* ]]
  grep -Fq 'net.core.default_qdisc' <<<"$debug_output"
  grep -Fq 'net.core.rmem_max' <<<"$debug_output"
  grep -Fq 'net.ipv4.tcp_congestion_control' <<<"$debug_output"
  grep -Fq 'sing-box.service' <<<"$debug_output"
  grep -Fq 'kernel default bbr' <<<"$debug_output"
  [[ "$debug_output" != *'BBR active'* ]]
)

# Listener ownership is semantic; verbose never needs raw ss output.
health_listener_check \
  'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=12,fd=6))' \
  443 sing-box
[[ "$HEALTH_LISTENER_STATE" == FAIL ]]
[[ "$HEALTH_LISTENER_DETAIL" == 'expected sing-box, found nginx' ]]

seed_healthy_health_state
HEALTH_TCP443_STATE=FAIL
HEALTH_TCP443_DETAIL='expected sing-box, found nginx'
HEALTH_VLESS_STATE=FAIL
health_recalculate_result
failed_listener_output="$(render_health_verbose)"
grep -Fq 'TCP/443        FAIL · expected sing-box, found nginx' <<<"$failed_listener_output"
grep -Fq 'Server-side health: UNHEALTHY' <<<"$failed_listener_output"
(( HEALTH_FAILURES > 0 ))

seed_healthy_health_state
HEALTH_UDP443_STATE=FAIL
HEALTH_UDP443_DETAIL='not listening'
HEALTH_HY2_STATE=FAIL
health_recalculate_result
missing_udp_output="$(render_health_verbose)"
grep -Fq 'UDP/443        FAIL · not listening' <<<"$missing_udp_output"
grep -Fq 'Hysteria2      FAIL · udp/443 · 1 client' <<<"$missing_udp_output"

seed_healthy_health_state
HEALTH_SUBSCRIPTION_STATE=FAIL
HEALTH_SUBSCRIPTION_DETAIL='self-test failed'
health_recalculate_result
subscription_failure_output="$(render_health_verbose)"
grep -Fq 'Subscription   FAIL · self-test failed' <<<"$subscription_failure_output"

seed_healthy_health_state
HEALTH_CONFIG_STATE=FAIL
HEALTH_CORE_STATE=FAIL
health_recalculate_result
config_failure_output="$(render_health_verbose)"
grep -Fq 'Config         FAIL · sing-box configuration validation' <<<"$config_failure_output"

seed_healthy_health_state
health_classify_certificate_expiry 1893456000 5
health_recalculate_result
near_expiry_output="$(render_health_verbose)"
grep -Eq 'Certificate[[:space:]]+WARN · expires [0-9]{4}-[0-9]{2}-[0-9]{2} \(5 days\)' \
  <<<"$near_expiry_output"
grep -Fq 'Server-side health: HEALTHY (warnings)' <<<"$near_expiry_output"
(( HEALTH_FAILURES == 0 ))

seed_healthy_health_state
HEALTH_CERT_STATE=FAIL
HEALTH_CERT_DETAIL='certificate expired or invalid'
HEALTH_CERT_HOSTNAME_STATE=FAIL
HEALTH_CERT_KEYPAIR_STATE=FAIL
HEALTH_LIVE_CERT_STATE=FAIL
HEALTH_LIVE_CERT_DETAIL='served certificate unavailable'
health_recalculate_result
invalid_certificate_output="$(render_health_verbose)"
grep -Fq 'Certificate    FAIL · certificate expired or invalid' \
  <<<"$invalid_certificate_output"
grep -Fq 'Live certificate FAIL · served certificate unavailable' \
  <<<"$invalid_certificate_output"

health_dns_matches '203.0.113.10' $'203.0.113.10\n198.51.100.1' '203.0.113.10'
if health_dns_matches '203.0.113.10' '198.51.100.2' '203.0.113.10'; then
  printf 'Mismatched DNS answers unexpectedly passed.\n' >&2
  exit 1
fi

# REALITY health reports each bounded VPS-to-target stage separately. A timeout
# remains a plain probe failure and must not be labelled as censorship or DPI.
# shellcheck disable=SC2030,SC2031
(
  seed_healthy_health_state
  HEALTH_TARGET_STATE=FAIL
  HEALTH_TARGET_DNS_STATE=FAIL
  HEALTH_TARGET_TCP_STATE=FAIL
  HEALTH_TARGET_TLS_STATE=FAIL
  HEALTH_TARGET_ALPN_STATE=FAIL
  TMP_DIR="${work}/target-pass"
  mkdir -p "$TMP_DIR"
  health_reality_target_dns_probe() { return 0; }
  health_reality_target_tcp_probe() { return 0; }
  timeout() { shift; "$@"; }
  # shellcheck disable=SC2317,SC2329 # Invoked indirectly through the timeout test seam.
  openssl() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verification: OK' \
      'ALPN protocol: h2'
  }
  health_collect_reality_target
  [[ "$HEALTH_TARGET_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_DNS_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_TCP_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_TLS_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_ALPN_STATE" == PASS ]]
)

# shellcheck disable=SC2030,SC2031
(
  health_reset_state
  health_reality_target_dns_probe() { return 1; }
  health_reality_target_tcp_probe() { return 0; }
  health_collect_reality_target
  [[ "$HEALTH_TARGET_DNS_STATE" == FAIL ]]
  [[ "$HEALTH_TARGET_TCP_STATE" == FAIL ]]
)

# shellcheck disable=SC2030,SC2031
(
  health_reset_state
  health_reality_target_dns_probe() { return 0; }
  health_reality_target_tcp_probe() { return 1; }
  health_collect_reality_target
  [[ "$HEALTH_TARGET_DNS_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_TCP_STATE" == FAIL ]]
  [[ "$HEALTH_TARGET_TLS_STATE" == FAIL ]]
)

# shellcheck disable=SC2030,SC2031
(
  health_reset_state
  TMP_DIR="${work}/target-timeout"
  mkdir -p "$TMP_DIR"
  health_reality_target_dns_probe() { return 0; }
  health_reality_target_tcp_probe() { return 0; }
  timeout() { return 124; }
  health_collect_reality_target
  [[ "$HEALTH_TARGET_TLS_STATE" == FAIL ]]
  grep -Fq 'timed out; censorship was not inferred' <<<"$HEALTH_TARGET_TLS_DETAIL"
)

# shellcheck disable=SC2030,SC2031
(
  health_reset_state
  TMP_DIR="${work}/target-alpn"
  mkdir -p "$TMP_DIR"
  health_reality_target_dns_probe() { return 0; }
  health_reality_target_tcp_probe() { return 0; }
  timeout() { shift; "$@"; }
  # shellcheck disable=SC2317,SC2329 # Invoked indirectly through the timeout test seam.
  openssl() {
    printf '%s\n' \
      'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' \
      'Verification: OK' \
      'No ALPN negotiated'
  }
  health_collect_reality_target
  [[ "$HEALTH_TARGET_TLS_STATE" == PASS ]]
  [[ "$HEALTH_TARGET_ALPN_STATE" == FAIL ]]
  [[ "$HEALTH_TARGET_STATE" == FAIL ]]
)

# The certificate served by nginx is checked independently from the files on
# disk. A valid but different served certificate must fail the comparison.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=expected.example' \
  -keyout "${work}/expected.key" -out "${work}/expected.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=stale.example' \
  -keyout "${work}/stale.key" -out "${work}/stale.pem" >/dev/null 2>&1
(
  TMP_DIR="${work}/live-cert-match"
  mkdir -p "$TMP_DIR"
  served_source="${work}/expected.pem"
  # shellcheck disable=SC2317,SC2329 # Invoked by the sourced certificate probe.
  timeout() { cat "$served_source"; }
  health_live_subscription_certificate_matches "${work}/expected.pem"
)
(
  TMP_DIR="${work}/live-cert-mismatch"
  mkdir -p "$TMP_DIR"
  served_source="${work}/stale.pem"
  # shellcheck disable=SC2317,SC2329 # Invoked by the sourced certificate probe.
  timeout() { cat "$served_source"; }
  if health_live_subscription_certificate_matches "${work}/expected.pem"; then
    printf 'A stale served certificate unexpectedly matched the deployed certificate.\n' >&2
    exit 1
  fi
)

seed_healthy_health_state
HEALTH_DNS_STATE=FAIL
health_recalculate_result
dns_output="$(render_health_verbose)"
grep -Fq 'Public IPv4    FAIL · configured · DNS mismatch' <<<"$dns_output"

seed_healthy_health_state
HEALTH_SERVICE_STATE=FAIL
HEALTH_CORE_STATE=FAIL
health_recalculate_result
inactive_output="$(render_health_verbose)"
grep -Fq 'Service        FAIL · sing-box.service inactive' <<<"$inactive_output"

seed_healthy_health_state
HEALTH_CORE_STATE=FAIL
HEALTH_SERVICE_STATE=FAIL
HEALTH_VLESS_STATE=FAIL
HEALTH_HY2_STATE=FAIL
health_recalculate_result
stopped_short_output="$(render_health_short)"
grep -Fq 'Core           FAIL · sing-box 1.13.16' <<<"$stopped_short_output"
grep -Fq 'Protocols      FAIL · REALITY tcp/443 · Hysteria2 udp/443' \
  <<<"$stopped_short_output"
grep -Fq 'REALITY target PASS · VPS -> target · TLS 1.3 · certificate/SNI · ALPN h2' \
  <<<"$stopped_short_output"

seed_healthy_health_state
HEALTH_FIREWALL_STATE=FAIL
health_recalculate_result
nft_output="$(render_health_verbose)"
grep -Fq 'nftables       FAIL · managed vpn_filter policy' <<<"$nft_output"

seed_healthy_health_state
HEALTH_SSH_STATE=FAIL
health_recalculate_result
ssh_output="$(render_health_verbose)"
grep -Fq 'SSH            FAIL · key-only policy' <<<"$ssh_output"

seed_healthy_health_state
HEALTH_CLIENT_COUNT=2
HEALTH_VLESS_CLIENTS=2
HEALTH_HY2_CLIENTS=2
HEALTH_SUBSCRIPTION_DETAIL='tcp/8443 · 2 clients'
two_clients_output="$(render_health_verbose)"
grep -Fq '2 clients' <<<"$two_clients_output"
[[ "$two_clients_output" != *'2 client ·'* ]]

(
  sysctl() {
    case "$*" in
      *tcp_congestion_control*) printf 'bbr\n' ;;
      *default_qdisc*) printf 'fq\n' ;;
    esac
  }
  ip() { printf '%s\n' 'default via 192.0.2.1 dev ens3'; }
  tc() { printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 10240p'; }
  seed_healthy_health_state
  health_collect_network
  [[ "$HEALTH_CONFIGURED_QDISC" == fq ]]
  [[ "$HEALTH_ACTIVE_QDISC" == fq_codel ]]
  [[ "$HEALTH_QUEUE_STATE" == INFO ]]
  HEALTH_CONGESTION_STATE=PASS
  health_recalculate_result
  (( HEALTH_WARNINGS == 0 ))
  queue_output="$(render_health_verbose)"
  grep -Fq 'Queue          INFO · active fq_codel · fq configured for next interface recreation' \
    <<<"$queue_output"
)

(
  sysctl() {
    case "$*" in
      *tcp_congestion_control*) printf 'bbr\n' ;;
      *default_qdisc*) printf 'fq\n' ;;
    esac
  }
  ip() { printf '%s\n' 'default via 192.0.2.1 dev ens3'; }
  tc() { printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p'; }
  seed_healthy_health_state
  health_collect_network
  [[ "$HEALTH_QUEUE_STATE" == PASS ]]
  [[ "$HEALTH_QUEUE_DETAIL" == 'active fq' ]]
)

network_body="$(declare -f health_collect_network)"
[[ "$network_body" != *'tc qdisc replace'* ]]

fake_uuid='550e8400-e29b-41d4-a716-446655440000'
fake_ip='203.0.113.77'
fake_ipv6='2001:db8:1:2::10'
fake_domain='vpn-secret.example.com'
fake_token='abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
fake_key='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789+/=='
SERVER_IPV4="$fake_ip"
TLS_DOMAIN="$fake_domain"
REALITY_TARGET='reality-secret.example.net'
redacted_output="$(printf '%s\n' \
  "$fake_uuid $fake_ip $fake_ipv6 $fake_domain $REALITY_TARGET $fake_token private_key=$fake_key" \
  'Server-side health: HEALTHY' \
  'net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.ipv4.tcp_congestion_control' \
  'sing-box.service nginx.service nftables.service certbot.timer systemd[123] sing-box[627]' \
  'MAC 52:54:00:12:34:56 PID 123 integer 627' | \
  redact_health_stream)"
for secret in "$fake_uuid" "$fake_ip" "$fake_ipv6" "$fake_domain" "$REALITY_TARGET" \
  "$fake_token" "$fake_key"; do
  [[ "$redacted_output" != *"$secret"* ]]
done
for literal in net.core.default_qdisc net.core.rmem_max net.core.wmem_max \
  net.ipv4.tcp_congestion_control sing-box.service nginx.service nftables.service \
  certbot.timer 'systemd[123]' 'sing-box[627]' '52:54:00:12:34:56' 'PID 123' \
  'integer 627'; do
  [[ "$redacted_output" == *"$literal"* ]]
done
[[ "$redacted_output" == *'Server-side health: HEALTHY'* ]]

for adjacent_ipv4_input in \
  '198.51.100.10 203.0.113.20 192.0.2.30' \
  '198.51.100.10,203.0.113.20,192.0.2.30'; do
  adjacent_ipv4_output="$(printf '%s\n' "$adjacent_ipv4_input" | redact_health_stream)"
  for ipv4 in 198.51.100.10 203.0.113.20 192.0.2.30; do
    [[ "$adjacent_ipv4_output" != *"$ipv4"* ]]
  done
  [[ "$(grep -o '\[IP-REDACTED\]' <<<"$adjacent_ipv4_output" | wc -l | tr -d ' ')" == 3 ]]
done

seed_healthy_health_state
health_classify_ntp_state no 120
[[ "$HEALTH_CLOCK_STATE" == PENDING ]]
[[ "$HEALTH_CLOCK_DETAIL" == 'waiting for NTP synchronization' ]]
health_recalculate_result
(( HEALTH_WARNINGS == 0 ))
health_classify_ntp_state no 301
[[ "$HEALTH_CLOCK_STATE" == WARN ]]
health_classify_ntp_state yes 10
[[ "$HEALTH_CLOCK_STATE" == PASS ]]

(
  seed_healthy_health_state
  TMP_DIR="${work}/journal-noise"
  mkdir -p "$TMP_DIR"
  SERVER_IPV4=203.0.113.77
  journalctl() {
    printf '%s\n' \
      '2026-08-09 sing-box[627]: ERROR inbound from 198.51.100.10:41001: REALITY: processed invalid connection' \
      '2026-08-09 sing-box[627]: ERROR inbound from 198.51.100.10:41002: REALITY: processed invalid connection' \
      '2026-08-09 sing-box[627]: ERROR inbound from [2001:db8::8]:41003: REALITY: processed invalid connection' \
      '2026-08-09 sing-box[627]: ERROR outbound: dial tcp 203.0.113.77:443: connection refused'
  }
  health_collect_recent_errors
  [[ "$HEALTH_REALITY_NOISE_COUNT" == 3 ]]
  [[ "$HEALTH_REALITY_NOISE_UNIQUE_SOURCES" == 2 ]]
  [[ "$HEALTH_RECENT_ERRORS_STATE" == WARN ]]
  grep -Fq 'connection refused' "$HEALTH_RECENT_ERRORS_FILE"
  if grep -Fq 'processed invalid connection' "$HEALTH_RECENT_ERRORS_FILE"; then
    printf 'Known REALITY noise leaked into actionable errors.\n' >&2
    exit 1
  fi
  verbose_noise="$(render_health_verbose)"
  [[ "$verbose_noise" != *'processed invalid connection'* ]]
  [[ "$verbose_noise" != *'198.51.100.10'* ]]
  debug_noise="$(render_health_debug_details | redact_health_stream)"
  grep -Fq 'Invalid REALITY handshakes (30 min): 3' <<<"$debug_noise"
  grep -Fq 'Unique source addresses (30 min): 2' <<<"$debug_noise"
  grep -Fq 'Redacted samples (bounded):' <<<"$debug_noise"
  [[ "$debug_noise" != *'198.51.100.10'* ]]
  [[ "$debug_noise" != *'2001:db8::8'* ]]
)

(
  seed_healthy_health_state
  TMP_DIR="${work}/journal-noise-only"
  mkdir -p "$TMP_DIR"
  journalctl() {
    printf '%s\n' \
      '2026-08-09 sing-box[627]: ERROR inbound from 198.51.100.10:41001: REALITY: processed invalid connection'
  }
  health_collect_recent_errors
  health_recalculate_result
  [[ "$HEALTH_RECENT_ERRORS_STATE" == PASS ]]
  (( HEALTH_WARNINGS == 0 ))
)

(
  seed_healthy_health_state
  TMP_DIR="${work}/journal-bounds"
  mkdir -p "$TMP_DIR"
  input="${TMP_DIR}/input"
  output="${TMP_DIR}/output"
  padding="$(printf 'x%.0s' {1..700})"
  for entry in {1..25}; do
    printf 'ERROR entry-%02d 203.0.113.77 %s useful-reason-%02d\n' \
      "$entry" "$padding" "$entry" >>"$input"
  done
  SERVER_IPV4=203.0.113.77
  health_write_bounded_redacted_file "$input" "$output" 20 12288
  [[ "$(wc -l <"$output" | tr -d ' ')" -le 20 ]]
  [[ "$(wc -c <"$output" | tr -d ' ')" -le 12288 ]]
  grep -Fq 'useful-reason-25' "$output"
  [[ "$(<"$output")" != *'203.0.113.77'* ]]
)

(
  COMMAND=plan
  VERBOSE=0
  DEBUG=0
  parse_args health --debug
  [[ "$COMMAND" == health ]]
  (( VERBOSE == 1 ))
  (( DEBUG == 1 ))
)

trap - ERR
if typo_output="$(bash "${repo_root}/install-sing-box-server.sh" health --verborse 2>&1)"; then
  printf 'Misspelled health option unexpectedly succeeded.\n' >&2
  exit 1
fi
trap on_error ERR
grep -Fq '[ERROR] Unknown option: --verborse' <<<"$typo_output"
grep -Fq 'Did you mean: --verbose?' <<<"$typo_output"
[[ "$typo_output" != *'Step: startup'* ]]

printf 'Health UX smoke test: PASS\n'
