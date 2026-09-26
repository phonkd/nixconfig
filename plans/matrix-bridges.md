# matrix + signal/whatsapp/discord bridges

**Repo(s):** nixconfig   **Status:** in progress — hosted on `ext-mail`, tag wired; secrets and DNS outstanding

## Goal

Run a personal Matrix homeserver with puppeting bridges to **Signal**,
**WhatsApp** and **Discord**, so all three land in one Matrix client instead of
three phone apps. Hosted on **Hetzner**, not at home: the homeserver needs
inbound :443 (federation + client API + the ACME challenge), and the point of
this exercise is to not punch holes in the home router. Nothing in the serving
path depends on 201-mono or the home connection being up.

## Approach

**Hosted on the existing `ext-mail` VM** — decided 2026-09-20; the separate-VM
option this plan originally recommended, and what choosing against it costs, is
recorded under Open decisions. It runs **Synapse + Postgres + nginx** with the three
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

`modules/chat.nix` — now written and committed —
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
- **It is tracked now**, which is what makes the above load-bearing: an
  untracked file is invisible to the flake, and that invisibility was the only
  reason the defects below were not already firing.

Skeleton — the committed file fills each of these blocks in:

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

Wiring (both described below; only the server half is actually hooked up):

- Server: add `chat-server` to `alwaysImport` in `modules/builder.nix`. It
  self-gates on the tag, exactly like `mailserver` and `observability-server`
  already there, so it is inert on all eight other hosts.
- Client: import `self.homeModules.chat` from `flake.homeModules.gui-nixos`
  (`modules/hosts/types/gui/default.nix`) — that is the list `blac`, `g14` and
  `z14` already pull. The Mac gets an `element` **cask** in `gui-darwin` instead,
  for the same reason `affine` and `discord` are casks there: HM links apps as
  store symlinks that Spotlight will not index, so a nix-installed GUI app is
  unlaunchable on Tahoe.

### Defects in the original stub — **fixed, kept as the record of why**

All three were repaired when `modules/chat.nix` was written for real; the
committed file has none of them. Kept here because each is a trap the next
module in this repo can fall into, and defect 1 in particular is a rule about
`flake.homeModules`, not a one-off typo.

The stub as it stood did not merely need filling in — it broke the flake the
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
- **One nginx serving two release cycles.** Not port *contention* — 80/443 is a
  single nginx and `matrix.phonkd.net` would simply be a third vhost beside
  `mail.` and `cal.` (see the port map below). The cost is coupling: one nginx
  config and one reload path shared between mail and a Synapse that changes far
  more often, and a broken matrix vhost takes the webmail/CalDAV vhosts with it.
- A CX22 is ~€4/month. The isolation is worth more than that.

The cost of a new VM is one more box to bootstrap (disk UUIDs, age key, tailnet
enrolment) — all of it a one-time, well-trodden path (`observability` did exactly
this).

**Sizing:** CX22-class — 2 vCPU / 4 GB / 40 GB, **x86_64**. Not the ARM CAX
series: `205-builder` is x86_64-only, so an aarch64 host would lose build offload
and compile its own closures. 4 GB is comfortable (synapse ~0.5–1 GB, postgres
~250 MB, each Go bridge ~100–200 MB); 2 GB would be tight once WhatsApp history
backfill runs.

### Port map: does synapse fit next to mail?

Checked by evaluating `nixosConfigurations.ext-mail.config`, not by reading the
module — and the bridge ports are the modules' own defaults, read the same way.

`ext-mail` as it stands: firewall open on **25, 80, 443, 465, 993, 5432**; sshd on
**5432**; dovecot, postfix, rspamd + a redis instance for it, radicale on
**5232** (localhost, proxied from the `cal.phonkd.net` vhost). **Postgres is not
enabled there today.**

| the chat stack wants | ext-mail today | verdict |
|---|---|---|
| synapse `127.0.0.1:8008` | free | fine |
| mautrix-whatsapp `29318` | free | fine |
| mautrix-signal `29328` | free | fine |
| mautrix-discord `29334` | free | fine |
| nginx `80` / `443` | nginx (`mail.`, `cal.`) | **shared nginx, not a conflict** |
| postgres `5432` | **sshd `0.0.0.0:5432`** | **collides — see landmine 1** |

So the only genuine collision is postgres, and it is **not** an argument either way
on the host decision: `hetzner-vm.nix` puts sshd on 5432 for *every* host carrying
that tag, so a fresh `ext-matrix` hits exactly the same thing. It is landmine 1,
unconditional, and `listen_addresses = lib.mkForce ""` is the fix in both shapes.

Two details specific to reusing `ext-mail`:

- **5432 is in that host's public `allowedTCPPorts`** (it has to be — it is the
  ssh port). A postgres that ever gained `listen_addresses = "*"` would therefore
  be publicly reachable, not merely locally bound. Another reason the
  unix-socket-only setting is mandatory rather than tidy.
- **Which service loses the bind is a race, not a defined order.** Nothing in
  systemd orders sshd against postgresql. In practice sshd binds first and
  postgres fails with `EADDRINUSE` — the chat stack dies, mail and ssh survive.
  The other branch is the bad one: postgres first means sshd cannot bind and the
  box is unreachable except via the Hetzner console. (A `deploy` that did this
  would trip deploy-rs magic rollback, since the confirmation never lands.)

Also worth noting: federation rides **443** via the SRV record, so nothing here
needs synapse's traditional **8448** — it stays closed in both shapes.

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
   binds `127.0.0.1:5432` even with `enableTCPIP = false` — confirmed by
   evaluating the module, not read off it. sshd binds `0.0.0.0:5432`, and the two
   conflict. Nothing orders them, so which one loses is a race: in practice sshd
   binds first and postgres fails with `EADDRINUSE` (chat dead, mail and ssh
   fine), but the other branch leaves the box unreachable except via the Hetzner
   console. **Fix:** `services.postgresql.settings.listen_addresses =
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
7. **All three bridges link libolm, which nixpkgs marks insecure.** Building the
   host fails outright with `Package 'olm-3.2.16' ... known vulnerabilities`
   until it is permitted — found by actually evaluating the host, not by
   reading. `olm` is a `buildInputs` dependency of all three packages, so
   turning bridge encryption *off* would not drop it. `mautrix-whatsapp` and
   `mautrix-signal` take a `withGoolm` flag that swaps in a pure-Go Olm, but
   `mautrix-discord` has no such flag, and upstream calls goolm experimental and
   "not recommended". **Fix:** `nixpkgs.config.permittedInsecurePackages =
   [ "olm-3.2.16" ]`, inside the tag gate so it touches nothing else. The pinned
   version string is deliberate: a nixpkgs bump past 3.2.16 breaks the build
   rather than silently doing nothing.
8. **The bridges' secret defaults are `""`, not `"generate"`** — the modules'
   own comments are stale on this point, and so was the first draft of this
   plan, which inherited the comments' conclusion. Because `""` is not
   `"generate"`, nothing is generated and **nothing rotates on restart**; the
   real defect is narrower and duller — an empty key, identical on every
   install. Only `pickle_key` is worth fixing (it encrypts the bridge's crypto
   store and must be stable *and* secret). The mechanism for fixing it is
   **envsubst**: each bridge's `preStart` runs the settings file through it, so
   a literal `"$MAUTRIX_…"` in `settings` is replaced at start time by the value
   from `environmentFile`. That indirection exists to keep the value out of
   `/nix/store`, where a plain `settings` entry would be world-readable — it is
   not about rotation. See *Why this is five keys and not fourteen*.
9. **`ensureDatabases` cannot set a locale, and Synapse demands C collation.**
   It issues a bare `CREATE DATABASE`, so the *cluster* has to be initialised
   that way: `initdbArgs = [ "--locale=C" "--encoding=UTF8" ]`. This applies at
   initdb time only — i.e. the very first start of a fresh host. Retrofitting an
   existing cluster means dump, re-initdb, restore. Getting this wrong on the
   new VM is cheap; getting it wrong on `ext-mail` later would not be.
10. **`ensureDBOwnership` requires role name == database name, and the bridges
    break that.** Their system users are `mautrix-whatsapp` etc., but a database
    name with a hyphen would need quoting throughout the connection URIs, so the
    databases are `mautrix_whatsapp`. The assertion fires if you set
    `ensureDBOwnership = true`. **Fix:** leave it off and hand ownership over
    once in `systemd.services.postgresql.postStart`.
11. **sops-nix reads the secrets file at *evaluation* time.** A
    `sops.secrets.<name>` pointing at a file that is not committed fails the
    build with `Path 'modules/homelab/secrets/chat.yaml' does not exist in Git
    repository` — not at deploy time, at eval. So the encrypted file has to
    exist and be `git add`ed before the host will evaluate at all, which is why
    it is committed with placeholders rather than created during rollout.

12. **Defining a `types.attrs` block REPLACES the module's default — it does not
    merge into it.** This bites mautrix-discord specifically, and it is silent.
    Its `settings.homeserver` / `appservice` / `bridge` are each a plain
    `types.attrs` option with a default attrset, and a NixOS *default* is not a
    *definition*, so the merge function never sees it. Setting just
    `appservice.database` therefore deleted the appservice `port` (29334), `id`,
    `bot` and both tokens; setting `bridge` deleted every username/displayname
    template, `command_prefix` and the rest — 34 keys down to 3. Nothing warns
    you, and it evaluates and builds perfectly happily.

    mautrix-whatsapp and mautrix-signal do **not** have this problem: their
    single `settings` option carries `apply = lib.recursiveUpdate defaultConfig`,
    which folds the defaults back in.

    **Fix:** merge explicitly against the module's own defaults, read back out
    of the option type so they track nixpkgs rather than being copied and going
    stale:

    ```nix
    discordOpts = options.services.mautrix-discord.settings.type.getSubOptions [ ];
    discordBlock = name: overrides:
      lib.recursiveUpdate (discordOpts.${name}.default or { }) overrides;
    ```

    Worth checking for on any module whose `settings` is `types.attrs` without
    an `apply`. Verified by evaluating `builtins.attrNames` on each block before
    and after — a diff of rendered config keys is the only way this shows up.

7. **`$PSQL` does not exist, and `ensureDatabases` no longer runs in
   `postgresql.service`.** This one actually bit: the first `deploy ext-mail`
   rolled back because `postgresql.service` failed with
   `ExecStartPost=… (code=exited, status=127)`. The module had a
   `systemd.services.postgresql.postStart` calling `$PSQL -tAc 'ALTER DATABASE …'`
   to hand each bridge database to its role. In `nixos-26.05` nothing defines a
   `PSQL` variable anywhere in `postgresql.nix`, so the line ran as a bare
   `-tAc '…'` — command not found, 127, unit dead, and with it synapse and all
   three bridges. It was wrong a second way too: `ensureDatabases` /
   `ensureUsers` live in a separate **`postgresql-setup.service`** that runs
   *after* `postgresql.service`, so the `ALTER` would have fired before the
   databases existed. **Fix:** name each database exactly like its role
   (`mautrix-whatsapp`, not `mautrix_whatsapp`) and set
   `ensureDBOwnership = true` on all four — then the module does it and the
   custom `postStart` goes away. The hyphen-avoidance that motivated the
   underscores was unfounded: in a libpq URI the dbname is just the path
   segment, and the module already quotes the SQL identifier
   (`CREATE DATABASE "${database}"`).

## Steps

Ordered; each verifiable on its own.

### Phase 1 — homeserver up

0. ~~**Make the stub safe first.**~~ **Done.** `modules/chat.nix` is written,
   committed and wired into `alwaysImport`, with the three stub defects fixed
   and the full server half in place (postgres, Synapse, all three bridges,
   nginx, and every sops template). The secrets file
   `modules/homelab/secrets/chat.yaml` is committed with placeholders.

   **It is inert.** No host carries the `chat-server` tag, so the whole module
   is behind `mkIf false`. Verified rather than asserted: evaluating
   `observability` with and without `chat-server` in `alwaysImport` yields the
   *same* system derivation. Tagging a host is the single switch that turns all
   of this on — which is what makes steps 1–5 the real remaining work, and why
   the new-VM-vs-`ext-mail` decision stayed cheap to defer.

   Verified so far: `nix eval` of both module attributes; a full
   `config.system.build.toplevel` evaluation of a `hetzner-vm` host temporarily
   wearing the tag (this is what surfaced landmines 7–11); and spot-checks that
   the `$MAUTRIX_…` literals survive into `settings` for envsubst and the
   postgres URIs render as unix-socket DSNs. **Not** verified: nothing has been
   *built* or run. Whether Synapse and the bridges actually come up is step 8.
1. ~~**Provision the VM.**~~ **Dropped** — reusing `ext-mail` (see Open
   decisions). No Hetzner cloud-firewall change either: 80/443 are already open
   there for `mail.` and `cal.`, which is one of the small dividends of this
   choice. Nothing to bootstrap, no disk UUIDs to read off.
2. **DNS:** create `matrix.phonkd.net A 157.180.27.152` (ext-mail's public IP)
   in Cloudflare. **This is the one prerequisite that must land before the first
   deploy** — ACME issues the cert over HTTP-01 on that name, so nginx will fail
   to obtain it until the record resolves. (The SRV record comes in step 8, once
   the server answers.)
3. ~~**`lib/registry.nix`: add an `ext-matrix` stanza.**~~ **Done, differently.**
   `chat-server` was added to the existing `ext-mail` tag list instead — a
   one-line edit. `deploy.hostname` is already `157.180.27.152` there, so
   `deploy mail` is the deploy command for this work too.
4. ~~**`modules/hosts/matrix.nix`.**~~ **Dropped** — no new host, so no host
   identity module and no `fileSystems` UUID overrides.
5. ~~**Bootstrap + enrol.**~~ **Dropped** — `ext-mail` is already a deploy node
   with the age key in place and the tailnet enrolment done.

   Verified on `ext-mail` with the tag applied: nginx serves all three vhosts
   (`mail.`, `cal.`, `matrix.`), sshd keeps :5432, postgres binds nothing
   (`listen_addresses = ""`), the firewall is unchanged at
   `[25 80 443 465 993 5432]`, and the two `security.acme` definitions agree
   rather than conflict. Docker flips to `false` — see the Open decisions note.
6. ~~**`modules/chat.nix`, server half**~~ — **Done in step 0**; this is now the
   description of what the committed file contains, not work left to do.
   `flake.nixosModules.chat-server`, gated on
   `noughtyLib.hostHasTag "chat-server"` and added to `alwaysImport` in
   `modules/builder.nix`, following the shape of
   `modules/hetzner/mail/mail.nix`:
   - `services.postgresql` — enable, `settings.listen_addresses = lib.mkForce ""`
     (landmine 1), `ensureDatabases` + `ensureUsers` for `matrix-synapse`,
     `mautrix_whatsapp`, `mautrix_signal`, `mautrix_discord`. **Correction to
     the original plan:** the C collation Synapse demands cannot be set per
     database — `ensureDatabases` issues a bare `CREATE DATABASE` — so it comes
     from the cluster's `initdbArgs` instead, and ownership for the three
     bridge DBs is handed over in `postStart` (landmines 9 and 10).
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
7. **Secrets** — the file and the wiring already exist; the values are
   placeholders. See the **Secrets** section below for the five keys and the
   exact commands. This must happen *before* the first `deploy`, or Synapse and
   all three bridges start with a known-bad shared secret.
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

11b. **`modules/chat.nix`, client half** — `flake.homeModules.chat` is **written
    but deliberately not imported yet**, so no desktop closure has changed. It
    is the only step that touches the desktops rather than the server, and
    wiring it early would install Element on `blac`, `g14` and `z14` months
    before there is a homeserver to point it at. To turn it on: import it from
    `flake.homeModules.gui-nixos` (`modules/hosts/types/gui/default.nix`), which
    is the list those three already pull. The Mac takes an `element` cask in
    `gui-darwin` instead, for the Spotlight reason documented on `affine` and
    `discord` there.
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

## Secrets

Everything lives in one per-app sops file, **`modules/homelab/secrets/chat.yaml`**,
created by the `.sops.yaml` rule for `modules/homelab/secrets/.*\.yaml$` — the
same single age recipient as the rest of the repo, so no per-host re-encryption
and nothing to do on the new box beyond the shared key already being at
`/home/phonkd/.config/sops/age/keys.txt`.

**The file is committed with obvious placeholders** (`REPLACE-ME-…`). That is
deliberate, not an oversight: landmine 11 — sops-nix resolves the file at
evaluation time, so the host will not evaluate at all until it exists and is
tracked. Committing it empty-but-valid is what lets the module be reviewed and
type-checked before the VM exists.

### What is *not* here

No account credentials, and nothing you have to fetch from a third party. All
five values are random strings this repo generates. The actual logins are
runtime operations over a bot DM, after the server is up:

- **WhatsApp** — `!wa login`, scan the QR from the phone's linked-devices screen.
- **Signal** — `!signal login`, likewise a linked device.
- **Discord** — `!discord login-token <token>`, pasted into the bot DM. The token
  itself never enters this repo. (Landmine 4 — user-token mode is ToS-gray; the
  bot-token alternative cannot see DMs. Still an open decision.)

### Filling them in

From the repo root, in the devshell (`nix develop`), using this repo's own
helper — `sops-secret <app>.<key> --generate` mints 48 random bytes, stores it
as `chat_<key>`, and re-encrypts the file in place:

```sh
for k in \
  synapse-registration-shared-secret \
  synapse-macaroon-secret-key \
  synapse-form-secret \
  whatsapp-pickle-key \
  signal-pickle-key
do
  sops-secret "chat.$k" --generate
done
```

**Verify none survived** before deploying:

```sh
sops decrypt modules/homelab/secrets/chat.yaml | grep -c REPLACE-ME   # must print 0
```

Then commit the re-encrypted file. Only ciphertext changes; the plaintext never
touches the working tree.

### The five keys, and where each lands

| sops key (`chat_…`) | consumed as | by |
|---|---|---|
| `synapse_registration_shared_secret` | `registration_shared_secret` | Synapse, via `extraConfigFiles` |
| `synapse_macaroon_secret_key` | `macaroon_secret_key` | ” |
| `synapse_form_secret` | `form_secret` | ” |
| `whatsapp_pickle_key` | `$MAUTRIX_WHATSAPP_ENCRYPTION_PICKLE_KEY` | mautrix-whatsapp, via `environmentFile` |
| `signal_pickle_key` | `$MAUTRIX_SIGNAL_ENCRYPTION_PICKLE_KEY` | mautrix-signal, via `environmentFile` |

Synapse's three go through a `sops.templates` YAML fragment because the module
refuses them as in-store values (landmine 6) — not because of env vars; they are
a file. Of the three, `macaroon_secret_key` is the one that genuinely must never
leak: it signs access tokens, so a known value is account takeover.

The two `pickle_key`s go through `sops.templates` **env** files, because the
substitution happens in `preStart` via envsubst (landmine 8) — a value put
straight into `settings` would be world-readable in `/nix/store`.

Rotating a `pickle_key` invalidates that bridge's existing encrypted sessions.

### Why this is five keys and not fourteen

The first cut of this plan protected four secrets per bridge. Checking the
bridges' own `example-config.yaml` (via the vendored mautrix-go bridgev2 config
for WhatsApp/Signal, and the in-tree one for Discord) showed most of them guard
nothing:

- **`public_media.signing_key`** — `public_media.enabled: false`, and enabling it
  also requires an `appservice.public_address`. Dead config until then.
- **`direct_media.server_key`** — `direct_media.enabled: false`, and enabling it
  needs a `server_name` plus `.well-known` delegation to it. Likewise dead.
- **`provisioning.shared_secret`** — accepts the documented literal
  `"disable"`, which switches the provisioning HTTP API off outright. The
  bridges are driven by `!wa` / `!signal` / `!discord` bot DMs, so turning the
  endpoint off is strictly better than guarding an unused one with a managed
  secret. (nixpkgs' `""` default would fail upstream's own "must be at least 16
  characters" rule anyway.)
- **Discord needs no secrets at all.** Its config has no pickle key (zero
  occurrences of `pickle`), and `avatar_proxy_key` only signs avatar URLs when
  `public_address` is set — "if not set, avatars will not be bridged". So it
  gets no `environmentFile`.

Also worth correcting the original premise: nixpkgs defaults these to `""`, not
`"generate"`, so they do **not** silently rotate on every restart the way the
modules' own stale comments suggest. The real problem with the default
`pickle_key` is narrower — it is empty, and identical on every install.

If `public_media` or `direct_media` is ever switched on, add that key back as an
env var at the same time; that is the moment it starts mattering.

### So are the dropped ones generated, and thrown away?

Worth being precise, because the two bridge families behave differently:

- **WhatsApp and Signal** — nixpkgs pins the dropped keys to `""`, which is not
  `"generate"`, so **nothing is generated**. The config simply carries an empty
  value for a feature that is switched off. Nothing rotates.
- **Discord** — its nixpkgs defaults really do say `"generate"` for
  `avatar_proxy_key` and `direct_media.server_key`. Those *are* generated at
  each start, written into the config in the state directory, and then thrown
  away when the next start rebuilds that file from the nix store. So yes: for
  those two, generated-and-not-persisted, i.e. a new value every restart.

  That is harmless **only because both features are off** — `public_address` is
  `null` ("if not set, avatars will not be bridged") and `direct_media.enabled`
  is `false`. If either is ever enabled, that rotation stops being cosmetic and
  the key has to move to an `environmentFile` like the pickle keys.

Nothing else is orphaned in the other direction either: all five keys in
`chat.yaml` are referenced by the module, and no referenced key is missing from
the file.

## Open decisions

- **New VM vs. the mailserver VM — RESOLVED 2026-09-20: reuse `ext-mail`.**
  This plan had recommended a separate `ext-matrix` on blast-radius grounds; the
  call went the other way, for box count and the €4/month. Recorded honestly so
  that reversing it later is cheap and so the accepted risk is not forgotten:

  - **What we accepted.** One nginx and one reload path now serve both mail and
    a Synapse that changes far more often, so a broken matrix vhost can take the
    webmail/CalDAV vhosts down with it. A bridge OOM or a Synapse schema
    migration can now hurt mail — whose deliverability and DKIM reputation are
    the one thing in this fleet that is genuinely hard to rebuild.
  - **What was never actually a risk.** 80/443 was not contention:
    `matrix.phonkd.net` is simply a third vhost beside `mail.` and `cal.`
    (verified — all three render on the host). Postgres vs sshd on :5432 is real
    but identical on any `hetzner-vm` host, and `listen_addresses = mkForce ""`
    handles it either way.
  - **Side effect of tagging `ext-mail`.** Docker is now forced **off** there.
    Nothing on that host used it, and it reclaims ~1 GB of closure — but it is a
    change to a live box, not a no-op.
  - **Reversing costs one registry line** plus a VM bootstrap: move the
    `chat-server` tag onto a new `ext-matrix` stanza. **Nothing in
    `modules/chat.nix` changes** — gating on a tag is exactly what buys that.
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

## Bootstrap fact not captured in git

`ext-mail` could not decrypt `global-secrets/secret.yaml` or
`homelab/secrets/chat.yaml`. Both are encrypted to the single fleet-shared
recipient `age1jsnyg…`, and that host's `/home/phonkd/.config/sops/age/keys.txt`
held only a mail-specific key (`age1y5wx…`, the recipient of `mail-secret.yaml`).
Its ssh-derived age key (`age19qhp…`) is not a recipient of anything. So every
rebuild died in the `setupSecrets` activation snippet with
`Error getting data key: 0 successful groups required, got 0`.

**This is also why `ext-mail` never enrolled in the headscale mesh** — the only
secret it takes from the global file is `tailnet.nix`'s `headscale_authkey`, so
it could never read the pre-auth key. That had been recorded as an unexplained
oddity; it was this all along.

Resolved by hand on the host: the shared key was appended to that `keys.txt`.
**That edit lives on the box, not in this repo** — a rebuilt or replaced
`ext-mail` needs it done again, and nothing in the flake will remind you. The
alternative considered was adding `age19qhp…` as a second recipient in
`.sops.yaml` and `sops updatekeys`-ing both files, which keeps the fleet-wide key
off the most internet-exposed host; not taken, but it remains the better shape if
that key is ever rotated.
