# Development and verification

This document contains durable maintainer details. Start with `AGENTS.md`, then
read only the section relevant to the current issue.

Future coding tasks should stay bounded and use this shape:

```text
Goal:
Problem and current evidence:
Acceptance criteria:
Constraints:
Verification:
```

Search for the named symbols first and open only linked documentation relevant
to the issue. The Russia-network research is needed only for protocol, DPI,
routing, or connectivity decisions.

## Source and standalone model

The ordered files in `src/` are the source of truth. The module order is declared
once in `scripts/build-standalone.sh`; it produces the public, self-contained
`install-sing-box-server.sh`. Top-level functions and heredocs must stay wholly
inside one module.

After any module change:

```bash
scripts/build-standalone.sh
git diff --exit-code -- install-sing-box-server.sh
```

The second command is the freshness check used by CI after generation. During
normal development it is expected to show a generated diff until that artifact
is intentionally included with the source change.

## Local checks

Run the complete repository suite from the root:

```bash
scripts/build-standalone.sh
git diff --check
bash -n src/*.sh scripts/build-standalone.sh install-sing-box-server.sh tests/*.sh
shellcheck --severity=style scripts/build-standalone.sh install-sing-box-server.sh tests/*.sh
bash tests/static-smoke.sh
bash tests/fingerprint-smoke.sh
bash tests/health-smoke.sh
bash tests/management-lifecycle-smoke.sh
bash tests/package-policy-smoke.sh
./install-sing-box-server.sh plan
```

On Linux with nftables, also run `sudo bash tests/firewall-smoke.sh`. The macOS
suite cannot prove Linux systemd, APT, nftables, kernel, listener, or qdisc
behavior. A JSON-validating test stub also does not replace `sing-box check`
against the supported real binary.

The compatibility window is defined by `SING_BOX_MIN_VERSION` and
`SING_BOX_MAX_EXCLUSIVE` in `src/00-preamble.sh`. A release candidate must be
checked with a real package version inside that interval. The current smoke
fixture is `1.13.16`; that fixture is not proof that a real `1.13.16` binary or
the latest repository candidate was executed in the current environment.

## Expanded testing triggers

- Generated config or protocols: parse the generated JSON, run real
  `sing-box check`, and verify the exact two-inbound topology.
- Firewall: run the Linux nftables smoke test and confirm unrelated tables
  survive apply, confirmation, and rollback.
- Health or diagnostics: cover healthy and failing states, bounded timeouts,
  redaction, exit codes, and the permanent client-path/provider boundary.
- Certificates: cover invalid and expiring files, ACME/deployed-copy mismatch,
  served-certificate mismatch, hook rollback, and both service reloads.
- Clients/settings/obfs/target: cover commit failure, exact restoration, unchanged
  credentials for other clients, and subscription revocation.
- Packages/upgrade: cover security-only unattended upgrades, APT hold, private
  `_apt` staging, candidate validation, service failure, and rollback package.
- SSH/systemd: validate generated files, service state, key-only policy, and the
  first-login firewall finalization path on a clean VM/VPS.

## Rollback testing

Use temporary paths and mocked commands for unit-like transaction failures. Save
the exact pre-operation files, inject one failure after publication starts, then
assert byte-for-byte restoration and active-service checks. Never use real
credentials in fixtures.

Firewall rollback additionally needs a disposable Linux VM/VPS: preserve any
pre-existing `inet vpn_filter` baseline, arm the transient timer, apply the
candidate, exercise both automatic rollback and explicit confirmation, and
prove that unrelated nftables tables remain unchanged. Keep the original SSH
session open.

Certificate-hook rollback must cover failure after certificate replacement and
after each service reload. The previous sing-box certificate copy must be
restored, nginx must serve the current Certbot-managed ACME certificate, and
both services must return active.

## Clean-install and release evidence

Static and CI checks are necessary but not clean-install proof. Before release,
install on a fresh supported Debian or Ubuntu `amd64` VPS and record only
non-secret results for prompts, ACME, service startup, firewall finalization,
health before/after reboot, both protocols, client add/delete, subscription 404,
transaction cancellation/acceptance, NTP/qdisc, unattended-upgrades policy, and
the sing-box APT hold.

Verify that the committed standalone equals a fresh build and note its SHA-256.
The current README bootstrap downloads mutable `main`; that is a trust boundary,
not by itself a demonstrated exploit. A low-complexity release procedure is:

1. publish the reviewed standalone at a versioned release/tag;
2. publish its SHA-256 through a separately reviewed release channel;
3. have users download, verify, and only then execute it as root.

A checksum fetched only from the same mutable location is not an independent
trust anchor. Do not introduce custom PKI, TUF, cosign infrastructure, or an
update daemon solely to change this boundary.

Release verification must explicitly separate local/CI results, clean-VPS
runtime evidence, and external client-network evidence. If no external client
probe ran, state: `Censorship/client-path reachability was not tested.`
