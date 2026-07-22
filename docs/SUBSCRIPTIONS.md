# Subscription design

Subscription delivery is included in the 1.0.0 release candidate. This document
describes its security boundary and the compatibility model that must be tested
on a fresh VPS before the public release is tagged.

## Goal

Each client should import one URL instead of two protocol links. When the
REALITY target, fingerprint, address, or another exported parameter changes,
the user updates the subscription in the client application without importing
the nodes again.

The subscription URL is configuration material, not an authentication protocol:
anyone who obtains it receives that client's VLESS UUID and Hysteria2 password.

## Considered approaches

| Approach | Advantages | Problems | Decision |
| --- | --- | --- | --- |
| Static multi-format HTTPS files served locally | Small, auditable, no database API or panel | Adds a web server and one TCP port; client detection is imperfect | Implemented |
| Full web panel | Convenient UI | Large attack surface, database, sessions, frequent updates | Reject |
| GitHub, gist, paste service or public converter | No service on the VPS | Gives credentials to a third party and can leak them publicly | Reject |
| Plain HTTP | Very small | Subscription tokens and credentials are exposed in transit | Reject |
| Custom Python/Go HTTP server | Can be tiny | Becomes security-sensitive code maintained by this project | Reject |
| Reuse the REALITY listener on TCP/443 | No extra public port | Complex fallback coupling and difficult rollback | Reject for the base design |

## Implemented design

Use `nginx-light` as a static HTTPS server on TCP/8443 with the existing
Let's Encrypt certificate. It should expose no index, API, upload, panel, or
directory listing.

Each VPN client receives an independent random 256-bit bearer token. Tokens are
stored only in the root-readable client database. A URL has this form:

```text
https://vpn.example.com:8443/s/64_HEXADECIMAL_CHARACTERS
```

The client-facing URL remains the same, but there is no universal subscription
payload understood by every application. The project therefore generates all
supported representations atomically from the same client record:

- a Base64-encoded URI list with one `vless://` and one `hysteria2://` entry for
  Shadowrocket, Happ/Hiddify, v2rayN-like clients, and the compatibility fallback;
- a complete Mihomo YAML profile for FlClash, Clash Verge, and other Mihomo
  frontends;
- direct URI import remains available through `vpn show` when an application
  cannot consume a remote subscription.

An nginx `map` selects a pre-generated static file from a conservative
`User-Agent` allowlist. Mihomo frontends receive the Mihomo profile; known
sing-box/Xray frontends and unknown clients receive the Base64 URI list. An
explicit `/mihomo` suffix remains available when an application sends a generic
or undocumented `User-Agent`. Thus the normal user experience is one stable
URL, while troubleshooting does not depend on an external converter or a
dynamic web backend.

Base64 is only a compatibility encoding and provides no secrecy; confidentiality
comes from HTTPS and the unguessable bearer token. User-Agent detection is a
compatibility aid, not a protocol guarantee, so each named client and version
must be covered by an integration test before it is listed as supported.

Required HTTP properties:

- TLS only, using the managed certificate;
- `GET` and `HEAD` only;
- `Cache-Control: no-store`;
- `X-Content-Type-Options: nosniff`;
- access log disabled so bearer tokens are not written to disk;
- no token in a query string;
- `Vary: User-Agent` because the representation can differ for one URL;
- `profile-update-interval: 24` as a compatible daily-refresh hint;
- exact token-length validation and no filesystem path supplied by the request;
- worker runs as the distribution's unprivileged `www-data` account;
- subscription files are static, atomic, and not writable by nginx.

TCP/8443 must be explicitly allowed by both nftables and the provider firewall.
Using a separate port keeps subscription retrieval independent of whether the
old REALITY target still connects. A separate optional CDN hostname could make
retrieval survive client-side blocking of the origin IP, but that introduces a
provider dependency and must not be the default.

## CLI

```text
vpn add NAME          Create credentials and immediately print the URL and QR
vpn show NAME         Print the existing URL, QR, and direct fallback links
vpn delete NAME       Revoke protocol credentials and the subscription URL
vpn list              List clients without printing secrets
vpn set-target DOMAIN Validate and transactionally change the REALITY target
vpn set-fingerprint   Interactively select and transactionally publish a fingerprint
vpn set-fingerprint VALUE  Use an explicit supported fingerprint
```

`set-target` stages the settings, sing-box configuration, and all
subscription files in a private temporary directory; validate the target and
candidate configuration; atomically replace files; restart sing-box; perform a
local health check; and restore the previous state on any failure. The stable
subscription URL does not change, so the user only presses Update in the client.

`set-fingerprint` changes client material only. It stages the settings and all
subscription representations, verifies that both the decoded VLESS URI and the
Mihomo profile contain the requested fingerprint, atomically publishes them,
and checks sing-box plus the HTTPS subscription service. On failure it restores
the previous settings and subscription tree. It does not restart sing-box
because the REALITY server inbound has no client-fingerprint setting.

The cross-format compatibility set is `chrome`, `firefox`, `safari`, `ios`,
`android`, `edge`, `360`, `qq`, and `random`. `randomized` is excluded because
current Mihomo documentation does not list it, even though Xray and sing-box do.
The installer does not rotate fingerprints automatically.

Client deletion removes both credentials and the corresponding subscription
files. Client creation generates a new token. Certificate renewal tests the
nginx configuration and reloads both nginx and sing-box; the deployed sing-box
certificate copy is restored if either reload path fails.

## Compatibility boundary

Shadowrocket supports URL subscriptions and manual/background updates, but node
sharing formats are not standardized between applications. Hiddify documents
V2Ray URI lists, Clash, and sing-box profiles; FlClash is a Mihomo frontend and
therefore needs a valid Mihomo configuration. A native sing-box remote profile
would be a complete JSON configuration whose routing, DNS, paths, TUN policy,
and privilege model are platform-specific. The project therefore does not
advertise a misleading universal sing-box JSON. Frontends based on sing-box or
Xray that accept V2Ray-style URI subscriptions use the URI fallback. Unknown
applications also receive that conservative fallback.

The generated Mihomo profile sends private/local networks directly and all
other traffic through the selected VPN proxy. Regional GeoIP/geosite routing is
client policy and is deliberately not coupled to this server installer or to an
unreviewed third-party rule provider. A separate client routing configuration is
not replaced by this node subscription.

## Multiple independent VPS nodes

A second node means a separately installed VPS with a different public IP and,
where practical, another provider/ASN. It is not a second sing-box process on
the same host. A combined subscription can contain VLESS and Hysteria2 profiles
from both nodes, allowing an already updated client to switch when one origin
IP becomes unreachable.

The single-node installer must not silently exchange its root-readable client
database with another VPS. Multi-node enrollment, credential distribution, and
subscription aggregation belong to a separate optional fleet tool with its own
threat model. Until that component is designed and reviewed, install each node
independently and do not copy `/var/lib/vpn-setup` between servers.

## References

- [Shadowrocket community manual: subscriptions and updates](https://lowertop.github.io/Shadowrocket/)
- [Mihomo HTTP proxy providers](https://wiki.metacubex.one/en/config/proxy-providers/)
- [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [sing-box graphical clients](https://sing-box.sagernet.org/clients/)
- [Hiddify supported URL and subscription formats](https://hiddify.com/app/URL-Scheme/)
- [Happ supported links and parameters](https://www.happ.su/main/dev-docs/app-management)
- [FlClash repository](https://github.com/chen08209/FlClash)
