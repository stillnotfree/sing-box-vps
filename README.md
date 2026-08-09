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
wget -qO vpn-install.sh https://raw.githubusercontent.com/stillnotfree/sing-box-vps/main/install-sing-box-server.sh && chmod 700 vpn-install.sh && ./vpn-install.sh install
```

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
question-driven install, leave it out. An audit warning is accepted only
through the interactive choice.

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
| Show detailed redacted health data | `vpn health --verbose` |
| Check installation compatibility | `vpn check` |
| List clients | `vpn show` |
| Show private links and QR codes | `vpn show NAME` |
| Add an independent client | `vpn add NAME` |
| Revoke a client | `vpn delete NAME --yes` |
| Update sing-box safely | `vpn update` |
| Audit a REALITY target | `vpn audit-target [DOMAIN]` |
| Change the REALITY target | `vpn set-target DOMAIN` |
| Select a client fingerprint | `vpn set-fingerprint` |
| Use native Hysteria2/QUIC | `vpn set-obfs off` |
| Enable Salamander | `vpn set-obfs salamander` |
| Show built-in help | `vpn help` |

The installed `vpn` command obtains its required administrative privileges
automatically. You do not need to prefix it with `sudo`.

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

OS security updates are enabled automatically without automatic reboot.
sing-box is updated separately by `vpn update`, which validates the current
configuration and can restore the cached previous package if startup fails.

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
| Updates | Automatic OS security updates and transactional sing-box updates |

The installer owns only `table inet vpn_filter`; it does not flush unrelated
nftables tables.

## Subscriptions

Each client receives an unguessable HTTPS subscription URL on TCP/8443. The
same URL serves a Base64 VLESS/Hysteria2 list or a complete Mihomo profile based
on the client `User-Agent`; `/mihomo` is also available explicitly. Routing,
split tunneling, and GeoIP policy remain the responsibility of the client.

See [docs/SUBSCRIPTIONS.md](docs/SUBSCRIPTIONS.md) for compatibility details and
the subscription threat model.

## Limitations

- No protocol, REALITY target, or fingerprint is guaranteed to bypass every network filter.
- Hysteria2 requires usable UDP and may be degraded by some networks.
- The installer deliberately accepts only the tested sing-box 1.13 release line.
- IPv6 profiles, CDN transports, port hopping, panels, and traffic statistics are not configured.
- Client routing and TLS fragmentation are not forced by the server.
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
