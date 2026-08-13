# AFFiNE self-hosted on 201-mono

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Add [AFFiNE](https://affine.pro) as a self-hosted note-taking workspace on
`201-mono`, reachable at `https://affine.int.w.phonkd.net`, LAN/tailnet-only
(`ipfilter = true`), listed on the homepage dashboard.

AFFiNE is a block-based docs/whiteboard app (Notion + Miro shaped). It is
*additive*, not a replacement: `homelab-notes` keeps serving memos at
`notes.int.w.phonkd.net` for quick captures, and the Obsidian home-module is
untouched. Nothing migrates.

## Approach

**nixpkgs has no AFFiNE server.** `pkgs.affine` / `pkgs.affine-bin` are the
Electron *desktop client* only, and there is no `services.affine` NixOS module
in the pinned nixpkgs. Upstream ships self-hosting exclusively as a container
(`.docker/selfhost/compose.yml`, image `ghcr.io/toeverything/affine`). So the
server runs as an OCI container — the first one in this repo.

**Hybrid, not a compose translation.** Upstream's compose stands up four
containers: `affine`, a one-shot `affine_migration`, `redis`, and
`pgvector/pgvector:pg16`. Only the app itself has to be a container. Postgres
and Redis are ordinary NixOS services here, which keeps them inside the normal
backup/observability/GC story instead of behind a container runtime:

| upstream compose | here |
|---|---|
| `postgres` (pgvector/pgvector:pg16) | `services.postgresql` + `extensions = ps: [ ps.pgvector ]` |
| `redis` | `services.redis.servers.affine` on :6379 |
| `affine_migration` | `affine-migrate.service`, a systemd one-shot `podman run --rm` |
| `affine` | `virtualisation.oci-containers.containers.affine` |

The app container runs with `--network=host`, so it binds :3010 on 201's
loopback+LAN (the host firewall only opens 80/443/22/53/51820, so :3010 is not
externally reachable) and reaches Postgres and Redis at `127.0.0.1` with no
bridge, no `host.containers.internal`, no gateway-IP guessing. Traefik then
routes to `127.0.0.1:3010` exactly like vaultwarden and paperless.

**Backend: podman**, not docker. Nothing on 201 runs containers today, and
`virtualisation.docker.enable` is currently scoped to the `hetzner-vm` host type
only — no reason to bring a daemon and a `docker` group onto the reverse proxy.

## Steps

- [x] Confirm no `services.affine` in nixpkgs; confirm image tags on ghcr
- [x] Verify option names against nixpkgs source (`extensions` not
      `extraPlugins`; `authentication` lines insert *above* the md5 defaults;
      named `services.redis.servers.<n>.port` defaults to 0 and must be set)
- [x] Check port 3010 / 6379 / 5432 are unclaimed on 201
- [x] `modules/homelab/apps/affine.nix` — new `flake.nixosModules."homelab-affine"`,
      gated on `hostHasTag "homelab-server"`
- [x] Register it in `modules/builder.nix` `alwaysImport`
- [x] `nix-instantiate --parse` both files; confirm the unit names the module
      references really are `redis-affine.service` / `podman-affine.service` /
      `postgresql-setup.service`
- [ ] Commit → land on `main` → `deploy 201`
- [ ] First-run: visit the domain, create the admin account through the setup page

## Open decisions

- **Pinned image, not `stable`.** `image = "ghcr.io/toeverything/affine:0.27.3"`
  pinned by digest. Upstream's compose defaults to the floating `stable` tag,
  which would silently move a major-ish version under us on any container
  restart and re-run migrations unattended. Pinning matches how `homelab-notes`
  pins memos 0.27.1. Cost: version bumps are a manual edit (tag + digest).
- **Postgres auth is `trust`, scoped to `host affine affine 127.0.0.1/32`.**
  Postgres listens on loopback only (`listen_addresses = "localhost"`, we do not
  set `enableTCPIP`), and the rule names one database and one role. Upstream's
  own compose ships `POSTGRES_HOST_AUTH_METHOD: trust`. The alternative — a
  sops-managed password — needs an `ALTER ROLE` in `postgresql.postStart`
  because this nixpkgs' `ensureUsers` has no `passwordFile`; that is more
  moving parts guarding a loopback socket on a single-user VM. Easy to upgrade
  later if 201 ever gains other local users.
- **No admin credentials in config.** `AFFINE_ADMIN_EMAIL` / `_PASSWORD` are
  deliberately *not* set, so the first visit goes to AFFiNE's own setup page and
  the password never sits in the nix store or sops. Safe because the route is
  `ipfilter = true` — the setup page is unreachable off the LAN/tailnet. The
  alternative (sops-provisioned admin) buys a hands-off first boot; not worth a
  secret for a one-time click.
- **`AFFINE_INDEXER_ENABLED=false`**, matching upstream's compose — the indexer
  wants Elasticsearch. Full-text search across docs is therefore limited to
  what the client does locally. Revisit if search turns out to matter; that is
  a follow-up, not a blocker.

## Risks / rollout

- **This lands on 201, the reverse proxy.** Everything added is additive
  (a new postgres, a new redis, a new container, one new traefik router); no
  existing service's config is touched. The failure mode to watch is a *new*
  service failing to start, not the proxy going down — magic rollback only
  catches lost connectivity, so verify units after `deploy 201`.
- **First deploy pulls ~1 GB** from ghcr on 201 and runs migrations. The
  container unit will restart-loop until `affine-migrate.service` has succeeded
  once; check `systemctl status affine-migrate podman-affine`.
- **New disk consumers on 201's system disk**: `/var/lib/postgresql`,
  `/var/lib/affine/{storage,config}`. Uploads (images/attachments) grow there.
- **Back out**: drop the module from `alwaysImport` and `deploy 201`. State
  survives in `/var/lib/affine` and the `affine` database, so re-enabling
  resumes; a true wipe is `rm -rf /var/lib/affine` + `DROP DATABASE affine`.
