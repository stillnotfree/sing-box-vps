# Russian network observations

Telegram observations are evidence, not specification.

This compact record preserves reported field observations supplied to the
project. The source messages are not reproduced here and the IDs are provenance
handles, not independently verified measurements. They must not be converted
into a universal protocol ranking or an automatic installer policy.

## Independent protocol failure domains

- Project VLESS `489201`: REALITY/TLS reportedly degraded while Hysteria2 worked.
- Amnezia `1193369`: the reported result was the reverse.

These observations support testing TCP/443 REALITY and UDP/443 Hysteria2
separately. Success of either transport does not prove that the server IP, the
other transport, or a different access network is usable.

## Endpoint, path, ISP, and region

- Amnezia `1413755`: VPN, SSH, and ping reportedly failed; changing the IP made
  all three work.
- Related independent observations: `1345447`, `1410653`, `1412628`, `1416429`,
  `1412727`, and `1232735`.
- Project VLESS `457254`: failure reportedly depended on the operator, and IP
  replacement changed part of the result.
- Amnezia `1333244` and `1333247`: a handshake reportedly existed while traffic
  was nearly absent on one mobile network/region; Wi-Fi or another region worked.

Treat endpoint/IP, route, ISP, access technology, and region as separate
variables. A working service-side health check cannot identify which one is
responsible for a client-side failure.

## Handshake versus usable tunnel

Amnezia `1264419` reportedly showed that handshake or ICMP could pass while bulk
transfer stalled. A completed handshake is therefore not sufficient evidence of
a usable tunnel. Throughput and ordinary application traffic need separate,
bounded client-side testing.

## Client implementation

The same configuration was reported to behave differently in Happ,
Shadowrocket, and Karing. Client implementation and version are separate failure
domains; server configuration should not be changed before reproducing the
difference with controlled inputs.

## What the evidence does not establish

- XHTTP, XMUX, or fingerprint tuning is not a universal answer to path/IP
  failures.
- A fingerprint is an A/B compatibility knob, not a censorship guarantee.
- No automatically selected REALITY target or protocol is proven best for
  Russian networks.
- Naive and AnyTLS remain possible controlled experiments, not production
  defaults. A useful A/B comparison holds VPS, IP, ISP, client, destination,
  time window, and approximate load constant.

## MTU

The observations include cases consistent with MTU-related timeout or stall.
That makes MTU a symptom-driven troubleshooting branch, not a reason to change
the production default or add automatic MTU guessing.

## Operational use

For connectivity incidents, first establish server-side health, then compare
access networks, test TCP/443 and UDP/443 independently, check SSH or other
traffic to the same IP, compare another IP/VPS/hoster with protocol settings
held constant, and only then investigate client- or protocol-specific tuning.
Read `README.md` or `README_RU.md` for the user-facing sequence.
