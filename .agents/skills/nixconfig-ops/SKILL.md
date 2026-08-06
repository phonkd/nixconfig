---
name: nixconfig-ops
description: Runbook for operating the running homelab from this Mac — the `deploy <host> [branch]` command (deploy-rs) that rebuilds any NixOS host, the headscale/Tailscale mesh every homelab connection now rides (NOT the old sing-box proxy), checking service status and logs over ssh, querying Loki/Mimir, and sops secret hygiene. Use when deploying/rebuilding a host, restarting or debugging a live service, or when ssh to a homelab host hangs. Architecture and module-wiring questions belong to the `nixconfig` skill, not this one.
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
deploy observability -r  # build ON the target, not on 205 (see below)
deploy 203 --hostname 192.168.1.203   # connect over the LAN, not the tailnet
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
- **`--remote-build` / `-r` — fallback when 205 is offline.** Passes
  `--remote-build` to deploy-rs so the target host builds its own closure
  (every deploy node is `x86_64-linux`, so it can). Use it when the builder VM
  is down: `deploy observability -r`. Costs the target transient build deps in
  its own store (fine for incremental rebuilds; watch it on tight-disk hosts
  like observability's 20 GB Hetzner root). Default (no flag) still offloads to
  205, which is faster and spares the target.
- **`--hostname <addr>` — mandatory when the deploy updates tailscale.**
  `deploy.hostname` points at tailnet IPs, so deploy-rs's own ssh session
  rides tailscaled on the target; activating a tailscale package bump restarts
  `tailscaled.service` and **kills that session mid-activation**. Seen twice:
  203 aborted and magic-rolled back; observability stopped its units and never
  reached "start units", leaving headscale/grafana/loki/mimir/alloy down. So
  when `git diff` on the lock/inputs touches tailscale, deploy over a
  non-tailnet path: `deploy 203 --hostname 192.168.1.203`,
  `deploy observability --hostname 10.9.0.1` (wg-obs). Any other unrecognised
  flag is forwarded to deploy-rs too — notably `--ssh-opts` for the obs rescue
  path: `--ssh-opts "-o ProxyCommand=none -p 5432 -i $HOME/.ssh/id_ed25519_priv"`
  (spell the key path out — `~` does not expand inside the quotes).
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

**Who runs it:** the agent runs `deploy <host>` itself — including
`deploy 201` — the user has authorized this (they got tired of pasting deploy
output back). The command is short, magic rollback catches lost connectivity,
and re-running it is cheap. So after committing a change, deploy it yourself and
report the result rather than handing the command back. Two caveats that still
warrant a heads-up first: (1) a config that could come up *wrong-but-reachable*
on `201-mono` (magic rollback won't catch that — it only reverts on lost
connectivity), and (2) anything that would drop multiple hosts at once. When in
doubt on 201, deploy but watch the result and be ready to roll back.

## Connectivity: everything rides the headscale tailnet

**The sing-box SOCKS proxy is NO LONGER the homelab path** — do not reach for
`127.0.0.1:2080`, `socks5://`, or `192.168.x.x` addresses. Every homelab host is
an enrolled Tailscale node on a self-hosted headscale mesh (coordinator on
observability at `hs.phonkd.net`; see `plans/headscale-mesh.md`). Reach hosts
**by name** — `~/.ssh/config` maps each alias to its tailnet IP with
`ProxyCommand none`:

```
ssh 203-media 'systemctl status jellyfin'   # just works, from any network
ssh observability                            # alias `obs` too
```

Auth is **Tailscale SSH** — by tailnet identity + headscale ACL. There is no
port, key, or known_hosts entry to get right over the tailnet.

Host → tailnet IP: `204-agent=100.64.0.1`, `205-builder=100.64.0.2`,
`203-media=100.64.0.3`, `observability=100.64.0.4`, `201-mono=100.64.0.5`,
this Mac`=100.64.0.6`. `deploy.hostname` in `lib/registry.nix` points at these,
so `deploy` rides the tailnet too.

- **First move when a host hangs**: `tailscale status` — an `offline` peer is
  the host being down/unenrolled, not a proxy problem. `tailscale ping <ip>`
  checks peer reachability, but note it uses **disco**, which travels *outside*
  the WireGuard data session: a working `tailscale ping` with dead `ping`/ssh
  means a stale session — fix with `sudo systemctl restart tailscaled` on the
  far host (has happened live on obs).
- Non-ssh traffic goes **direct, no proxy**: `curl http://10.9.0.1:3100/ready`.
- In scripts use `ssh -o ConnectTimeout=8 -o BatchMode=yes` so an offline host
  fails fast instead of hanging.
- **SMB**: `smb://100.64.0.3` directly (203's samba `hosts allow` includes
  `100.64.0.0/10`). The old `smb://127.0.0.1:8445` sing-box forward is gone.
- **Non-enrolled LAN boxes** (Proxmox `192.168.3.47`, etc.) are reached by
  ssh-jump through 203 — `~/.ssh/config` has a `192.168.1.* 192.168.3.*` block
  with `ProxyCommand ssh phonkd@100.64.0.3 nc %h %p`. So they need 203 up.
- **sing-box still runs, but only for work + Spotify** (the bedag work VPN and
  the `domains` list in `modules/proxy.nix`). It is irrelevant to homelab ops —
  if it's down, homelab access is unaffected.
- **Break-glass when the tailnet is broken**: obs's real sshd is on **:5432**,
  reachable two non-tailnet ways, both wired up as aliases in `mac.nix` —
  `ssh obs-rescue` (over wg-obs, `10.9.0.1`) and `ssh obs-rescue-public`
  (obs's public IP `89.167.83.90`, works with wg-obs down too). The raw IPs
  match the same blocks, so `ssh 10.9.0.1` / `ssh 89.167.83.90` work as well.
  The blocks exist because those addresses otherwise fall through to the bedag
  `Host *` **socat SOCKS catch-all** (work repo, `modules/work/external.nix`)
  and fail as `peer might not be a socks4 server` / `Connection closed by
  UNKNOWN port 65535` — hence `ProxyCommand none`, plus the key obs actually
  accepts (`id_ed25519_priv`, not the catch-all's global `id_ed25519`).
  Homelab VMs are reachable on the LAN when you're on the home network,
  bypassing the jump block:
  `ssh -o ProxyCommand=none -i ~/.ssh/id_ed25519_priv phonkd@192.168.1.203`.

### 203 runs a ProtonVPN full tunnel — mind the ip rules

203 egresses all *general* traffic through a host-level ProtonVPN `wg-quick`
tunnel (`203-vpn` in `modules/hosts/203-media.nix`), while Tailscale bypasses it
via its fwmark. This only works if wg-quick's policy rules sit **below**
Tailscale's (5210/5270). wg-quick adds them with no explicit priority and
iproute2 picks "lowest existing − 1", so with tailscaled already up they land at
**5208/5209 — above Tailscale's — and blackhole the tailnet**. `postUp` re-pins
them to 32763/32764; check with `ip rule` if 203 loses the tailnet after a boot.
Symptom: `ping 100.64.0.x` 100% loss, `tailscale netcheck` → `UDP: false`,
`tailscale status` → `NoState`, and `tailscaled-autoconnect.service` timed out.
Recovery: pin the rules, then `systemctl restart tailscaled-autoconnect`.

## Inspecting a live service

```
ssh 203-media 'systemctl status jellyfin --no-pager -l'
ssh 203-media 'journalctl -u jellyfin --since -1h --no-pager | tail -50'
```

Status/journal reads work unprivileged for most units. All servers have
passwordless sudo for `phonkd` (`security.sudo.wheelNeedsPassword = false`) —
that's what lets deploy-rs and `systemctl restart` work non-interactively.

Prefer Loki over ssh-journalctl when comparing across hosts or time ranges:

```
curl -s 'http://10.9.0.1:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={host="203-media", unit="jellyfin.service"}' \
  --data-urlencode 'since=1h'
```

(No proxy — 10.9.0.1 is the wg-obs tunnel and is reachable directly from the
Mac. Mimir is `:9009` on the same host.)

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
