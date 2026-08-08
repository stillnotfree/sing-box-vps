# Security policy

## Supported versions

Only the latest published release is supported with security fixes. Before
reporting a problem, update the local installer and verify the current release.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting through **Security → Advisories →
Report a vulnerability**:

https://github.com/stillnotfree/sing-box-vps/security/advisories/new

Do not open a public issue for an undisclosed vulnerability. Never include
subscription URLs, UUIDs, passwords, private keys, certificates, IP addresses,
domains, or unredacted installation logs in a report.

Include the affected release, operating system, threat scenario, reproduction
steps, and the smallest relevant code fragment. Reports are evaluated against
the documented project scope and supported platforms.

The installer retains at most five root-only, redacted installation logs of up
to 1 MiB each under `/var/log/vpn-setup/`. Redaction is defense in depth, not a
guarantee: review a log before sharing it and never commit logs to Git.
