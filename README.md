# sing-box-vps

[![CI](https://github.com/stillnotfree/sing-box-vps/actions/workflows/ci.yml/badge.svg)](https://github.com/stillnotfree/sing-box-vps/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/stillnotfree/sing-box-vps?display_name=tag&sort=semver)](https://github.com/stillnotfree/sing-box-vps/releases/latest)
[![License](https://img.shields.io/github/license/stillnotfree/sing-box-vps)](LICENSE)

**English** · [Русский](README_RU.md)

A minimal interactive installer for a private sing-box server on a clean VPS.
It is designed for a small personal server that should be easy to install,
update, and manage without a web panel.

## Features

- Installs the latest compatible stable sing-box from its official signed repository.
- Runs VLESS + REALITY + Vision on TCP/443 and Hysteria2 + TLS on UDP/443.
- No web panel, Docker, statistics, telemetry, or access logging.

## Before you start

You need:

- Debian 13, Ubuntu 24.04 LTS, or Ubuntu 26.04 LTS on `amd64`;
- at least 1 vCPU, 1 GB RAM, and 10 GB disk;
- a public IPv4 address and a real systemd boot;
- a domain or subdomain with a direct `A` record pointing to the VPS;
- a real email address for Let's Encrypt;
- an OpenSSH **public** key, such as one line beginning with `ssh-ed25519`;
- a reviewed REALITY target supporting TLS 1.3 and HTTP/2.

Never paste or upload your private SSH key.

Allow these ports in the provider firewall or security group:

| Protocol | Port | Purpose |
| --- | ---: | --- |
| TCP | Current SSH port | Server administration |
| TCP | 80 | Let's Encrypt validation |
| TCP | 443 | VLESS + REALITY |
| UDP | 443 | Hysteria2 |
| TCP | 8443 | Private subscriptions |

The DNS record must point directly to the VPS. Do not enable a CDN or DNS proxy
for it, and do not add an `AAAA` record unless IPv6 is deliberately configured.

## Install

Connect to the VPS as `root` and run:

```bash
wget -qO vpn-install.sh https://github.com/stillnotfree/sing-box-vps/releases/latest/download/install-sing-box-server.sh && chmod 700 vpn-install.sh && ./vpn-install.sh install
```

This downloads the latest published GitHub release rather than mutable `main`.
To install an exact reviewed version, replace `latest/download` with
`download/v1.0.10`; the current release page also publishes the installer
SHA-256. Before executing code as root, obtain the expected SHA-256 through a
separately trusted channel, verify it locally with `sha256sum vpn-install.sh`,
and inspect the script. A checksum from the same GitHub release is useful for
integrity checking but is not an independent trust anchor. See
[development verification](docs/development.md#clean-install-and-release-evidence).

The installer asks for the administrator, public SSH key, VPS address, domain,
email, current SSH port, REALITY target, VPS country, and client fingerprint. It
shows a short summary and asks for confirmation with `[Y/n]`; pressing Enter
accepts. An interrupted installation can normally be resumed with the same
command.

The selected REALITY target is audited immediately when `openssl` and `timeout`
are already available. Otherwise the installer explicitly defers the audit
until dependencies are installed, but still runs it before saving settings. A
TLS 1.3, certificate-chain, or ALPN h2 failure requires another target. Zero
observed `NewSessionTicket` messages is preferred only for this heuristic; one
or more tickets produces a warning, but the target remains usable and can be
kept by default. `--yes` skips the final confirmation prompt; for the normal
question-driven install, leave it out. In an interactive install, a warning
offers `[K]` to keep the usable target, `[T]` to try another one, and `[?]` for
the heuristic's limitations. A non-interactive install keeps a target that has
passed TLS, certificate/SNI, and ALPN checks even when tickets were observed.
Raw OpenSSL trace and certificate diagnostics are hidden by default; use
`vpn audit-target DOMAIN --verbose` only when they are explicitly needed.
`vpn set-target DOMAIN` uses this same audit before any transaction starts. A
target with a comparison-heuristic warning is still usable, but must be
accepted before settings, configuration, or subscriptions are changed. Session
tickets are normal TLS 1.3 behavior; their count is not a security score.

## Source layout

Development happens in the ordered Bash modules under `src/`. The public
`install-sing-box-server.sh` is a generated, self-contained artifact, so a
clean VPS still downloads and runs one file without Git or repository files.
Regenerate it after module changes with:

```bash
scripts/build-standalone.sh
```

## First login

Keep the installer session open. In a second terminal, log in once with the new
administrator and the configured private key:

```bash
ssh ADMIN_USER@SERVER_IP
```

That successful interactive login automatically confirms the firewall and
enables key-only SSH. No separate finalization command or second login is
normally required.

The created account is a full administrator with `NOPASSWD: ALL`. Possession
of its SSH private key therefore permits root access through `sudo` without a
second factor. `PermitRootLogin no` still blocks direct root login, but is not
an additional privilege boundary after the administrator has logged in.

The first independent client is named `default`. Display its private
subscription, direct links, and QR codes with:

```bash
vpn show default
```

Do not share this output: the links contain client credentials.

## Commands

| Task | Command |
| --- | --- |
| Check server health | `vpn health` |
| Show semantic redacted diagnostics | `vpn health --verbose` |
| Show bounded developer diagnostics | `vpn health --debug` |
| Check installation compatibility | `vpn check` |
| List clients | `vpn show` |
| Show private links and QR codes | `vpn show NAME` |
| Add an independent client | `vpn add NAME` |
| Revoke a client | `vpn delete NAME --yes` |
| Update sing-box safely | `vpn update` |
| Audit a REALITY target | `vpn audit-target [DOMAIN] [--verbose]` |
| Change the REALITY target | `vpn set-target DOMAIN` |
| Select a client fingerprint | `vpn set-fingerprint` |
| Use native Hysteria2/QUIC | `vpn set-obfs off` |
| Enable Salamander | `vpn set-obfs salamander` |
| Show built-in help | `vpn help` |

The installed `vpn` command obtains its required administrative privileges
automatically. You do not need to prefix it with `sudo`.

`vpn health` is the short server-side operational result. It always reports
client-path reachability as `NOT TESTED` and the provider firewall as `UNKNOWN`;
neither changes a successful exit code. `--verbose` expands the result into
semantic SYSTEM, VPN, NETWORK, TLS, VPS-to-REALITY-target, SECURITY, and RECENT
ACTIONABLE ERRORS sections without raw system dumps. It distinguishes the
managed sing-box version, config validation, service, TCP/UDP listeners, local
nftables, local subscription endpoint, DNS/certificate state, the certificate
actually served by nginx, and bounded VPS-to-target DNS/TCP/TLS/ALPN probes.
`--debug` adds bounded low-level listener, qdisc, interface, certificate,
systemd, and journal data. Known invalid
REALITY handshakes are treated as unauthenticated inbound noise, not a server
failure; only debug output includes redacted bounded samples and 30-minute
counts. Sensitive values remain redacted in both diagnostic modes.

Target, fingerprint, obfuscation, client, and update changes are validated and
applied transactionally. Existing subscription URLs remain stable; refresh the
subscription in clients after changing connection settings.

## System updates

Normal operating-system updates are supported:

```bash
sudo apt update
sudo apt upgrade
vpn update
vpn health
```

Only OS security origins are enabled for automatic unattended upgrades, and
automatic reboot is disabled. sing-box is APT-held and updated separately by
`vpn update`, which validates the current configuration and can restore the
cached previous package if startup fails.

## What the installer configures

| Component | Configuration |
| --- | --- |
| Core | Compatible stable sing-box from the signed SagerNet repository |
| Primary | VLESS + REALITY + Vision on TCP/443 |
| Reserve | Hysteria2 + TLS on UDP/443; native QUIC by default, optional Salamander |
| Clients | Independent credentials, HTTPS subscription, links, and QR codes |
| SSH | Dedicated administrator, public-key authentication, root/password login disabled |
| Firewall | Native nftables with a temporary automatic rollback window |
| TLS | Let's Encrypt certificate with tested automatic renewal |
| Network | BBR + `fq` when supported and conservative UDP buffer ceilings |
| Storage | 1 GiB swap when supported and absent, plus a 200 MiB / 30-day journal limit |
| Updates | Security-only automatic OS updates without reboot; APT-held transactional sing-box updates |

The installer owns only `table inet vpn_filter`; it does not flush unrelated
nftables tables.

## Subscriptions

Each client receives an unguessable HTTPS subscription URL on TCP/8443. The
same URL serves a Base64 VLESS/Hysteria2 list or a complete Mihomo profile based
on the client `User-Agent`; `/mihomo` is also available explicitly. Routing,
split tunneling, and GeoIP policy remain the responsibility of the client.

See [docs/SUBSCRIPTIONS.md](docs/SUBSCRIPTIONS.md) for compatibility details and
the subscription threat model.

## Connectivity troubleshooting

`vpn health` proves only the managed server-side state. It cannot prove that an
IP or protocol is reachable from a Russian network, that a provider firewall is
open, or that traffic passes a particular ISP's filtering.

1. Run `vpn health`, then `vpn health --verbose` if a server-side row fails.
2. If the server is healthy, test the same VPS/IP from another access network.
3. Test REALITY TCP/443 and Hysteria2 UDP/443 independently; they have different
   failure domains.
4. Check SSH or other traffic to the same IP.
5. Compare another IP, VPS, or hoster while keeping protocol settings unchanged.
6. Only then compare client implementations and protocol-specific settings.
7. Treat the fingerprint as a controlled A/B compatibility knob, not a bypass
   guarantee. Check IP/path, TCP/443, and client behavior first.
8. Investigate MTU only for matching timeout/stall symptoms; do not guess or
   change it globally without a reproduced case.

A working Hysteria2 connection does not prove that REALITY, TCP/443, or the
server IP is universally unblocked. A successful handshake also does not prove
a usable tunnel. The field evidence behind this model is summarized in
[docs/research/russia-network-findings.md](docs/research/russia-network-findings.md).

## Limitations

- No protocol, REALITY target, or fingerprint is guaranteed to bypass every network filter.
- Hysteria2 requires usable UDP and may be degraded by some networks.
- The installer deliberately accepts only the tested sing-box 1.13 release line.
- IPv6 profiles, CDN transports, port hopping, panels, and traffic statistics are not configured.
- Client routing and TLS fragmentation are not forced by the server.
- When `fq` is configured on an already-running host, the current interface may
  retain `fq_codel` until it is recreated or the VPS reboots.
- Invalid REALITY handshakes can appear in raw logs and do not by themselves
  indicate a broken server or an attack.
- Test both transports on the actual Wi-Fi and mobile networks where they will be used.

<details>
<summary><strong>Recovery commands</strong></summary>

Fresh installations finalize automatically. Use these only when installation
or the health check explicitly reports a recovery condition.

```bash
vpn finalize --yes
vpn confirm-firewall --yes
vpn rollback-firewall --yes
vpn lockdown-ssh --yes
vpn self-update /root/install-sing-box-server.sh
```

</details>

<details>
<summary><strong>Development checks</strong></summary>

```bash
scripts/build-standalone.sh
bash -n src/*.sh scripts/build-standalone.sh install-sing-box-server.sh tests/*.sh
shellcheck --severity=style scripts/build-standalone.sh install-sing-box-server.sh tests/*.sh
bash tests/static-smoke.sh
bash tests/fingerprint-smoke.sh
bash tests/health-smoke.sh
bash tests/management-lifecycle-smoke.sh
bash tests/package-policy-smoke.sh
sudo bash tests/firewall-smoke.sh
./install-sing-box-server.sh plan
```

</details>

## Development note

This project was vibe-coded with AI assistance, then reviewed, tested, and
iterated on real Debian and Ubuntu VPS installations. Read the code and assess
the trade-offs before using it on infrastructure you do not control.

The `audit-target` heuristic is based on the TLS 1.3 post-handshake detection
research and MIT-licensed proof of concept in
[Aparecium](https://github.com/ban6cat6/aparecium) by ban6cat6. This project
uses only the narrow target-audit idea and does not vendor Aparecium or its Go
dependencies.

## License

The installer is released under the [MIT License](LICENSE). sing-box and system
packages retain their respective licenses.
