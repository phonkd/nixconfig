---
name: nixconfig-ops
description: Runbook for operating the running homelab from this Mac — the `deploy <host> [branch]` command (deploy-rs) that rebuilds any NixOS host, the sing-box SOCKS proxy every homelab connection depends on, checking service status and logs over ssh, querying Loki/Mimir, and sops secret hygiene. Use when deploying/rebuilding a host, restarting or debugging a live service, or when ssh/curl to 192.168.x.x or 10.9.0.1 hangs. Architecture and module-wiring questions belong to the `nixconfig` skill, not this one.
---

# Operating the homelab

Companion to the `nixconfig` skill: that one explains how the config is *wired*,
this one is the runbook for the *running* systems.

## Deploying: `deploy <host> [branch]`

NixOS hosts are rebuilt with one command (deploy-rs, defined in
`modules/deploy.nix`, wrapper on the Mac's PATH):

```
deploy 201            # rebuild 201-mono from the current checkout's committed HEAD
deploy 203 mybranch   # build + deploy 203-media from git branch `mybranch`
deploy --all          # every node
deploy --list         # show deployable hosts
```

- **Nodes** (opt in via `deploy.hostname` in `lib/registry.nix`): `201-mono`,
  `203-media`, `204-agent`, `205-builder`, `observability`. Short alias = the
  numeric prefix (`201`), full name also works.
- **Builds run on 205-builder.** deploy-rs builds from the Mac, and the Mac
  offloads every `x86_64-linux` derivation to 205 via `nix.buildMachines`
  (`modules/hosts/mac.nix`). Nothing host-side to trigger. (To move the build
  elsewhere later, that's the `nix.buildMachines` block, not the deploy tool.)
- **Magic rollback is on**: if a host drops off the network after activating
  (e.g. you break its networking or the reverse proxy), it auto-reverts to the
  previous generation. This is the safety net for 201, which fronts everything.
- **Git flake semantics — commit first.** `deploy 201` reads the flake at
  `~/git/nixconfig` = the *committed* HEAD; **uncommitted working-tree changes
  are NOT deployed**. Commit (to `main`, per the repo's workflow) before
  deploying, or pass a branch you've committed to. Set `NIXCONFIG_DIR` to point
  at a different checkout.
- **Before the wrapper is installed** (fresh Mac, or you just added it and
  haven't rebuilt the Mac yet): `nix run ~/git/nixconfig#deploy -- 201`.

**The Mac itself is not a deploy-rs node** (it's darwin). Rebuild it with:

```
sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake ~/git/nixconfig --impure
```

(`--impure` is load-bearing; keep the `nix-darwin-26.05` ref in step with the
flake's nixpkgs branch on upgrades.)

**Who runs it:** the command is short and safe enough for an agent to run for
non-critical hosts. For `201-mono` (reverse proxy, fronts every other service)
still confirm with the user first — magic rollback protects against *lost
connectivity*, not against a config that comes up wrong-but-reachable.

## Connectivity: everything rides the sing-box SOCKS proxy

The Mac reaches all homelab LAN targets through a local SOCKS5 proxy at
`127.0.0.1:2080` (sing-box, `modules/hosts/mac.nix`). `~/.ssh/config` routes
`192.168.1.x` / `192.168.3.x` through it, so `ssh 192.168.3.203` and deploy-rs
work — but only while sing-box is up. `observability` (10.9.0.1) is reached
directly over WireGuard (wg-obs), not the proxy.

- **First move when anything hangs**: `nc -z 127.0.0.1 2080` — if that fails the
  proxy is down and nothing below (or `deploy`) will work.
- Non-ssh traffic needs the proxy explicitly:
  `curl -sx socks5://127.0.0.1:2080 http://10.9.0.1:3100/ready` (that one is
  WireGuard-direct and works without the proxy too).
- In scripts use `ssh -o ConnectTimeout=6 -o BatchMode=yes` so a dead proxy
  fails fast instead of hanging.
- SMB to 203 can't use SOCKS; sing-box forwards `smb://127.0.0.1:8445` instead.

Host → address: 201-mono=192.168.3.201, 203-media=192.168.3.203 (also .1.203),
204-agent=192.168.3.204, 205-builder=192.168.3.205, observability=10.9.0.1 (wg).

## Inspecting a live service

```
ssh 192.168.3.203 'systemctl status jellyfin --no-pager -l'
ssh 192.168.3.203 'journalctl -u jellyfin --since -1h --no-pager | tail -50'
```

Status/journal reads work unprivileged for most units. All servers have
passwordless sudo for `phonkd` (`security.sudo.wheelNeedsPassword = false`) —
that's what lets deploy-rs and `systemctl restart` work non-interactively.

Prefer Loki over ssh-journalctl when comparing across hosts or time ranges:

```
curl -sx socks5://127.0.0.1:2080 'http://10.9.0.1:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={host="203-media", unit="jellyfin.service"}' \
  --data-urlencode 'since=1h'
```

(Label names unverified — check with `.../loki/api/v1/labels` first.)

## Secrets hygiene (ops side — wiring is in the `nixconfig` skill)

- Sanity-check after editing: `sops -d --output /dev/null modules/homelab/global-secrets/secret.yaml`
- Non-interactive add/update:
  `sops set modules/homelab/global-secrets/secret.yaml '["key-name"]' '"value"'`
- The age key that can edit lives at `~/.config/sops/age/keys.txt` on this Mac.
  A secret only lands on a host after the next `deploy` of that host — editing
  the yaml alone changes nothing live.

## Alert rules

`mimir-rules-sync` pushes rules on `deploy observability`. If running
`mimirtool rules sync` by hand: **always** `--namespaces=...` — unscoped sync is
a mirror op and deletes every other namespace in the tenant (has happened live).
