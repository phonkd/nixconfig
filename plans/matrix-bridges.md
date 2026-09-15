# matrix + signal/whatsapp/discord bridges

**Repo(s):** nixconfig   **Status:** draft

## Goal

Run a personal Matrix homeserver with puppeting bridges to **Signal**,
**WhatsApp** and **Discord**, so all three land in one Matrix client instead of
three phone apps. Hosted on **Hetzner**, not at home: the homeserver needs
inbound :443 (federation + client API + the ACME challenge), and the point of
this exercise is to not punch holes in the home router. Nothing in the serving
path depends on 201-mono or the home connection being up.

## Approach

New Hetzner VM `ext-matrix`, alongside the two that already exist (`ext-mail`,
`observability`), running **Synapse + Postgres + nginx** with the three
**mautrix** bridges as local appservices. All four are in the pinned nixpkgs
(`nixos-26.05`) with real NixOS modules — verified against the module source,
not from memory:

| thing | version in nixos-26.05 | module | appservice port |
|---|---|---|---|
| matrix-synapse | 1.159.0 | `services.matrix-synapse` | — |
| mautrix-whatsapp | 26.08 | `services.mautrix-whatsapp` | 29318 |
| mautrix-signal | 26.08 | `services.mautrix-signal` | 29328 |
| mautrix-discord | 0.7.6 | `services.mautrix-discord` | 29334 |

`services.mautrix-*.registerToSynapse` defaults to
`config.services.matrix-synapse.enable`, so each bridge appends its own
registration file to `settings.app_service_config_files` and adds itself to
synapse's `SupplementaryGroups` automatically. No hand-written registration YAML.

mautrix-signal 26.08 is the **Go rewrite with embedded libsignal** — no signald
sidecar, no Python, nothing extra to package.

Layout on the box:

```
      internet :443
           │
        nginx (ACME HTTP-01, matrix.phonkd.net)
           │  /_matrix/*  /_synapse/admin/*
           ▼
      synapse  127.0.0.1:8008  ── unix socket ──► postgres
           ▲                                      (synapse + 3 bridge DBs)
           │ appservice HTTP (localhost)
     ┌─────┴──────┬─────────────┐
  mautrix-      mautrix-     mautrix-
  whatsapp      signal       discord
   :29318       :29328        :29334
```

Telemetry rides the existing pattern: tag `observability-sender`, and Alloy ships
journal→Loki / metrics→Mimir at `100.64.0.4` over the tailnet. **No change needed
in `modules/observability.nix`** — its `obsHost` special-case is keyed on
`hostname == "ext-mail"`, and any other host already falls through to
`100.64.0.4`.

### File layout: one `modules/chat.nix` for both halves

`modules/chat.nix` — already stubbed on the main checkout, still untracked —
holds **both** sides of this feature: the homeserver's NixOS module and the
desktop clients' Home Manager module. That is the established shape here, not a
novelty: `modules/kde.nix`, `modules/hyprland.nix` and `modules/desktop.nix` each
define `flake.nixosModules.*` and `flake.homeModules.*` in one file, so the system
half and the `$HOME` half of one feature stay next to each other. It supersedes
the `modules/hetzner/matrix/matrix.nix` path named in the steps below — there is
no second file, and nothing about the module needs to live under `hetzner/`
(the tag decides where it lands, not the directory).

`import-tree ./modules` (flake.nix) picks the file up automatically; nothing
imports it by path. Two consequences worth stating plainly:

- **Every `.nix` under `modules/` is evaluated**, so a mistake in this one file
  breaks the whole flake — every host, not just the chat host.
- **Untracked files are invisible to the flake.** `chat.nix` is not `git add`ed
  yet, and that is the only reason the defects below are not already firing.

Target skeleton:

```nix
{ self, inputs, ... }:
{
  # ── server half: the homeserver + bridges ──────────────────────────
  flake.nixosModules.chat-server =
    { config, pkgs, lib, noughtyLib, ... }:
    {
      config = lib.mkIf (noughtyLib.hostHasTag "chat-server") {
        services.postgresql    = { /* … */ };
        services.matrix-synapse = { /* … */ };
        services.mautrix-whatsapp = { /* … */ };
        services.mautrix-signal   = { /* … */ };
        services.mautrix-discord  = { /* … */ };
        services.nginx = { /* matrix.phonkd.net */ };
        networking.firewall.allowedTCPPorts = [ 80 443 ];
      };
    };

  # ── client half: what a desktop needs to talk to it ────────────────
  flake.homeModules.chat =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.element-desktop ];
    };
}
```

Wiring, once the file is correct:

- Server: add `chat-server` to `alwaysImport` in `modules/builder.nix`. It
  self-gates on the tag, exactly like `mailserver` and `observability-server`
  already there, so it is inert on all eight other hosts.
- Client: import `self.homeModules.chat` from `flake.homeModules.gui-nixos`
  (`modules/hosts/types/gui/default.nix`) — that is the list `blac`, `g14` and
  `z14` already pull. The Mac gets an `element` **cask** in `gui-darwin` instead,
  for the same reason `affine` and `discord` are casks there: HM links apps as
  store symlinks that Spotlight will not index, so a nix-installed GUI app is
  unlaunchable on Tahoe.

### Defects in the current stub (verified, not read off)

The stub as it stands does not merely need filling in — it breaks the flake the
moment it is tracked. All three were confirmed by copying the file into a
worktree and evaluating, not by inspection.

1. **`flake.homeModules.desktop` collides with `modules/desktop.nix:10`** and is a
   hard eval error. `flake.homeModules` is a `lazyAttrsOf raw` (`modules/parts.nix`),
   whose merge function rejects a second definition outright:

   ```
   error: The option `flake.homeModules.desktop' is defined multiple times
          while it's expected to be unique.
   Definition values:
   - In `…/modules/chat.nix': <function, args: {pkgs}>
   - In `…/modules/desktop.nix': <function, args: {pkgs}>
   ```

   This is the whole flake failing to evaluate, so it would take every host down
   with it, not just chat. **Fix:** name it `flake.homeModules.chat`. Renaming it
   was verified to make both `.#homeModules.chat` and `.#nixosModules.chat-server`
   evaluate clean. More generally: a second file can never *extend* an existing
   home module by redefining its name — it either declares a new module that gets
   imported alongside, or it edits `desktop.nix` directly.

2. **`imports = [ self.nixosModules.desktop ];` inside `chat-server`** is a
   copy-paste from `nvidia-desktop` (`modules/desktop.nix:348`) and does not
   belong on a headless server — that module is the display-manager / desktop-
   environment mapping (SDDM, greetd, GNOME). It is inert *today* because it
   self-gates on `noughty.host.is.nixosDesktop`, so this one is latent rather
   than fatal. It is still worth removing: `builder.nix`'s own comment warns that
   function modules cannot be deduplicated by Nix, so if `chat-server` ever lands
   on a desktop host this second import path produces duplicate definitions of
   every unique option `desktop` declares. **Fix:** drop the `imports` entirely.

3. **No gate on the `config` block.** As written, `chat-server` applies wherever
   it is imported. Once it joins `alwaysImport` that means *everywhere*. **Fix:**
   the `lib.mkIf (noughtyLib.hostHasTag "chat-server")` wrapper shown above, and
   take `noughtyLib` from the module arguments — the stub's argument list omits it.

Note the tag name drifts between this plan and the stub: the steps below say
`matrix-server`, the stub module is `chat-server`. Settling on **`chat-server`**
for both the module name and the registry tag, to match the file.

### Why a new VM rather than the mailserver VM

Reusing `ext-mail` was the other candidate. Against it:

- ~~**`ext-mail` is the fleet's one hand-managed box.**~~ **Obsolete — this was
  the strongest argument and it has since been answered.** `ext-mail` is a normal
  deploy node now: the `worktree-mail-tailnet` branch gives it
  `deploy.hostname = "157.180.27.152"` (its public IP, not a tailnet address —
  deliberately, so that activation restarting `tailscaled` cannot kill the deploy
  that is riding it), and `deploy mail` works. Note that branch is **not merged to
  `main`** yet, so on `main` the registry stanza still has no `deploy.hostname`.
  The three reasons below are what the new-VM recommendation now rests on, and
  they are weaker than this one was.
- **Mail is the one workload whose reputation is precious.** Deliverability, DKIM
  state and the ACME certs for `mail.phonkd.net` / `cal.phonkd.net` all live
  there. Synapse plus three bridges is the noisiest, most memory-hungry,
  most-frequently-restarted workload in the fleet; a bridge OOM or a Synapse
  schema migration should not be able to take mail down.
- **:80/:443 contention.** `modules/hetzner/mail/mail.nix` already owns nginx and
  both ACME vhosts there. Adding `matrix.phonkd.net` is possible but couples two
  unrelated release cycles onto one nginx.
- A CX22 is ~€4/month. The isolation is worth more than that.

The cost of a new VM is one more box to bootstrap (disk UUIDs, age key, tailnet
enrolment) — all of it a one-time, well-trodden path (`observability` did exactly
this).

**Sizing:** CX22-class — 2 vCPU / 4 GB / 40 GB, **x86_64**. Not the ARM CAX
series: `205-builder` is x86_64-only, so an aarch64 host would lose build offload
and compile its own closures. 4 GB is comfortable (synapse ~0.5–1 GB, postgres
~250 MB, each Go bridge ~100–200 MB); 2 GB would be tight once WhatsApp history
backfill runs.

### Identity / domain

`server_name` is **permanent** — it is baked into every MXID and every room this
server ever joins, and cannot be changed later without abandoning the account. So
pick the good one now:

- **`server_name = "phonkd.net"`** → MXIDs read `@phonkd:phonkd.net`.
- Federation discovery via a **`_matrix-fed._tcp.phonkd.net` SRV** record →
  `matrix.phonkd.net:443`. This sidesteps the `.well-known` problem entirely: the
  apex `phonkd.net` A record points at the *home* IP (85.195.231.133) and nothing
  there serves a valid cert for the apex today, so a `.well-known/matrix/server`
  lookup fails and resolvers fall through to SRV. No home dependency in the
  federation path.
- Clients point at `https://matrix.phonkd.net` **manually** (Element accepts a
  custom homeserver URL). Client autodiscovery via
  `phonkd.net/.well-known/matrix/client` is a later nicety, not a blocker.
- Both well-known files get served from `matrix.phonkd.net` too. Harmless, and
  correct if anything ever redirects there.

New DNS records needed (Cloudflare — the same zone `ddns.nix` already drives):

```
matrix.phonkd.net.            A    <ext-matrix public IP>
_matrix-fed._tcp.phonkd.net.  SRV  10 0 443 matrix.phonkd.net.
```

**Fragility to know about:** the SRV path works *because* the apex well-known
lookup fails. If a traefik router for bare `phonkd.net` is ever added on 201 and
starts answering 200, federation discovery breaks. Phase 3 removes that trap by
serving the two well-known JSON files from the apex deliberately.

### Landmines found while surveying

1. **Postgres vs sshd both want :5432.** `modules/hosts/types/server/hetzner-vm.nix`
   sets `services.openssh.ports = [ 5432 ]`, and nixpkgs' postgresql module sets
   `listen_addresses = if cfg.enableTCPIP then "*" else "localhost"` — i.e. it
   binds `127.0.0.1:5432` even with `enableTCPIP = false`. sshd binds
   `0.0.0.0:5432`, so whichever starts second fails to bind and the box comes up
   half-dead. **Fix:** `services.postgresql.settings.listen_addresses =
   lib.mkForce "";` — unix-socket-only. Everything on this host (synapse and all
   three bridges) connects via `host=/run/postgresql` anyway.
2. **Per-host disk UUIDs.** `hetzner-vm.nix` hardcodes `fileSystems."/"` and
   `"/efi"` UUIDs. `observability` already has to `lib.mkForce` its own
   (`modules/observability.nix`); `ext-matrix` will need the same, read off the
   new VM after install.
3. **The Hetzner cloud firewall is separate from the NixOS firewall.** The
   headscale rollout was bitten by exactly this
   (`plans/headscale-mesh.md`). Open 80/443 at the Hetzner level too, or ACME
   silently never completes.
4. **The Discord bridge authenticates with a user token.** `mautrix-discord` logs
   in as your own Discord account (a "self-bot"), which is against Discord's ToS
   on a strict reading and has gotten accounts flagged. The bot-token mode only
   sees guilds the bot was invited to, so it does not bridge DMs. Not a blocker,
   but a real user's-call risk — noted, not hidden. Signal and WhatsApp bridges
   link as ordinary companion devices (QR scan), a supported flow in both apps.
5. **`hetzner-vm.nix` turns Docker on** for every host with that tag except
   `observability-server`. Nothing here needs it, and it is ~1 GB of closure plus
   a bridge network on a 40 GB disk. Extend that exemption, or add a
   `lib.mkForce false` in the matrix host module.
6. **The synapse module refuses in-store secrets.** `registration_shared_secret`,
   `macaroon_secret_key` and `form_secret` are explicitly flagged
   "Pass this value via extraConfigFiles instead" (synapse.nix ~L418) — so the
   sops route in step 7 is mandatory, not a nicety.

## Steps

Ordered; each verifiable on its own.

### Phase 1 — homeserver up

0. **Make the stub safe first.** `modules/chat.nix` exists untracked on the main
   checkout and, as written, fails flake evaluation the moment it is `git add`ed
   (see *Defects in the current stub* above). Before anything else: rename
   `flake.homeModules.desktop` → `flake.homeModules.chat`, drop
   `imports = [ self.nixosModules.desktop ]`, add `noughtyLib` to the
   `chat-server` argument list and wrap its `config` in the tag gate. Verify with
   `nix eval .#homeModules.chat --apply 'x: "ok"'` and the same for
   `.#nixosModules.chat-server` — both must evaluate before the file is committed.
   This step is independent of the host decision and can land today.
1. **Provision the VM.** Hetzner CX22, x86_64, same project and private network as
   `ext-mail`/`observability`. Install NixOS the way those two were done. Open
   80/443 in the Hetzner cloud firewall. Record the public IP and the `/` + `/efi`
   disk UUIDs.
2. **DNS:** create `matrix.phonkd.net A <ip>` in Cloudflare. (SRV comes in step 8,
   once the server answers.)
3. **`lib/registry.nix`:** add an `ext-matrix` stanza — `kind = "server"`,
   `tags = [ "vm" "hetzner-vm" "chat-server" "observability-sender" ]`,
   `extraModules = [ self.nixosModules."ext-matrix" self.nixosModules."hetzner-vm" ]`.
   Leave `deploy.hostname` out until the box is on the tailnet (step 5).
4. **`modules/hosts/matrix.nix`:** host identity module, mirroring
   `modules/hosts/mail.nix` — sets `networking.hostName`, plus the `lib.mkForce`
   fileSystems UUID overrides from step 1.
5. **Bootstrap + enrol.** Place the shared age key at
   `/home/phonkd/.config/sops/age/keys.txt` (the sops `keyFile`, per
   `modules/homelab/sops.nix`), then first `nixos-rebuild` on the box by hand.
   `tailnet.nix` gates on `is.server`, so it enrols itself with the sops
   `headscale_authkey`. Read the assigned `100.64.0.x` out of `tailscale status`,
   put it in `deploy.hostname`, and confirm `deploy matrix` works end to end.
6. **`modules/chat.nix`, server half** — `flake.nixosModules.chat-server`, gated on
   `noughtyLib.hostHasTag "chat-server"` and added to `alwaysImport` in
   `modules/builder.nix`, following the shape of
   `modules/hetzner/mail/mail.nix`:
   - `services.postgresql` — enable, `settings.listen_addresses = lib.mkForce ""`
     (landmine 1), `ensureDatabases` + `ensureUsers` for `matrix-synapse`,
     `mautrix_whatsapp`, `mautrix_signal`, `mautrix_discord`, each created with
     `LC_COLLATE=C LC_CTYPE=C` (Synapse refuses anything else).
   - `services.matrix-synapse` — `server_name = "phonkd.net"`,
     `public_baseurl = "https://matrix.phonkd.net/"`, one listener on
     `127.0.0.1:8008` carrying `client` + `federation`,
     `database.name = "psycopg2"` with `args.host = "/run/postgresql"`,
     `enable_registration = false`.
   - `services.nginx` — `matrix.phonkd.net`, `forceSSL` + `enableACME`, proxying
     `/_matrix` and `/_synapse/admin` to `127.0.0.1:8008` with
     `client_max_body_size` raised for media. Serve the two
     `/.well-known/matrix/*` JSON files here too.
   - `networking.firewall.allowedTCPPorts = [ 80 443 ]`.
7. **Secrets** into the global `modules/homelab/global-secrets/secret.yaml` (the
   defaultSopsFile — the new host decrypts it with the same shared age key, so no
   per-host sops file is needed, unlike `ext-mail`'s local one):
   `sops set modules/homelab/global-secrets/secret.yaml '["matrix-synapse-conf"]' '"..."'`
   holding `registration_shared_secret`, `macaroon_secret_key` and `form_secret`
   as a YAML fragment, wired in via `settings.extraConfigFiles`.
8. **Verify, then open federation.** `deploy matrix`; create the first account with
   `register_new_matrix_user`; log in from Element against
   `https://matrix.phonkd.net`. Then add the
   `_matrix-fed._tcp.phonkd.net SRV 10 0 443 matrix.phonkd.net` record and check
   `phonkd.net` on federationtester.matrix.org.

### Phase 2 — the bridges, one at a time

Each is the same shape and each is independently verifiable, so they land as
separate commits rather than one big one. Order by value: WhatsApp → Signal →
Discord.

9. **mautrix-whatsapp.** `services.mautrix-whatsapp.enable = true` with
   `settings.homeserver.domain = "phonkd.net"`,
   `settings.database = { type = "postgres"; uri = "postgresql:///mautrix_whatsapp?host=/run/postgresql"; }`,
   `settings.bridge.permissions."phonkd.net" = "admin"`, and
   `encryption = { allow = true; default = true; }`.
   Secrets — `encryption.pickle_key`, `provisioning.shared_secret`,
   `public_media.signing_key`, `direct_media.server_key` — go through
   `environmentFile` from a sops template, **not** into `settings`: the module's
   own docs warn that leaving them at `generate` breaks on every restart, because
   the config file is regenerated each start and the generated values are thrown
   away.
   Verify: DM `@whatsappbot:phonkd.net`, `!wa login`, scan the QR from the phone's
   linked-devices screen, confirm a portal room appears.
10. **mautrix-signal.** Identical shape (`mautrix_signal` DB, `!signal login`,
    QR-link as a Signal linked device).
11. **mautrix-discord.** Same, plus the ToS caveat in landmine 4 — decide
    user-token vs bot-token before wiring it. Note its option tree is shaped
    differently from the other two: `settings.appservice` carries the database
    block, rather than a top-level `settings.database`.

11b. **`modules/chat.nix`, client half** — `flake.homeModules.chat`, and the only
    step that touches the desktops rather than the server. Put the Matrix client
    in `home.packages` and import the module from `flake.homeModules.gui-nixos`
    (`modules/hosts/types/gui/default.nix`), which is what `blac`, `g14` and `z14`
    already pull. The Mac takes an `element` cask in `gui-darwin` instead, for the
    Spotlight reason documented on `affine` and `discord` there.
    Client choice (all three are in the pinned nixpkgs, versions checked):
    `element-desktop` 1.12.26 — the reference client, the one to default to;
    `nheko` 0.12.1 — native Qt, much lighter, weaker on spaces/threads;
    `fluffychat` 2.6.0 — Flutter, phone-shaped. Recommending `element-desktop`
    because the bridges' admin flows are all bot DMs with `!wa`-style commands and
    Element is where those are actually tested.
    Verify: log the desktop client in against `https://matrix.phonkd.net` and
    confirm the bridged portal rooms from steps 9–11 appear.

### Phase 3 — polish, once it is actually being used

12. **Backups.** Nothing in this repo currently backs anything up, and this is the
    first service where losing state genuinely hurts: the bridge DBs hold the
    device-linking sessions, so a restore-from-nothing means re-scanning QR codes
    on three services and losing every portal mapping. Nightly `pg_dump` of the
    four databases + `/var/lib/mautrix-*` → either the existing garage S3 on 201
    over the tailnet (`modules/homelab/apps/s3-garage.nix`) or a Hetzner Storage
    Box. Garage is cheaper but makes backups depend on home being up — acceptable
    for backups in a way it is not for the serving path.
13. **Growth control.** `synapse-auto-compressor` (module exists in nixpkgs) plus
    `media_retention` — Synapse's state tables and bridged media are what fill the
    40 GB disk.
14. **Apex well-known**, to remove the fragility noted above: a traefik router for
    bare `phonkd.net` on 201 serving the two static JSON files, so federation
    discovery stops depending on the apex *failing*.
15. **Element web** at `element.phonkd.net` off the same nginx (`pkgs.element-web`
    is packaged; there is no NixOS module, so serve the derivation as a `root`
    with a generated `config.json`). Optional — mobile/desktop Element works fine
    without it.
16. **Double puppeting** (`double_puppet.secrets`, so messages you send from the
    WhatsApp/Signal app show as *you* in Matrix rather than as the bridge bot),
    and a Grafana dashboard off Synapse's Prometheus metrics.

## Open decisions

- **New VM vs. the mailserver VM — reopened.** Still recommending a new
  `ext-matrix`, but less strongly than before: the "ext-mail is hand-managed"
  argument is gone now that it is a deploy node, so the case rests only on
  blast-radius isolation (mail reputation, bridge OOM, one nginx serving two
  release cycles). If box-count or the €4/month wins, the delta is smaller than
  this plan originally implied — add the `chat-server` tag to the existing
  `ext-mail` stanza, add the matrix vhosts to its nginx, and accept that a bridge
  OOM can take mail with it. Note the `worktree-mail-tailnet` branch has to reach
  `main` either way before `deploy mail` is reproducible from a clean checkout.
  **Nothing about `modules/chat.nix` changes with this decision** — it is gated on
  a tag, so which host wears the tag is a one-line registry edit. That is the
  reason to fix and land the module (step 0) without waiting for this call.
- **Where the client half lives.** `modules/chat.nix` holding both halves is the
  recommendation and matches `kde.nix` / `hyprland.nix` / `desktop.nix`. The
  alternative — server module here, client packages appended to the existing
  `homeModules.desktop` in `desktop.nix` — splits one feature across two files and
  is what the current stub half-attempted by redefining that name. Not
  recommended, and note it is not merely a style call: redefining the name is the
  eval error in defect 1.
- **`server_name = "phonkd.net"` (recommended) vs `"matrix.phonkd.net"`.** The
  latter needs no SRV record and no well-known at all, but the MXIDs
  (`@phonkd:matrix.phonkd.net`) are permanent and ugly. Recommending `phonkd.net`
  because `server_name` cannot be migrated later.
- **Federation on (recommended) vs off.** If this is purely a private bridge hub,
  `federation_domain_whitelist = [ ]` drops the SRV record, the federation attack
  surface and the spam entirely — but it also means never joining a public Matrix
  room. One DNS record is a cheap price for keeping the option.
- **Discord: user token vs bot token.** User token bridges DMs and everything you
  see, and is ToS-gray. Bot token is clean but only sees guilds the bot joins, so
  no DMs. No recommendation — this one is a values call, not a technical one.
- **Bridge DBs: Postgres (recommended) vs the modules' default SQLite.** Postgres
  is one extra `ensureDatabase` per bridge and makes the backup story a single
  `pg_dump`. SQLite is the upstream default and fine at this scale.

## Risks / rollout

- **Blast radius is zero for the existing fleet** in the recommended shape. A new
  host touches `lib/registry.nix` plus two new files; no shared module changes, no
  `201-mono`, no traefik. The reuse-`ext-mail` variant is the risky one, which is
  the main argument against it.
- **Rollout** is `deploy matrix` from a NixOS desktop or the Mac, with deploy-rs
  magic rollback — a host that drops off the network after activation reverts
  itself. Bootstrap (step 5) is the one hand-run `nixos-rebuild`.
- **Back out:** `services.matrix-synapse.enable = false` (or drop the whole
  `ext-matrix` stanza) and delete the VM. Nothing else in the fleet references it.
  Deleting the DNS records is the only external cleanup.
- **Ongoing:** mautrix bridges track the upstream apps and break when WhatsApp or
  Signal change protocol; expect to follow nixpkgs bumps rather than pinning and
  forgetting. Synapse major upgrades run schema migrations on start — watch the
  journal (it lands in Loki via the `observability-sender` tag) on the first boot
  after a bump.
