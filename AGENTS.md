# Repository instructions

## Architecture

- `src/*.sh` is the authoritative installer source.
- `install-sing-box-server.sh` is a committed generated standalone artifact for end users. Do not edit it directly.
- `scripts/build-standalone.sh` concatenates the modules in a fixed order. Run it after every module change and commit the regenerated standalone file with the modules.
- Keep module boundaries at top-level Bash function boundaries. Never split a function or heredoc across modules.

Module ownership:

- `00-preamble.sh`: shell policy, constants, global state.
- `10-runtime-cli.sh`: logging, traps, locks, CLI parsing.
- `20-validation-settings.sh`: validation, prompts, persisted settings, installer metadata.
- `30-preflight-packages.sh`: plan, platform checks, package/repository handling.
- `40-system-tls.sh`: host configuration, DNS, REALITY target audit, certificates.
- `50-core-clients.sh`: sing-box configuration, clients, subscriptions, target/fingerprint/obfs transactions.
- `60-helper-firewall-ssh.sh`: installed helper, nftables, SSH finalization.
- `70-update-health.sh`: sing-box updates and health reporting.
- `80-upgrade-install.sh`: rollback metadata, upgrade and installation orchestration.
- `90-main.sh`: command validation and dispatch.

## Project policy

- The installer targets a clean supported Debian or Ubuntu system. Do not add legacy aliases, migration shims, deprecated state fallbacks, or compatibility branches for obsolete releases.
- Preserve the supported upgrade path from the current published release only when the maintained state schema is complete and valid.
- The firewall may manage only `table inet vpn_filter`; never flush or replace the global nftables ruleset.
- Keep the public artifact self-contained: runtime installation must not depend on the repository, module files, Git, or a network fetch of project code.
- Do not commit, push, tag, or publish without explicit user approval.

## Required checks

Run from the repository root:

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
