# Repository instructions

## Purpose and scope

- This repository builds a minimal, self-contained Bash installer for a private
  sing-box VPS. It is not a panel, fleet manager, or client-routing project.
- Work only in this repository. Inspect the current implementation and Git state
  before relying on an issue description, handoff, or historical audit.
- Prefer the smallest coherent change that fixes a reproduced defect or satisfies
  an explicit acceptance criterion. Do not add speculative compatibility paths.

## Production topology

- TCP/443: one public VLESS + REALITY + Vision inbound.
- UDP/443: one public Hysteria2 + TLS inbound.
- TCP/8443: private tokenized HTTPS subscriptions served by nginx-light.
- TCP/80: ACME HTTP-01 validation. The configured SSH port remains public.
- One sing-box core is used. Do not add Xray, a second proxy core, third proxy
  inbound, automatic fallback/cascade, Docker, a panel, database, metrics,
  telemetry, statistics, or access logging.
- Client routing, split tunneling, censorship detection, and provider firewall
  APIs are outside the server installer's scope.

## Source and generated artifact

- `src/*.sh` is the authoritative installer source.
- `install-sing-box-server.sh` is the committed generated standalone artifact.
  Never edit it directly.
- `scripts/build-standalone.sh` concatenates modules in a fixed order and must run
  after every source-module change.
- Runtime installation must not depend on Git, repository modules, or fetching
  project code after the standalone file has been downloaded.
- CI must fail if the committed standalone differs from a fresh generation.

## Module map

- `src/00-preamble.sh`: shell policy, constants, paths, compatibility window.
- `src/10-runtime-cli.sh`: logging, traps, locks, parsing, help.
- `src/20-validation-settings.sh`: validation, prompts, persisted settings.
- `src/30-preflight-packages.sh`: plan, platform checks, packages, repositories.
- `src/40-system-tls.sh`: host setup, DNS, REALITY audit, certificates.
- `src/50-core-clients.sh`: sing-box config, clients, subscriptions, mutations.
- `src/60-helper-firewall-ssh.sh`: helper, systemd, nftables, SSH finalization.
- `src/70-update-health.sh`: sing-box update and health diagnostics.
- `src/80-upgrade-install.sh`: overlay upgrade, rollback, install orchestration.
- `src/90-main.sh`: command validation and dispatch.
- Keep module boundaries at top-level function boundaries. Never split a function
  or heredoc across modules.

## Supported platform and compatibility

- Supported clean hosts: Debian 13, Ubuntu 24.04 LTS, or Ubuntu 26.04 LTS,
  `amd64`, real systemd boot, public IPv4.
- The authoritative sing-box compatibility bounds are
  `SING_BOX_MIN_VERSION` and `SING_BOX_MAX_EXCLUSIVE` in
  `src/00-preamble.sh`; tests must match them.
- The installer targets a clean supported system. Do not add legacy aliases,
  deprecated-state fallbacks, migration shims, or obsolete release branches.
- Preserve only the supported upgrade path from complete, validated managed
  state of the current published release.

## Security and reliability invariants

- The firewall owns only `table inet vpn_filter`. Never flush or replace the
  global nftables ruleset or alter unrelated tables.
- SSH ends key-only with root and password login disabled. Do not weaken the
  staged first-login rollback/finalization flow.
- Secrets, subscription URLs, UUIDs, passwords, private keys, IP addresses, and
  domains must not appear in committed fixtures or shareable diagnostics.
- Logs and health/debug output are bounded and redacted. Treat redaction as
  defense in depth; users must still review output before sharing it.
- Downloads and network probes need timeouts and bounded output. Never scan
  address ranges or infer DPI/censorship from a generic timeout.
- Client, target, fingerprint, obfs, update, certificate, and managed-runtime
  changes must remain transactional. Validate staged state before publication;
  on failure restore the exact previous managed state.
- Certificate health must distinguish ACME files, deployed sing-box copies, and
  the certificate actually served by the local subscription endpoint.
- Health is server-side evidence only. It must always state that client-path
  reachability was not tested and that the provider firewall is unknown without
  an external probe.
- Automatic OS updates remain security-only, automatic reboot remains disabled,
  and sing-box remains APT-held for `vpn update`.

## Change discipline

- Search for the current symbol and existing tests before reading whole files or
  adding a new abstraction.
- Preserve existing good structure; do not rewrite working components to satisfy
  stylistic preferences.
- Avoid generic hardening claims. Report a security defect only with a concrete
  code path, violated invariant, or reproducible failure.
- Protocol, listener, firewall, SSH, certificate, package, state-schema, or
  transaction changes require expanded targeted tests plus the full suite.
- Documentation-only changes still require generated freshness, diff checking,
  and relevant static checks.
- Keep research observations separate from product requirements. Consult the
  Russia-network research only for protocol, DPI, routing, or connectivity work.
- Do not commit, push, merge, tag, release, or publish without explicit approval.
- Preserve unrelated and untracked user files, including `.codex/` and review
  artifacts.

## Required checks

Run from the repository root before a commit:

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

On Linux with nftables, also run:

```bash
sudo bash tests/firewall-smoke.sh
```

Record separately whether a real clean VPS install, real sing-box binary check,
and external client-network probe were actually performed.

## Detailed documentation

- Development, testing, release, and rollback: `docs/development.md`.
- Subscription boundary and client formats: `docs/SUBSCRIPTIONS.md`.
- Connectivity evidence from Russian networks:
  `docs/research/russia-network-findings.md`.
- User operation and troubleshooting: `README.md` and `README_RU.md`.
- Vulnerability reporting and log-sharing rules: `SECURITY.md`.
