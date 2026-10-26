# Headscale security update

**Repo(s):** nixconfig   **Status:** done

## Goal

Update only the Hetzner observability VM's Headscale package to native 0.29.6,
built with Go 1.27.3, fixing the public HTTP/2 and TLS dependency gap. The user
explicitly requested a local-main commit and deployment for this change; the
broader October security PR remains separate and is not merged or pushed.

## Approach

Add a dedicated nixpkgs input at `8544a89fdbf2cf0ad9da7a6cfb02e4b28c2c3a86`
and select its native package through `services.headscale.package`, gated on
`observability-server`. Do not change other package inputs, add overrides or
custom units, or replace unrelated runtime database-managed ACL rules. The user
approved adding `autogroup:internet:*` to preserve exit-node access: 0.29's `*`
now covers only tailnet addresses. Apply that same targeted edit to the exported
active policy with the native CLI, and record it in the repository policy.

## Steps

- [x] Inspect main, shared-checkout state, package sources and running version.
- [x] Add the scoped input/package selection and parse changed Nix/lock files.
- [x] Verify the running database-managed policy with the new native CLI.
- [x] Commit on local main in an isolated worktree; preserve other sessions.
- [x] Back up state consistently and deploy observability over public SSH.
- [x] Verify Headscale version, HTTPS health, DERP and tailnet connectivity.

## Risks / rollout

Observed runtime: Headscale 0.28.0 built with Go 1.26.7. The supported 0.28 to
0.29 transition applies database migrations and changes ACL wildcard, SSH rule
validation and hostname handling. Validate the active policy, not the repository
example. Keep a protected pre-upgrade backup of database, keys, configuration
and old system-generation path; reverting only the binary is not a safe
minor-version rollback. No secrets are printed or inspected.

Deploy only observability via `89.167.83.90:5432`, not through the coordinator's
own tailnet. Use the native deploy command; do not perform separate full-host
evaluation/build verification. Other hosts and the security PR are untouched.

## Evidence

The native 0.29.6 package was fetched from cache.nixos.org and its `version`
command reports Go 1.27.3. All existing lock nodes and root inputs are unchanged;
only `nixpkgs-headscale` was added. Changed Nix parses and whitespace checks pass.

Protected backup on observability:
`/var/backups/headscale/pre-0.29.6-20261026.H2lanG`. The live SQLite online backup
passed `PRAGMA integrity_check`; configuration, non-database state and previous
system-generation path are retained alongside it. The native 0.29.6 policy check
against a separate migrated copy passed. The original database was not opened
by the new binary. A deprecated ephemeral timeout warning is non-fatal.

The active database policy was exported and inspected: its only packet rule is
`src: ["*"]`, `dst: ["*:*"]`; exit-node auto-approval and SSH rules are present.
Syntactic validation alone would not catch the lost exit-node access after 0.29's
wildcard change. User approval for the explicit internet permission was obtained
before changing policy or activating anything.

## Deployment result

Code commit: `838aa84` on local `main`, in the isolated worktree
`/tmp/opencode/nixconfig-headscale-main`. No push, security-PR merge or other-host
deployment occurred. The VM was behind main, so its ordinary system activation
also refreshed existing services, including SSH and Tailscale; the dry activation
preview identified this before rollout.

The first deploy reached Headscale 0.29.6 and served clients, but deploy-rs missed
confirmation and automatically reverted the system generation. It did not revert
the migrated database: Headscale 0.28.0 then rejected the new `database_versions`
table and restarted repeatedly. The local deploy's SSH processes remained hung.
The precise transport/confirmation failure was not established; activation
included networking and SSH restarts.

Recovery: stop Headscale, preserve the failed post-migration database and sidecars
under `failed-activation-database/` inside the protected backup directory, restore
`pre-activation-with-internet.sqlite` with Headscale ownership, and start 0.28.0.
HTTPS health and DERP probes returned 200 again, with all services active. The
approved internet permission was retained. Terminate the stale local deploy
processes before retrying; do not manually drop schema tables to force a downgrade.

The user explicitly approved a second attempt with automatic binary rollback
disabled for this database migration. A fresh `pre-retry-0.28.sqlite` backup passed
integrity checks first. Native invocation (SSH opts also supplied the public port
5432, identity, and `ProxyCommand=none`):

```
NIXCONFIG_DIR=/tmp/opencode/nixconfig-headscale-main deploy observability main \
  --hostname 89.167.83.90 --ssh-opts '<public SSH options with keepalives>' \
  --magic-rollback=false --auto-rollback=false --activation-timeout=180 --no-progress
```

Use `--flag=value` for these extra value-taking flags: the wrapper otherwise
mistakes their separate values for positional branch arguments. No persistent
rollback configuration was changed. This retry returned activation success.

Verified after activation on 2026-10-26:

- Headscale reports **0.29.6**, built with **Go 1.27.3**; restart count is zero.
- Current system is
  `/nix/store/av79d7zj0nfba8ckz4d2kxkbykbg6dyx-nixos-system-observability-26.05.20261013.a033e66`.
- Public `/health`: **HTTP 200 over HTTP/2**; `/derp/probe`: **HTTP 200**.
- Headscale, Tailscale, Grafana, Loki, Mimir and Alloy are active; no failed units.
- Native policy check against the active database-managed policy passes and its
  explicit `autogroup:internet:*` permission is present. Only that packet-rule
  destination was edited in the exported runtime policy; unrelated rules remain.
- SQLite integrity check passes; **1 user and 20 nodes** remain.
- Fresh tailnet SSH succeeds to observability and 205-builder; Tailscale ping to
  observability succeeds. No new client enrolment or client exit-node selection
  was performed, so those flows are not claimed as end-to-end tested.

Keep the protected backups for any future coordinated database-plus-generation
rollback. A plain automatic generation rollback remains unsafe across this minor
version boundary. Unrelated Mimir ingestion series-limit errors were observed
during the failed attempt; they were not changed as part of this Headscale work.

- [Headscale 0.29.6](https://github.com/juanfont/headscale/releases/tag/v0.29.6):
  Go 1.27.3, x/net 0.60.0, x/text 0.42.0 and gRPC 1.83.2.
- [GO-2026-6617](https://pkg.go.dev/vuln/GO-2026-6617): HTTP/2 server crash,
  fixed in Go 1.26.9 / 1.27.2 and x/net 0.60.0. The configured public autocert
  listener advertises HTTP/2, independently of Traefik and tailnet ACLs.
- [GO-2026-6809](https://pkg.go.dev/vuln/GO-2026-6809): compromised-intermediate
  rejection, fixed in Go 1.26.10 / 1.27.3; system root filtering alone is not
  equivalent to this Go denylist.
- [Upgrade guide](https://headscale.net/stable/setup/upgrade/): advance one minor
  release at a time and back up before migration.
