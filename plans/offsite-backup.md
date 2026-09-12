# offsite backup

**Repo(s):** nixconfig   **Status:** draft

_Decisions to lock before implementation:_ backup **level** (file-level restic vs
image-level PBS), **target** (Infomaniak Swiss Backup vs a NAS at a second
address), and the **capacity to order** — see *Open decisions*.

## Goal

Nothing in this homelab is backed up today. `grep -rn restic|borg|kopia|rclone
modules/` returns nothing; the only hit for "backup" is Immich's product
description. A dead disk on 203, a bad `rm`, or ransomware on the Samba share
currently loses ~1.7 TB of irreplaceable files with no second copy anywhere.

Target state: every irreplaceable byte lands **encrypted, incremental, weekly**
in a second location, with the Jellyfin/*arr media pile deliberately excluded
(it is re-downloadable and it is also the fastest-growing thing on the box).
Cheap enough to not think about — budget on the order of CHF 10–20/month.

## What is actually there (measured, not estimated)

Pulled from Mimir (`node_filesystem_*`, 2026-09-12), so these are live figures:

| Host | Mount | Used | Disk | 30-day growth |
|---|---|---|---|---|
| 203-media | `/mnt/Shares` (Samba) | **1 659 GB** | 3 170 GB | −94 GB |
| 203-media | `/mnt/solo-sata` (immich + oCIS + nixflix) | **1 617 GB** | 3 170 GB | **+191 GB** |
| 201-mono | `/mnt/syncthing` | 63 GB | 210 GB | ~0 |
| 201-mono | `/mnt/s3` (Garage) | 54 GB | 537 GB | ~0 |
| 201-mono | `/` | 30 GB | 127 GB | — |
| 203-media | `/` | 65 GB | 105 GB | — |
| 204-agent | `/` | 21 GB | 105 GB | — |

**The estimate of "about 4 TB" is high.** Total used across the data mounts is
3.4 TB, but that number *includes* the nixflix media. Excluding it, the backup
set is Samba 1.66 TB + Garage 54 GB + Syncthing 63 GB + Immich + oCIS + a few GB
of `/var/lib` service state — realistically **2–2.6 TB**.

The one number still missing is the immich / oCIS / nixflix split inside
`/mnt/solo-sata` (1 617 GB total). Measure it first — it decides the capacity to
order, and it is one command:

```
ssh 203-media 'du -shx /mnt/solo-sata/* /mnt/Shares/*'
```

(Could not be run from this session: ssh from the background job fails at
`No user exists for uid 501` — macOS directory services do not answer in that
context. Mimir over the tailnet did answer, which is where the table above comes
from.)

### Finding that shapes the design

`/mnt/solo-sata` is **one virtual disk** (`/dev/disk/by-id/virtio-solo-sata`,
`modules/hosts/203-media.nix:246`) holding all three of:

- `/mnt/solo-sata/immich` — keep (irreplaceable photos)
- `/mnt/solo-sata/ocis` — keep
- `/mnt/solo-sata/nixflix/{tv,music,downloads}` — drop (re-downloadable, +191 GB/mo)

So "exclude the Jellyfin disk" **cannot be done at disk granularity** — the
photos are on the same disk as the media. Any image-level scheme (Proxmox
vzdump / PBS with `backup=0` on a disk) either backs up the whole 1.6 TB
including the media, or needs the media moved to a new dedicated disk first.
File-level backup selects by path and sidesteps this entirely.

## Approach

**Phase 1 (recommended, do this first): file-level restic to S3, declared in this repo.**

restic is the right tool here: content-defined chunking (true incrementals, only
changed blocks upload), AES-256 client-side encryption by default, zstd
compression, native S3 backend, and a first-class NixOS module
(`services.restic.backups.<name>`, verified present in this flake's nixpkgs —
`paths`, `exclude`, `passwordFile`, `environmentFile`, `initialize`,
`pruneOpts`, `checkOpts`, `backupPrepareCommand`, `extraBackupArgs`,
`timerConfig`).

Why file-level rather than image-level, for *this* homelab specifically: every
host's OS is fully declared in this flake and rebuilt by `deploy <host>`. The
bytes of a NixOS root filesystem are reproducible; backing them up is paying to
store something git already holds. What is *not* reproducible is the data. A
disaster recovery here is `deploy <host>` + `restic restore` — and the first half
of that is exercised every time anything ships, which is the only kind of
restore path that is actually known to work.

Two backup sets per host, because the data has two very different tempos:

| Set | Contents | Schedule | Size |
|---|---|---|---|
| `critical` | service state + DB dumps: `/var/lib/{vaultwarden,paperless,authelia-main,crowdsec,affine}`, `/var/lib/traefik/acme.json`, the *arr configs, `/var/lib/slop-trove/exports`, `/etc/ssh/ssh_host_*` | **daily** 03:00 | a few GB |
| `bulk` | `/mnt/Shares`, `/mnt/solo-sata/{immich,ocis}`, `/mnt/syncthing/data`, `/mnt/s3/{data,meta}` | **weekly** Sun 02:00 | ~2–2.5 TB |

Excluded everywhere: `/mnt/solo-sata/nixflix/**`, `/nix/store`, `/var/cache`,
container image layers, Ollama models (re-downloadable, large), and
`/var/lib/{loki,mimir}` on the observability host (regenerable telemetry).

**Databases must be dumped, not copied.** restic walking a live Postgres data
directory produces a torn, unrestorable backup. Per host:

- **203-media** runs Postgres (Immich, and Affine shares that instance —
  `modules/homelab/apps/affine.nix:117`). `backupPrepareCommand` runs
  `pg_dumpall --clean --if-exists` into a staging dir that `critical` then
  picks up. Immich caveat: its vector extension means the restore path is
  dump + reindex, not a raw file copy — verify against Immich's current
  documented dump flags at implementation time.
- **201-mono** is all SQLite (Vaultwarden, Paperless — this repo does not set
  `database.createLocally`, whose nixpkgs default is `false`, so Paperless is
  on SQLite, not Postgres — and Authelia at
  `/var/lib/authelia-main/db.sqlite3`). Use `sqlite3 … ".backup"`, never a
  plain copy. For Vaultwarden, prefer the module's own
  `services.vaultwarden.backupDir` (it ships a daily SQLite `.backup` timer)
  and point restic at that directory.
- **Garage** (`/mnt/s3`, LMDB metadata) wants a consistent meta+data pair.
  Simplest: stop `garage.service` for the seconds the snapshot takes in
  `backupPrepareCommand`, restart in `backupCleanupCommand`. Alternative if
  that downtime is unwanted: `rclone sync` the buckets out through Garage's own
  S3 API into a staging dir instead.

**Phase 2 (optional, decide later): Proxmox Backup Server → S3 for whole-VM images.**
PBS 4.2 (April 2026) promoted S3-backed datastores out of tech preview, so PBS
can push deduplicated, encrypted, incremental VM images straight to the same
Swiss Backup bucket. What it buys over Phase 1: click-to-restore an entire VM,
and coverage of the Proxmox host itself, which is the one machine in the fleet
*not* declared in this repo. What it costs: a Debian VM to maintain (non-
declarative, against the grain here), a local cache disk, and either backing up
the 1.6 TB media pile or first splitting it onto its own disk. Note PBS does not
support S3 Object Lock — enabling it on the bucket corrupts the datastore.

A cheap middle ground that captures most of Phase 2's value for ~nothing: have
`critical` on 201 also pick up a nightly `vzdump`-style dump of the **Proxmox VM
configs** (`/etc/pve`, a few KB of text). VM configs plus this flake plus the
restored data is a complete rebuild recipe without storing a single OS image.

## Cost

**Infomaniak Swiss Backup** is a good fit and the published rates support the
instinct: capacity-based billing with **unmetered traffic** (no egress or
per-request fees), S3 + Swift + SFTP endpoints, restic explicitly documented as
supported, Swiss jurisdiction, and a **90-day free trial** — which is long
enough to cover the initial 2.5 TB seed for free.

Quoted rates are inconsistent across sources and must be confirmed in the
Manager order flow: CHF 2.40/mo for the 200 GB entry tier, ~EUR 3.75–4.18/mo per
TB at the 1 TB tier, while one 2026 review lists EUR 8.49 for 1 TB. Budget
**CHF 4–8 per TB per month** until confirmed.

At ~2.5 TB, storage only, roughly converted:

| Option | ~CHF/mo | 3-year | Notes |
|---|---|---|---|
| **Infomaniak Swiss Backup** | **10–21** | **360–760** | unmetered restore, Swiss, restic-documented, 90-day trial |
| Backblaze B2 | ~14 | ~500 | $6.95/TB, egress free up to 3× stored |
| Storj | ~9 + egress | ~350+ | $4/TB + $7/TB egress |
| Wasabi | ~16 | ~580 | 90-day minimum retention — penalizes prune/churn |
| Scaleway One Zone IA | ~19 | ~700 | EUR 8.03/TB + EUR 0.01/GB egress over 75 GB |
| Scaleway Glacier | ~6 | ~230 | EUR 2.54/TB **but** restic cannot read it directly (objects need restoring first) and restore costs EUR 0.009/GB |
| Cloudflare R2 | ~35 | ~1 270 | $15/TB, zero egress |

Unmetered restore is worth more than it looks: it makes `restic check
--read-data-subset` — the only thing that proves the backup is actually
readable — free to run monthly. On B2 or Scaleway that verification costs money
every time, which in practice means it never gets run.

**NAS, 3-year total cost of ownership** (~4 TB usable):

- enclosure or mini-PC: CHF 150–400
- disks: 1× 8 TB ≈ CHF 160, or 2× 8 TB mirrored ≈ CHF 300–400
- power at ~10 W average, CHF 0.32/kWh: ~CHF 28/yr → **CHF 84 over 3 years**
- **3-year total: CHF 400–650 single disk, CHF 530–880 mirrored**

So the NAS does **not** clearly win on a 3-year horizon — it lands in the same
CHF 400–900 band as the cloud, with capex up front, a device to maintain, and no
Swiss-datacentre durability. It only pulls clearly ahead past ~5 years.

The decisive point is not cost, it is **location**: a NAS in the same flat is
not a backup against fire, flood, burglary, or a lightning strike on the same
power bus — it is a second copy of a single failure domain. A NAS only becomes
a real answer if it lives at a **second address**. That is genuinely attractive
here, because the headscale mesh already exists: a small box at a relative's or
the office, joined to the tailnet, running `rest-server` or plain SSH, is a
restic target one config line away — and restic's repository format is identical
across backends, so switching is a one-line change with a re-seed, not a
redesign.

**Recommendation:** start on Swiss Backup during the free 90-day trial (zero
capex, genuinely offsite from day one, and the trial covers the slow initial
seed). Revisit the NAS at the end of the trial with a real bill in hand and, if
it goes ahead, put it at a second address rather than next to the Proxmox box.

## Steps

1. **Measure the split** — `ssh 203-media 'du -shx /mnt/solo-sata/* /mnt/Shares/*'`.
   Decides the capacity tier and confirms whether anything large is hiding in the
   private share (the Jellyfin `clips` library lives under `/mnt/Shares`, so if it
   is big it belongs on the exclude list too).
2. **Order Swiss Backup** at the measured size + ~30 % headroom, start the 90-day
   trial, create a Cloud device → S3 credentials (endpoint is
   `https://s3.swiss-backup0N.infomaniak.com`, N varies by cluster).
3. **Secrets** — add `restic-password` (generate long and random),
   `restic-s3-access-key`, `restic-s3-secret-key` to
   `modules/homelab/global-secrets/secret.yaml` via `sops set`; compose
   `sops.templates."restic.env"` for restic's `environmentFile`.
4. **Escrow the keys, on paper.** The restic password and the sops age key must
   exist somewhere outside every machine being backed up. They cannot live in
   Vaultwarden — Vaultwarden is *inside* the backup, so that is a circular
   dependency that fails exactly when it is needed. Printed copy plus the Mac's
   password manager.
5. **New module** `modules/backup.nix` → `flake.nixosModules.homelab-backup`,
   self-gated on a `backup-client` tag (or `config.noughty.host.is.server`),
   added to `alwaysImport` in `modules/builder.nix`. It declares the per-host
   `critical` / `bulk` path sets and maps them onto `services.restic.backups.*`.
   Tag 201-mono, 203-media, 204-agent in `lib/registry.nix`.
6. **Seed, bandwidth-capped.** Set `extraBackupArgs = [ "--limit-upload=<KiB/s>" ]`
   so the first pass does not saturate the household uplink. Seeding 2.5 TB takes
   **~12 days at 20 Mbit/s, ~5 days at 50, ~2.5 days at 100, ~7 h at 1 Gbit/s** —
   this is the single biggest practical risk in the whole plan. restic resumes
   cleanly across interruptions; seed `critical` first, then `bulk` path by path
   so each run completes on its own.
7. **Retention & prune.** `critical`: `--keep-daily 14 --keep-weekly 8
   --keep-monthly 12`. `bulk`: `--keep-weekly 5 --keep-monthly 6 --keep-yearly 2`.
   Prune monthly, staggered so the two sets never run at once.
8. **Alerting, via the wiring that already exists.** Senders already run Alloy
   with node_exporter's `systemd` and `textfile` collectors enabled
   (`modules/observability.nix:586`), so no new plumbing is needed:
   - failure: `node_systemd_unit_state{name=~"restic-backups-.*",state="failed"} == 1`
   - staleness (catches the worse failure — a timer that silently stopped firing):
     `time() - node_systemd_timer_last_trigger_seconds{name="restic-backups-bulk.timer"} > 9*24*3600`

   Add both to the rules pushed by `mimir-rules-sync` — and scope the sync with
   `--namespaces=` as always, or it deletes every other rule group in the tenant.
9. **Verify + drill.** Monthly `restic check --read-data-subset=10%` (free on
   unmetered Swiss Backup). Quarterly, restore a real file to `/tmp` and diff it.
   A backup that has never been restored is a hypothesis, not a backup.
10. **Document the restore** in the plan or the `nixconfig-ops` skill: rebuild
    host via `deploy <host>`, then `restic restore latest --target /`. Mark this
    plan `done`.

## Open decisions

- **File-level (restic) vs image-level (PBS).** Recommending restic: declarative,
  no extra VM, selects by path (which the shared `solo-sata` disk forces), and
  stores only what git cannot regenerate. The alternative — PBS 4.2 → S3 — buys
  click-to-restore whole VMs and covers the Proxmox host, at the price of a
  hand-maintained Debian VM and either storing the media pile or splitting the
  disk first. The literal reading of "VM backups incremental" is PBS; the thing
  that actually protects the data for less money is restic. Both can coexist —
  restic now, PBS later if whole-VM restore turns out to be missed.
- **Cloud now vs NAS now.** Recommending cloud first: zero capex, offsite
  immediately, free 90-day trial covers the seed. Revisit with a real bill.
  If a NAS happens, **put it at a second address** — otherwise it is a second
  copy, not a backup.
- **Capacity to order.** Recommending 3 TB after measuring, on a ~2–2.6 TB set.
  Drop to 2 TB if Immich turns out small.
- **Ransomware / credential blast radius.** A root compromise on 201 or 203 can
  `restic forget --prune` the repository with the same credentials it backs up
  with. The clean mitigation is append-only credentials on the hosts with prune
  run separately from the Mac — feasibility depends on whether Swiss Backup's S3
  supports per-prefix policies, which needs checking during the trial. If it does
  not, accept the risk explicitly or keep a second copy.
- **One repo per host vs one shared repo.** Recommending per-host: independent
  locking and prune, no cross-host contention. Shared would dedup across hosts,
  but under capacity-based billing that saves nothing meaningful.

## Risks / rollout

- **The seed is long.** Days of upload at a residential uplink. Bandwidth-cap it
  and expect the first `bulk` snapshot to span several nights. Nothing else in
  the plan can be verified until it lands.
- **Silent DB corruption** is the classic failure: backups run green for a year,
  then the Postgres restore fails. Mitigated by dumping rather than copying, and
  caught only by step 9's restore drill. Do not skip step 9.
- **Losing the restic password loses everything** — the repository is
  unrecoverable without it, by design. Step 4 is not optional.
- **Garage stop/start window** briefly interrupts S3 during the weekly run.
  Seconds, at 02:00 Sunday; call it acceptable or take the rclone route.
- **Rollout** is per-host and additive: `deploy 204-agent` first (smallest,
  lowest stakes), then `deploy 203-media`, then `deploy 201-mono` last since it
  fronts everything. Backing out is deleting the module and the timers; nothing
  else in the system depends on it.
