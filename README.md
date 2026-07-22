# sing-box-vps

A minimal interactive installer for a private sing-box server on a clean VPS.
It deploys two independent transports, private per-device subscriptions, and a
terminal-only management CLI with transactional updates and rollback.

## Features

- Installs the latest stable sing-box from its official signed repository.
- Runs VLESS + REALITY + Vision on TCP/443 and Hysteria2 + TLS on UDP/443.
- No web panel, Docker, statistics, telemetry, or access logging.

## Requirements

- Debian 13, Ubuntu 24.04 LTS, or Ubuntu 26.04 LTS on `amd64`;
- 1 vCPU, 1 GB RAM, and 10 GB disk;
- a real systemd boot, not WSL or a container without systemd;
- a public IPv4 address;
- a domain or subdomain with a direct `A` record to the VPS;
- a real reachable email address for the Let's Encrypt account;
- a one-line OpenSSH public key;
- a reviewed REALITY target supporting TLS 1.3 and HTTP/2.

The provider firewall or security group must allow the current SSH port,
TCP/80, TCP/443, TCP/8443, and UDP/443. The DNS record must not be hidden behind
a CDN or DNS proxy because Certbot uses the HTTP-01 standalone challenge.

## Quick install

Connect to the VPS as `root`, then run:

```bash
wget -qO vpn-install.sh https://raw.githubusercontent.com/stillnotfree/sing-box-vps/v1.0.2/install-sing-box-server.sh && chmod 700 vpn-install.sh && ./vpn-install.sh install
```

The installer asks for:

1. the administrative username to create;
2. the administrator's public SSH key;
3. the VPS public IPv4 address;
4. the TLS and subscription domain;
5. a real reachable Let's Encrypt account email;
6. the existing SSH port;
7. the REALITY target;
8. the VPS country from a numbered list;
9. the initial client TLS fingerprint.

It displays the complete plan before making changes and requires an explicit
`YES` confirmation. Failed runs keep validated settings and can be resumed by
running the same install command again.

## Finish the installation safely

Do not close the original SSH session. Within five minutes, open one new SSH
session using the administrator and private key configured during installation:

```bash
ssh ADMIN_USER@SERVER_IP
```

That verified key login automatically confirms the managed firewall, enables
key-only SSH, and removes the one-time login hook. No post-install command is
required. If the safety window expired first, the login reapplies the firewall
with a new rollback timer and asks for one more SSH login. Keep the earlier
session open until finalization reports success.

If an interrupted installation saved an ACME address that Let's Encrypt rejects,
resume it with a real address instead of reinstalling the VPS:

```bash
./vpn-install.sh install --email you@your-domain.com
```

Replace the example above with an address you actually receive mail at;
reserved `example.*` addresses are deliberately rejected by the installer.

The initial independent client is named `default`:

```bash
sudo vpn show default
```

This command prints private subscription URLs, direct import links, and QR
codes. Do not share its output.

## Commands

### Read-only checks

```bash
sudo vpn check
```

Checks OS, architecture, memory, disk, systemd, ports, and runtime compatibility.

```bash
sudo vpn status
```

Shows sing-box, nginx, nftables, SSH lockdown, congestion control, swap,
certificate timer, listeners, DNS, and client count.

```bash
sudo vpn diagnostic
```

Runs health checks for both transports, subscriptions, DNS, certificates,
Certbot, REALITY target, and nftables, followed by a redacted diagnostic report.
Review the report before sharing it.

### Client management

```bash
sudo vpn list
```

Lists clients without printing credentials.

```bash
sudo vpn add WorkPC
```

Creates an independent VLESS UUID, Hysteria2 password, and subscription token,
then displays the new subscription and QR code.

```bash
sudo vpn show WorkPC
```

Displays the existing client's subscription, direct links, and QR codes.

```bash
sudo vpn delete WorkPC --yes
```

Revokes the client's VLESS, Hysteria2, and subscription credentials. The last
remaining client cannot be deleted.

### Connection settings

```bash
sudo vpn set-target example.com
```

Validates TLS 1.3, HTTP/2, and the certificate before transactionally changing
the REALITY target and regenerating subscriptions. No target is automatically
selected or guaranteed to work through every network.

```bash
sudo vpn set-fingerprint
sudo vpn set-fingerprint firefox
```

Selects a client fingerprint interactively or directly. Supported values are
`chrome`, `firefox`, `safari`, `ios`, `android`, `edge`, `360`, `qq`, and
`random`. Subscription URLs remain unchanged; refresh them on each device.

### Updates and recovery

The following finalization commands are recovery tools; a normal fresh install
runs them automatically on the first administrator SSH login.

```bash
sudo vpn finalize --yes
```

Completes pending firewall confirmation and SSH hardening from a verified
administrator SSH session.

```bash
sudo vpn update
```

Updates sing-box from its official repository, validates the current
configuration, and restores the cached previous package if startup fails.

```bash
sudo vpn self-update /root/install-sing-box-server.sh
```

Applies an already downloaded newer installer file after syntax, project, and
version validation. Downgrades are rejected and the previous CLI is retained as
a rollback copy.

```bash
sudo vpn confirm-firewall --yes
sudo vpn rollback-firewall --yes
```

Confirms the managed nftables policy or restores the saved pre-install ruleset.

```bash
sudo vpn lockdown-ssh --yes
```

Enables key-only SSH. It must be run with `sudo` from a verified session of the
administrator created during installation.

```bash
sudo vpn help
```

Displays the built-in command reference.

## Subscriptions

Every client receives a stable random HTTPS subscription URL on TCP/8443. The
default response is a Base64 URI list containing VLESS and Hysteria2. Mihomo,
FlClash, and Clash Verge receive a complete Mihomo profile based on their
`User-Agent`; an explicit `/mihomo` suffix is also available. Frontends based
on sing-box or Xray receive the URI list; neither core defines a portable
cross-platform subscription document of its own.

Changing the REALITY target or fingerprint regenerates every representation
without changing subscription URLs. Regional routing and split tunneling remain
client policy and are not coupled to third-party rule providers. See
[docs/SUBSCRIPTIONS.md](docs/SUBSCRIPTIONS.md) for the format and threat model.

The installation domain is also the HTTPS subscription hostname and Hysteria2
TLS identity. Release 1.0.0 does not automate domain migration because clients
cannot portably replace their own saved subscription URL.

## System updates

Normal OS updates are supported:

```bash
sudo apt update
sudo apt upgrade
sudo vpn update
sudo vpn status
```

The sing-box package is held from unattended APT upgrades and is updated only
through `vpn update`, which performs validation and rollback. OS security
updates remain enabled without automatic reboot.

## What the installer configures

| Component | Configuration |
| --- | --- |
| Core | One stable sing-box package from the signed SagerNet repository |
| Primary | VLESS + REALITY + Vision, TCP/443 |
| Reserve | Hysteria2 + TLS with native HTTP/3 camouflage, UDP/443 |
| Subscription | Static nginx-light HTTPS service, TCP/8443 |
| Firewall | Native nftables with a five-minute rollback timer |
| SSH | Dedicated administrator, then optional key-only lockdown |
| TLS | Certbot renewal hook with certificate/key validation and rollback |
| Network | BBR + `fq` when supported and conservative Hysteria2 UDP ceilings |
| Storage | 1 GiB swap when absent and a 200 MiB / 30-day journal limit |
| Updates | Unattended OS security updates; transactional sing-box updates |

## Limitations

- No protocol, target, or fingerprint guarantees access through every current or future filter.
- Hysteria2 requires usable UDP and may be degraded by some networks.
- IPv6 server profiles, CDN transports, port hopping, panels, and traffic statistics are not configured.
- Client-side routing, GeoIP rules, and TLS fragmentation are not forced by the server.
- End-to-end tests must be performed from the actual Wi-Fi and mobile networks where the service will be used.

## Development checks

```bash
bash -n install-sing-box-server.sh
shellcheck --severity=style install-sing-box-server.sh
bash tests/static-smoke.sh
bash tests/fingerprint-smoke.sh
./install-sing-box-server.sh plan
```

## License

The installer is released under the [MIT License](LICENSE). sing-box and system
packages retain their respective licenses.
