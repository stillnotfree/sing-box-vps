# sing-box-vps

A minimal interactive installer for a private sing-box server on a clean VPS.
It is designed for a small personal server that should be easy to install,
update, and manage without a web panel.

## Features

- Installs the latest stable sing-box from its official signed repository.
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
wget -qO vpn-install.sh https://raw.githubusercontent.com/stillnotfree/sing-box-vps/v1.0.5/install-sing-box-server.sh && chmod 700 vpn-install.sh && ./vpn-install.sh install
```

The installer asks for the administrator, public SSH key, VPS address, domain,
email, current SSH port, REALITY target, VPS country, and client fingerprint. It
shows the complete plan before making changes and waits for an explicit `YES`.
An interrupted installation can normally be resumed with the same command.

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
sudo vpn show default
```

Do not share this output: the links contain client credentials.

## Commands

| Task | Command |
| --- | --- |
| Show server state | `sudo vpn status` |
| Run share-safe diagnostics | `sudo vpn diagnostic` |
| Check installation compatibility | `sudo vpn check` |
| List clients | `sudo vpn list` |
| Show links and QR codes | `sudo vpn show NAME` |
| Add an independent client | `sudo vpn add NAME` |
| Revoke a client | `sudo vpn delete NAME --yes` |
| Update sing-box safely | `sudo vpn update` |
| Change the REALITY target | `sudo vpn set-target DOMAIN` |
| Select a client fingerprint | `sudo vpn set-fingerprint` |
| Use native Hysteria2/QUIC | `sudo vpn set-obfs off` |
| Enable Salamander | `sudo vpn set-obfs salamander` |
| Show built-in help | `sudo vpn help` |

Target, fingerprint, obfuscation, client, and update changes are validated and
applied transactionally. Existing subscription URLs remain stable; refresh the
subscription in clients after changing connection settings.

## System updates

Normal operating-system updates are supported:

```bash
sudo apt update
sudo apt upgrade
sudo vpn update
sudo vpn status
```

OS security updates are enabled automatically without automatic reboot.
sing-box is updated separately by `vpn update`, which validates the current
configuration and can restore the cached previous package if startup fails.

## What the installer configures

| Component | Configuration |
| --- | --- |
| Core | Stable sing-box from the signed SagerNet repository |
| Primary | VLESS + REALITY + Vision on TCP/443 |
| Reserve | Hysteria2 + TLS on UDP/443; native QUIC by default, optional Salamander |
| Clients | Independent credentials, HTTPS subscription, links, and QR codes |
| SSH | Dedicated administrator, public-key authentication, root/password login disabled |
| Firewall | Native nftables with a temporary automatic rollback window |
| TLS | Let's Encrypt certificate with tested automatic renewal |
| Network | BBR + `fq` when supported and conservative UDP buffer ceilings |
| Storage | 1 GiB swap when absent and a 200 MiB / 30-day journal limit |
| Updates | Automatic OS security updates and transactional sing-box updates |

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
- IPv6 profiles, CDN transports, port hopping, panels, and traffic statistics are not configured.
- Client routing and TLS fragmentation are not forced by the server.
- Test both transports on the actual Wi-Fi and mobile networks where they will be used.

<details>
<summary><strong>Recovery commands</strong></summary>

Fresh installations finalize automatically. Use these only when installation
or diagnostics explicitly report a recovery condition.

```bash
sudo vpn finalize --yes
sudo vpn confirm-firewall --yes
sudo vpn rollback-firewall --yes
sudo vpn lockdown-ssh --yes
sudo vpn self-update /root/install-sing-box-server.sh
```

If Let's Encrypt rejected an email saved during an interrupted installation:

```bash
./vpn-install.sh install --email you@your-domain.com
```

</details>

<details>
<summary><strong>Development checks</strong></summary>

```bash
bash -n install-sing-box-server.sh
shellcheck --severity=style install-sing-box-server.sh
bash tests/static-smoke.sh
bash tests/fingerprint-smoke.sh
./install-sing-box-server.sh plan
```

</details>

## Development note

This project was vibe-coded with AI assistance, then reviewed, tested, and
iterated on real Debian and Ubuntu VPS installations. Read the code and assess
the trade-offs before using it on infrastructure you do not control.

## License

The installer is released under the [MIT License](LICENSE). sing-box and system
packages retain their respective licenses.
