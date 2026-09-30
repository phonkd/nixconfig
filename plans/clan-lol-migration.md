# clan.lol migration

**Repo(s):** nixconfig   **Status:** in-progress — Phase 1: `205-builder` live on clan-core, `204-agent` next

## Why

Decided 2026-09-30: move this flake onto clan-core. Not because it wins on
outcome — the investigation (bottom of this file, and in full at `e341024`)
found secrets is the only clear gain — but to be part of the clan community and
upstream what's missing instead of routing around it. So a gap is a
contribution candidate, not a reason to stop.

## Scope

**In:** the builder (hosts become clan machines), secrets (clan's store, then
vars), the module system (inventory, then clan services where roles fit),
eventually deploy (`clan machines update`).

**Out: networking.** Clan has no tailscale/headscale service, its `wireguard`
service is a star through a controller, and `zerotier` bootstraps off ZeroTier
Inc's root servers — and the tailnet itself is being reconsidered separately.
`modules/tailnet.nix` and `modules/homelab/apps/headscale.nix` stay plain
modules. Clan reaches hosts through `inventory.machines.<n>.deploy.targetHost`,
mirrored from `lib/registry.nix`'s `deploy.hostname`, which short-circuits
clan's own network probing entirely.

## Phases

### 1 — clan-core is the builder, one host at a time

`modules/builder.nix` routes every name in `clanHosts` through
`clan.machines.<name>` instead of `nixosSystem`. Both paths get the identical
module list (`nixosModulesFor`), so moving a host is a one-word edit plus a
deploy. deploy-rs is untouched: clan emits ordinary `nixosConfigurations` and
the two sets merge because names never overlap.

Done in the first commit:

- [x] `clan-core` input on the 26.05 branch, following our `nixpkgs`,
      `flake-parts`, `sops-nix`, `nix-darwin`. Verified no existing input moved
      (92 input paths, identical narHash).
- [x] `modules/parts.nix` no longer declares `flake.darwinModules` — clan-core
      does, with an incompatible type.
- [x] `clan.core.enableRecommendedDefaults = false` per machine,
      `clan.pkgsForSystem = _: null` (keep per-host `nixpkgs.config`).
- [x] Registry tags and `deploy.hostname` mirrored into
      `clan.inventory.machines` (as `phonkd@<ip>` — root login is off).
- [x] `clan` CLI in the devshell; `nix develop -c clan machines list` →
      `205-builder`.
- [x] `deploy 205` (2026-09-30, `652efad`): generation 12 → 13,
      `is-system-running` = `running`, no rollback. The closure diff is **not**
      a clean clan-only diff: it is dominated by the nixpkgs bump that landed in
      `2a3f5e3` (2026-08-29 → 2026-09-27: systemd 260.2 → 260.4, kernel
      6.18.48 → 6.18.54, glibc 2.42-67 → 84), which this deploy was the first
      to ship. Activation restarted sshd and tailscaled, the session riding
      the tailnet was cut before deploy-rs printed a result, and it survived
      anyway. The new kernel waits for a reboot.

**Every remaining server is still on the 2026-08-29 nixpkgs**, so its first
clan deploy also carries the systemd bump — deploy each one off-tailnet
(`nixconfig-ops` has why):

- [x] `204-agent` (`cf8a5d3`, over `192.168.3.204`): generation 77, confirmed,
      `running`. 204 already had the nixpkgs bump, so this is the clean
      measurement: **clan's entire closure change is `gen: ∅ → ε`** —
      `/etc/hostid` — and activation restarted no system service.
- [ ] `203-media` — **blocked.** `prowlarr-config.service` now fails on every
      activation (curl exit 22 on the host-config PUT), so every deploy to 203
      reports failure and deploy-rs rolls the boot profile back. Not clan:
      nixflix moved in `2a3f5e3` and `11774fcb` ("send allowedHosts in the
      arr host config payload") changed exactly that request; sonarr, radarr
      and lidarr accept it, prowlarr doesn't. Pin nixflix back or fix it
      upstream first. From z14, deploy over `192.168.3.203` (201's subnet
      route) — `192.168.1.203` gets `Permission denied (publickey)` here.
- [ ] `ext-mail` — deploys over its public IP already
- [ ] `observability` — the headscale coordinator; `--hostname 89.167.83.90`,
      and from z14 also `--ssh-opts "-o ProxyCommand=none -p 5432 -i
      $HOME/.ssh/id_ed25519_priv -o IdentitiesOnly=no"`
- [ ] `201-mono` — fronts everything, so last among servers;
      `--hostname 192.168.3.201`, then check `systemctl is-active traefik dnsmasq`
- [ ] `z14`, `blac` — local `nixos-rebuild`; their `extraModules` import
      `/etc/nixos/hardware-configuration.nix`, which needs `--impure` as today
- [ ] `Eliss-MacBook-Pro` — needs `inventory.machines.<n>.machineClass =
      "darwin"` and `mkDarwin` folded in the same way. Clan's darwin support
      is `clan machines update` + vars only.

When every host is on clan: delete `mkNixos` and the `clanHosts` filter.

### 2 — secrets onto clan's store

Verified by spike: `clan secrets import-sops` writes clan's legacy
`sops/secrets/<name>/` store, and clanCore auto-declares `sops.secrets.<name>`
for every secret a machine can decrypt — so `config.sops.secrets."x".path` and
all four `sops.templates` blocks keep working with **no consumer edits**.

1. `clan vars keygen --user phonkd` — registers the existing
   `~/.config/sops/age/keys.txt` as the admin key.
2. Machine keys. Today every host decrypts with the *shared user key* at
   `/home/phonkd/.config/sops/age/keys.txt`. Clan's model is one key per
   machine. Start by registering the shared key's public half for each
   machine (`clan secrets machines add`) — no key distribution changes — then
   move hosts to their own keys once the store is proven.
   **Do not derive machine keys from ssh host keys yet:** 204 and 205 present
   the identical ed25519 host key (cloned VM image), so ssh-derived age keys
   would let each decrypt the other's secrets. Clan's default — a fresh age
   key per machine — sidesteps this; regenerating the cloned host keys is
   worth doing regardless.
3. `clan secrets import-sops --group admins --machine … <file>` for
   `global-secrets/secret.yaml` and the three per-app files.
4. Drop bare `sops.secrets.<name> = { };` declarations; keep the ~10 that set
   `owner`/`group`/`mode`.
5. Then vars, but only for secrets that are genuinely *generatable* (passwords,
   keypairs, the headscale pre-auth key). The ~45 opaque third-party API keys
   can stay in the store — vars has no importer for them, prompts can't be
   piped, and there is no `sops.templates` equivalent.

Watch for: `migrateFact` no longer exists; the vars sops name changed
between 26.05 and main (`vars/<gen>/<file>` → `vars/per-machine/…`); upstream
#6963 "updating to latest clan fails decrypting secrets" is open.

### 3 — the module system

- Tags: make `clan.inventory.machines.<n>.tags` the source and feed
  `noughty.host.tags` from `config.clanConfig.inventory.machines.<me>.tags`
  (verified to evaluate without recursion; `all` and `nixos` arrive for free),
  so all ~40 `noughtyLib.hostHasTag` sites keep working unchanged.
- `lib/registry.nix` keeps what the inventory can't hold — it has no freeform
  type, so `kind`, `platform`, `formFactor`, `gpu`, `username`, `extraModules`
  stay in the registry.
- Convert feature modules to `clan.service`s where roles are real, one at a
  time: `observability` (server/sender) is the obvious first. `alwaysImport`
  shrinks as they move.
- 26.05 has no per-tag `settings` (main does), so per-host settings go under
  `roles.<r>.machines.<m>.settings`. Function modules in `extraModules` don't
  dedupe — use paths or `self.nixosModules.<x>`.

### 4 — deploy via `clan machines update`

Blocked on a rollback story. Until then deploy-rs stays, which is fine: it
reads the same `nixosConfigurations`. When it moves: set
`deploy.buildHost = "localhost"` (clan builds on the *target* by default; local
keeps the 205 offload), pass `--host-key-check accept-new` (the default `ask`
hangs in scripts), and expect every run to evaluate vars for the whole fleet.

## Contribution candidates

Gaps found along the way, most useful first:

- **Rollback for `clan machines update`.** No magic/auto rollback anywhere in
  clan-core, and 26.05 registers the new generation in the bootloader *before*
  activating — so a config that kills the network leaves you booting into it.
  This is the one that blocks Phase 4 here.
- **A tailscale/headscale service** — or whatever networking replaces it. A
  ~60-line local `clan.service` exporting `networking` + `peer` was spiked and
  works with no Python plugin (`e341024`).
- **`zfs.nix` sets `networking.hostId` on every NixOS machine**, ZFS or not.
  Intentional (matches the installer ISO), but surprising on non-ZFS hosts —
  worth asking whether to gate it on `boot.zfs.enabled`.
- **Docs:** the networking guide says machine-level
  `clan.core.networking.targetHost` "bypasses all networking modules"; in
  `clan_lib/network/network.py` it is tried *last*. The wireguard README says
  "full mesh connectivity" for a topology where peers only ever peer with
  controllers.
- **Per-tag settings on the stable branch**, and **darwin support for
  services** (upstream #5717).

## Risks / rollout

- **Upgrade treadmill.** Stable branches get about six months and don't
  overlap — 25.11 went quiet when 26.05 shipped. 26.11 is due ~December.
- Clan's CI doesn't cover a downstream nixpkgs; we follow our own nixos-26.05,
  which is at least the same release line clan-core 26.05 pins.
- `nix-select` and `data-mesher` float on `main` even on the 26.05 branch —
  `nix flake update` moves them.
- Every Phase 1 step is one host, `deploy <host>`, magic rollback intact.
  Back out a host by removing it from `clanHosts`; back out entirely by
  reverting the Phase 1 commit (nothing in `sops/` or `vars/` exists yet).

## Reference — what the investigation verified

Evaluated in throwaway flakes against clan-core 26.05, not read from docs.
Full write-up and reproductions: `git show e341024:plans/clan-lol-migration.md`.

- clan's flake module and a hand-written `flake.nixosConfigurations` coexist
  when names differ (now exercised for real by `clanHosts`).
- `flake.darwinModules` declared twice is fatal — lazily, only when read.
- Two sops-nix store paths is fatal; `inputs.clan-core.inputs.sops-nix.follows`
  fixes it.
- `enableRecommendedDefaults = true` (clan's default) sets
  `networking.useNetworkd = true`, `networking.domain = "clan"` and
  `targetHost = root@<host>.clan`. With it off, clanCore's `nix.settings` are
  off too — all of them are gated on it.
- The only unconditional system change from clanCore found in source:
  `networking.hostId = mkDefault "8425e349"` from `zfs.nix`.
- `inventory.machines.<n>` options are exactly `name, description, icon,
  machineClass, installedAt, tags, deploy.{targetHost,buildHost,forwardAgent}`.
