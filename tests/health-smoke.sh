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
  HEALTH_RENEWAL_STATE=PASS
  HEALTH_RENEWAL_DETAIL='certbot timer · deploy hook · deployed cert synced'
  HEALTH_TARGET_STATE=PASS
  HEALTH_FIREWALL_STATE=PASS
  HEALTH_SSH_STATE=PASS
  HEALTH_PERMISSIONS_STATE=PASS
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
  HEALTH_ACTIVE_QDISC=fq
  HEALTH_CONFIGURED_QDISC=fq
  HEALTH_DEFAULT_INTERFACE=ens3
  HEALTH_CLIENT_COUNT=1
  HEALTH_VLESS_CLIENTS=1
  HEALTH_HY2_CLIENTS=1
  HEALTH_OS='Debian GNU/Linux 13 (trixie)'
  HEALTH_KERNEL=6.12.101
  HEALTH_UPTIME=35m
  HEALTH_RESOURCES='RAM 254 MiB/967 MiB · disk 2.3 GiB/9.8 GiB · swap 0 MiB/1.0 GiB'
  HEALTH_CLOCK_STATE=PASS
  HEALTH_CLOCK_DETAIL='NTP synchronized'
  HEALTH_RECENT_ERRORS_STATE=PASS
  HEALTH_RECENT_ERRORS_FILE="${work}/recent-errors"
  : >"$HEALTH_RECENT_ERRORS_FILE"
  health_recalculate_result
}

seed_healthy_health_state
short_output="$(render_health_short)"
grep -Fq 'Core           PASS · sing-box 1.13.16' <<<"$short_output"
grep -Fq 'Subscription   PASS · 1 client' <<<"$short_output"
grep -Fq 'Network        PASS · bbr · fq' <<<"$short_output"
grep -Fq 'Result: HEALTHY' <<<"$short_output"
[[ "$(awk 'NF {count++} END {print count}' <<<"$short_output")" -le 10 ]]
[[ "$short_output" != *Profiles* ]]
[[ "$short_output" != *Fingerprint* ]]
[[ "$short_output" != *$'\033['* ]]

verbose_output="$(render_health_verbose | redact_health_stream)"
for section in SYSTEM VPN NETWORK TLS SECURITY 'RECENT ERRORS'; do
  grep -Fxq "$section" <<<"$verbose_output"
done
grep -Fq 'OS             Debian GNU/Linux 13 (trixie) · Linux 6.12.101' <<<"$verbose_output"
grep -Fq 'TCP/443        PASS · sing-box listening' <<<"$verbose_output"
grep -Fq 'Certificate    PASS · expires 2026-11-06 (89 days) · hostname · key pair' <<<"$verbose_output"
grep -A1 -Fx 'RECENT ERRORS' <<<"$verbose_output" | grep -Fq 'None'
grep -Fq 'Sensitive values are redacted.' <<<"$verbose_output"
for forbidden in 'Listeners (addresses redacted)' 'Queue discipline counters' \
  'UDP receive ceiling' 'notBefore=' 'Client-side REALITY fragmentation guidance' \
  'journal usage'; do
  [[ "$verbose_output" != *"$forbidden"* ]]
done

(
  seed_healthy_health_state
  sysctl() { printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr' 'net.core.default_qdisc = fq'; }
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
  journalctl() {
    printf '%s\n' '203.0.113.77 vpn.example.com password=abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef'
  }
  debug_output="$({ render_health_verbose; render_health_debug_details; } | redact_health_stream)"
  grep -Fxq 'DEVELOPMENT DETAILS' <<<"$debug_output"
  grep -Fq 'Relevant sysctl:' <<<"$debug_output"
  grep -Fq 'Listener dump (bounded):' <<<"$debug_output"
  grep -Fq 'Active qdisc for default interface:' <<<"$debug_output"
  grep -Fq 'Default interface counters:' <<<"$debug_output"
  grep -Fq 'Certificate timestamps:' <<<"$debug_output"
  grep -Fq 'Recent sing-box journal (bounded):' <<<"$debug_output"
  [[ "$debug_output" != *'203.0.113.77'* ]]
  [[ "$debug_output" != *'vpn.example.com'* ]]
  [[ "$debug_output" != *'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef'* ]]
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
grep -Fq 'Result: UNHEALTHY' <<<"$failed_listener_output"
(( HEALTH_FAILURES > 0 ))

seed_healthy_health_state
health_classify_certificate_expiry 1893456000 5
health_recalculate_result
near_expiry_output="$(render_health_verbose)"
grep -Eq 'Certificate[[:space:]]+WARN · expires [0-9]{4}-[0-9]{2}-[0-9]{2} \(5 days\)' \
  <<<"$near_expiry_output"
grep -Fq 'Result: HEALTHY (warnings)' <<<"$near_expiry_output"
(( HEALTH_FAILURES == 0 ))

health_dns_matches '203.0.113.10' $'203.0.113.10\n198.51.100.1' '203.0.113.10'
if health_dns_matches '203.0.113.10' '198.51.100.2' '203.0.113.10'; then
  printf 'Mismatched DNS answers unexpectedly passed.\n' >&2
  exit 1
fi
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
grep -Fq 'sing-box       FAIL · 1.13.16 · inactive' <<<"$inactive_output"

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
  health_reset_state
  health_collect_network
  [[ "$HEALTH_CONFIGURED_QDISC" == fq ]]
  [[ "$HEALTH_ACTIVE_QDISC" == fq_codel ]]
  [[ "$HEALTH_QUEUE_STATE" == WARN ]]
  queue_output="$(render_health_verbose)"
  grep -Fq 'Queue          WARN · active fq_codel · configured default fq' <<<"$queue_output"
)

fake_uuid='550e8400-e29b-41d4-a716-446655440000'
fake_ip='203.0.113.77'
fake_ipv6='2001:db8:1:2::10'
fake_domain='vpn-secret.example.com'
fake_token='abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
fake_key='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789+/=='
redacted_output="$(printf '%s\n' \
  "$fake_uuid $fake_ip $fake_ipv6 $fake_domain $fake_token private_key=$fake_key" | \
  redact_health_stream)"
for secret in "$fake_uuid" "$fake_ip" "$fake_ipv6" "$fake_domain" "$fake_token" "$fake_key"; do
  [[ "$redacted_output" != *"$secret"* ]]
done

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
