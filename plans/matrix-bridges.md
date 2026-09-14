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

### Why a new VM rather than the mailserver VM

Reusing `ext-mail` was the other candidate. Against it:

- **`ext-mail` is the fleet's one hand-managed box.** It has no `deploy.hostname`
  in `lib/registry.nix`, and it does not appear in `tailscale status` at all — it
  never enrolled in the headscale mesh. Landing a service there means first
  fixing enrolment + deploy plumbing, which is most of the cost of standing up a
  fresh VM anyway.
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

1. **Provision the VM.** Hetzner CX22, x86_64, same project and private network as
   `ext-mail`/`observability`. Install NixOS the way those two were done. Open
   80/443 in the Hetzner cloud firewall. Record the public IP and the `/` + `/efi`
   disk UUIDs.
2. **DNS:** create `matrix.phonkd.net A <ip>` in Cloudflare. (SRV comes in step 8,
   once the server answers.)
3. **`lib/registry.nix`:** add an `ext-matrix` stanza — `kind = "server"`,
   `tags = [ "vm" "hetzner-vm" "matrix-server" "observability-sender" ]`,
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
6. **`modules/hetzner/matrix/matrix.nix`** — the service module, gated on
   `noughtyLib.hostHasTag "matrix-server"`, following the shape of
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

- **New VM vs. the mailserver VM.** Recommending a new `ext-matrix` for the
  reasons above. If cost or box-count wins instead, the delta is: enrol `ext-mail`
  in the tailnet and give it `deploy.hostname` first (it has neither today), add
  the matrix vhosts to its existing nginx, and accept that a bridge OOM can take
  mail with it. Everything else in this plan is unchanged.
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
