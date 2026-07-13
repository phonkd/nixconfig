---
name: nixconfig-ops
description: Runbook for operating the running homelab from this Mac — rebuild/deploy commands per host, the sing-box SOCKS proxy every homelab connection depends on, checking service status and logs on hosts over ssh, querying Loki/Mimir, and sops secret hygiene. Use when deploying, restarting or debugging a live service, or when ssh/curl to 192.168.x.x or 10.9.0.1 hangs. Architecture and module-wiring questions belong to the `nixconfig` skill, not this one.
---

# Operating the homelab

Companion to the `nixconfig` skill: that one explains how the config is *wired*,
this one is the runbook for the *running* systems. Facts marked ✅ were verified
live on 2026-07-13; ⚠️ means unconfirmed — ask before relying on it.

## Ground rule: who deploys

Claude edits and commits to `main`; **the user pushes and rebuilds on targets**.
Only run a rebuild yourself when explicitly asked in that session. (Restarting a
single service to test a change is a smaller ask than a rebuild, but still confirm
first — 201 fronts every other service.)

## Connectivity: everything rides the sing-box SOCKS proxy

The Mac reaches ALL homelab and WireGuard targets through a local SOCKS5 proxy at
`127.0.0.1:2080` (sing-box, configured in `modules/hosts/mac.nix`). `~/.ssh/config`
already routes `192.168.1.x`, `192.168.3.x` and `10.9.0.0` through it, so plain
`ssh 192.168.3.203` works ✅ — but only while sing-box is up.

- **First move when anything hangs**: `nc -z 127.0.0.1 2080` — if that fails, the
  proxy is down and no recipe below will work.
- Non-ssh traffic needs the proxy explicitly:
  `curl -sx socks5://127.0.0.1:2080 http://10.9.0.1:3100/ready` ✅ (Loki; Mimir
  :9009, Grafana :3000 same pattern).
- In scripts always use `ssh -o ConnectTimeout=6 -o BatchMode=yes` so a dead proxy
  fails fast instead of hanging the session.
- SMB to 203 can't use SOCKS; sing-box forwards `smb://127.0.0.1:8445` instead.

## Rebuild / deploy

**This Mac** (registry host `Eliss-MacBook-Pro`) — verified from shell history:

```
sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake ~/git/nixconfig --impure
```

⚠️ `--impure` is load-bearing (rebuilds fail without it — reason undocumented) and
the `nix-darwin-26.05` ref must track the flake's nixpkgs branch on upgrades.

**NixOS servers** — the two verified hosts differ ⚠️:

- `203-media` has a checkout at `~/nixconfig` ✅ → ssh in, `git pull`, then
  `sudo nixos-rebuild switch --flake ~/nixconfig#203-media`.
- `201-mono` has **no** checkout ✅ → presumably
  `sudo nixos-rebuild switch --flake github:phonkd/nixconfig#201-mono` (⚠️ exact
  invocation unconfirmed; requires the commit to be *pushed*, not just committed).

`sudo` over ssh may prompt for a password ⚠️ — assume remote rebuilds are
interactive-only (i.e. the user's job) until proven otherwise. x86_64-linux builds
from the Mac offload to `205-builder` automatically (distributed builds,
`modules/hosts/mac.nix`).

## Inspecting a live service

```
ssh 192.168.3.203 'systemctl status jellyfin --no-pager -l'
ssh 192.168.3.203 'journalctl -u jellyfin --since -1h --no-pager | tail -50'
```

Reading status/journal works unprivileged for most units; `systemctl restart`
needs sudo (see caveat above). Host→IP map: 201-mono=.3.201, 203-media=.3.203
(also 192.168.1.203), 204-agent=.3.204, 205-builder=.3.205; `observability` is
only 10.9.0.1 over WireGuard.

Prefer Loki over ssh-journalctl when comparing across hosts or time ranges:

```
curl -sx socks5://127.0.0.1:2080 'http://10.9.0.1:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={host="203-media", unit="jellyfin.service"}' \
  --data-urlencode 'since=1h'
```

(⚠️ label names unverified — check with `.../loki/api/v1/labels` first.)

## Secrets hygiene (ops side — wiring is in the `nixconfig` skill)

- Sanity-check after editing: `sops -d --output /dev/null modules/homelab/global-secrets/secret.yaml` ✅
- Non-interactive add/update:
  `sops set modules/homelab/global-secrets/secret.yaml '["key-name"]' '"value"'`
- The age key that can edit lives at `~/.config/sops/age/keys.txt` on this Mac.
  A secret only lands on a host after the *next rebuild of that host* — editing
  the yaml alone changes nothing live.

## Alert rules

`mimir-rules-sync` pushes rules on rebuild of the observability host. If running
`mimirtool rules sync` by hand: **always** `--namespaces=...` — unscoped sync is a
mirror op and deletes every other namespace in the tenant (has happened live).
