# offsite backup

**Repo(s):** nixconfig   **Status:** draft — target decided, not yet built

_Decisions locked (2026-09-12):_ a **second location is available**, so the
primary target is a **NixOS box there running `restic.server` in append-only
mode**, CHF 400–660 for 2× 12 TB mirrored plus the box. Everything is
**client-side encrypted by restic** (AES-256) regardless of target. A small
Infomaniak Swiss Backup tier carries the crown jewels as a third copy.

## Goal

Nothing in this homelab is backed up today. `grep -rn restic|borg|kopia|rclone
modules/` returns nothing; the only hit for "backup" is Immich's product
description. A dead disk on 203, a bad `rm`, or ransomware on the Samba share
currently loses ~1.7 TB of irreplaceable files with no second copy anywhere.

Target state: every irreplaceable byte lands **encrypted, incremental, weekly**
in a second physical location, cheap enough to stop thinking about.

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
3.4 TB, but that includes the nixflix media. Excluding it, the backup set is
Samba 1.66 TB + Garage 54 GB + Syncthing 63 GB + Immich + oCIS + a few GB of
`/var/lib` service state — realistically **2–2.6 TB**.

With 12 TB of usable space on the NAS, though, the exclusion stops being a
budget question — see *Capacity*. The number still missing is the
immich / oCIS / nixflix split inside `/mnt/solo-sata` (1 617 GB total):

```
ssh 203-media 'du -shx /mnt/solo-sata/* /mnt/Shares/*'
```

(Not runnable from the background job that wrote this: ssh there fails at
`No user exists for uid 501` — macOS directory services do not answer in that
context. Mimir over the tailnet did, which is where the table comes from.)

### Finding that shapes the design

`/mnt/solo-sata` is **one virtual disk** (`/dev/disk/by-id/virtio-solo-sata`,
`modules/hosts/203-media.nix:246`) holding all three of:

- `/mnt/solo-sata/immich` — keep (irreplaceable photos)
- `/mnt/solo-sata/ocis` — keep
- `/mnt/solo-sata/nixflix/{tv,music,downloads}` — re-downloadable, +191 GB/mo

So "exclude the Jellyfin disk" **cannot be done at disk granularity** — the
photos share a disk with the media. Any image-level scheme (Proxmox vzdump or
PBS with `backup=0`) either stores the whole 1.6 TB or needs the media moved to
its own disk first. File-level restic selects by path and sidesteps it.

## Approach

**restic, file-level, pushing to a NixOS NAS at the second location over the
existing tailnet.**

restic is the right tool: content-defined chunking (true incrementals — only
changed blocks move), AES-256 client-side encryption *by default*, zstd
compression, and a first-class NixOS module on both ends. All option names below
are verified against this flake's nixpkgs.

Why file-level rather than image-level, for *this* homelab: every host's OS is
declared in this flake and rebuilt by `deploy <host>`. The bytes of a NixOS root
filesystem are reproducible — backing them up pays to store what git already
holds. What is *not* reproducible is the data. Disaster recovery here is
`deploy <host>` + `restic restore`, and the first half of that is exercised
every time anything ships, which is the only kind of restore path known to work.

### The append-only trick (this is why a self-hosted target wins)

The NAS runs `services.restic.server` with **`appendOnly = true`**. Hosts can
create and read snapshots but **cannot delete them**. A root compromise on 201
or 203 — the scenario where ransomware encrypts the Samba share and then goes
looking for the backups — cannot destroy backup history. No S3 provider in the
earlier comparison offers this as simply.

Pruning still has to happen, and this is where the key handling matters:

- **Hosts** push over `rest:http://<nas>:8000/<host>` — append-only, so their
  credentials are useless for destruction.
- **The Mac** prunes, checks and restores over `sftp:nas:/srv/restic/<host>`,
  bypassing rest-server entirely with full rights, gated on its SSH key.

The consequence worth stating plainly: **the NAS never holds the restic
password.** If the box is stolen from the second location, the thief gets
encrypted blobs and nothing else. That falls out of the design rather than
needing full-disk encryption bolted on.

### Backup sets

Two per host, because the data has two very different tempos:

| Set | Contents | Schedule | Size |
|---|---|---|---|
| `critical` | service state + DB dumps: `/var/lib/{vaultwarden,paperless,authelia-main,crowdsec,affine}`, `/var/lib/traefik/acme.json`, the *arr configs, `/var/lib/slop-trove/exports`, `/etc/ssh/ssh_host_*` | **daily** 03:00 | a few GB |
| `bulk` | `/mnt/Shares`, `/mnt/solo-sata/{immich,ocis}`, `/mnt/syncthing/data`, `/mnt/s3/{data,meta}` | **weekly** Sun 02:00 | ~2–2.5 TB |

Excluded: `/nix/store`, `/var/cache`, container image layers, Ollama models
(re-downloadable, large), `/var/lib/{loki,mimir}` (regenerable telemetry), and —
for now — `/mnt/solo-sata/nixflix/**`.

**Databases must be dumped, not copied.** restic walking a live Postgres data
directory produces a torn, unrestorable backup.

- **203-media** runs Postgres (Immich; Affine shares that instance —
  `modules/homelab/apps/affine.nix:117`). `backupPrepareCommand` runs
  `pg_dumpall --clean --if-exists` into a staging dir that `critical` picks up.
  Immich caveat: its vector extension makes the restore path dump + reindex,
  not a raw file copy — check Immich's current documented dump flags when
  implementing.
- **201-mono** is all SQLite (Vaultwarden; Paperless — this repo does not set
  `database.createLocally`, whose nixpkgs default is `false`, so Paperless is on
  SQLite; Authelia at `/var/lib/authelia-main/db.sqlite3`). Use
  `sqlite3 … ".backup"`, never a plain copy. For Vaultwarden prefer the module's
  own `services.vaultwarden.backupDir`, which already ships a daily SQLite
  `.backup` timer, and point restic at that directory.
- **Garage** (`/mnt/s3`, LMDB metadata) needs a consistent meta+data pair. Stop
  `garage.service` for the seconds the snapshot takes in `backupPrepareCommand`,
  restart in `backupCleanupCommand`. Alternative if that downtime is unwanted:
  `rclone sync` the buckets out through Garage's own S3 API into a staging dir.

### Third copy: crown jewels to Infomaniak

The NAS gives two copies in two places. It does not cover *both* failing — the
NAS dying unnoticed, then something happening at home. The fix is cheap: a
**200 GB Infomaniak Swiss Backup tier at CHF 2.40/month** (CHF 29/year) holding
only the small irreplaceable things — Vaultwarden, Paperless documents, the
Immich database dump, Authelia, sops secrets, personal documents. Same restic,
same encryption, second repo, monthly.

That is a real 3-2-1: three copies, two media, one offsite (two, in fact).

## Encryption

Asked for explicitly, and the answer is that it is not optional — **restic has
no unencrypted repository format.** Every blob is AES-256 encrypted with
Poly1305-AES authentication before it leaves the host; the repository key is
derived from the password via scrypt. Infomaniak, and anyone holding the NAS,
sees only ciphertext plus coarse structure (how many blobs, roughly how large).
This is identical for the NAS and the cloud tier — one mechanism, both targets.

Full-disk encryption on the NAS (LUKS or ZFS native) is **not recommended on
top**: the contents are already encrypted, the only extra gain is hiding
snapshot metadata, and the cost is real — a headless box at someone else's
address either needs a passphrase typed at every boot (it will eventually reboot
when you are not there) or a keyfile on the boot disk, which defeats the theft
protection it was added for. The design above already keeps the password off the
NAS, which is the protection that actually matters.

**The password is the whole ballgame.** Lose it and the repository is
unrecoverable by design. It cannot live in Vaultwarden — Vaultwarden is *inside*
the backup, so that is a circular dependency that fails exactly when needed.
Printed copy plus the Mac's password manager, both off every machine being
backed up.

## Cost

Drives are 2× 12 TB ≈ CHF 300. The box is CHF 100 (used mini-tower) to CHF 360
(prebuilt NAS) — see *Hardware*; the CHF 200 originally assumed sits between the
two. Electricity at CHF 0.32/kWh:

| | capex | power/yr | 3-year | 5-year |
|---|---|---|---|---|
| **NAS, used mini-tower** (~20 W avg) | ~400 | ~56 | **~570** | **~680** |
| **NAS, prebuilt N100 4-bay** (~12–15 W avg) | ~660 | ~38 | **~775** | **~850** |
| NAS, older MicroServer-class (~35 W) | ~500 | ~98 | ~795 | ~990 |
| Cloud only, 2.5 TB Swiss Backup | 0 | 120–250 | 360–760 | 600–1 260 |
| **Recommended: NAS + 200 GB cloud tier** | 400–660 | ~67–85 | **~640–860** | **~780–950** |

Break-even against cloud-only is **~2 years** for the used-tower build and
**~3.5 years** for the prebuilt, at the midpoint of the cloud range — but that
framing undersells it, because the two sides do not buy the same thing. The
hardware buys **12 TB usable**, about five times the 2.5 TB the cloud figure is
priced for, and it keeps being yours afterwards. The cloud bill never stops and
grows with the data.

The power line matters more than it looks: an old MicroServer-class box burns
CHF 98/year and eats the whole advantage — it is the one thing here where being
cheap up front actually loses money.

### Capacity

2× 12 TB as a **ZFS mirror = 12 TB usable**, surviving one disk failure. Mirror
rather than stripe: 24 TB is more space than this will ever need, and a disk
failure on a striped backup target means re-seeding 2.5 TB from scratch. ZFS
also scrubs, which catches bit rot in data that sits unread for years — exactly
the failure mode a backup archive has.

With 12 TB usable against a 2.5 TB need, **the nixflix media stops being worth
excluding**. Adding it costs nothing but disk that is already bought, and turns
a re-download measured in weeks into a restore measured in hours. Recommendation:
exclude it from the initial seed to keep that seed short, then add it as a third
`media` set once everything else is verified.

## Hardware

Surveyed 2026-09-12, Swiss retail. **First: the CPU does not matter here.** This
box accepts restic pushes over a WAN link once a week. An N100 is already far
past what that needs — every franc spent moving up to an i3-N305 buys nothing.
Optimise for bays, idle watts, and how little the thing will need hands on it at
an address that is not yours.

| Option | CPU | Bays | ~CHF | Verdict |
|---|---|---|---|---|
| **TerraMaster F4-424** | N95/N100 | 4× 3.5" | **~357** | 4 bays, AMI Aptio UEFI, documented third-party-OS path |
| **UGREEN NASync DXP2800** | N100 | 2× 3.5" + 2× M.2 | **~312** | a published NixOS config exists for its DXP4800 sibling |
| Topton N18 / CWWK M8 board | N150 / i3-N305 | 6–8 SATA | ~115–165 board, ~270–320 built | the literal "SoC mainboard" ask |
| Used OptiPlex / ProDesk **mini-tower** | i3/i5 8–9th gen | 2–4 SATA | ~80–150 | cheapest, zero hardware quirks |
| ~~ODROID-H4+~~ | N97 | 4× SATA | — | **ruled out — production suspended on Intel supply, still out of stock May 2026** |
| ~~TerraMaster F4-424 **Pro**~~ | i3-N305 | 4 | ~768 | paying for CPU this workload cannot use |
| ~~Synology~~ | — | — | — | DSM lock-in and the drive allowlist |

**The prebuilts cost more than the CHF 200 budgeted** — CHF 310–360 rather than
200, so the total lands near CHF 620–660 instead of 500. What the extra buys is
a case, PSU, backplane, and fans that already fit the drives.

**The deciding practical risk is fan control, not performance.** On both
prebuilts the fans are driven by an embedded controller their stock OS talks to;
under a third-party Linux you get community out-of-tree code or nothing. Fans
stuck at 100 % means a noisy box your host eventually unplugs; fans stuck at 0 %
means cooked drives. Known state:

- **TerraMaster F4-424** — IT8613E chipset, community PID fan-control script
  (Nikotine1 / rcarmo forks of the Xpenology one), tested on the 424 Pro/Max
  under Proxmox. Works, but it is a script to package and keep alive.
- **UGREEN DXP** — needs the out-of-tree `led-ugreen` module for the front LEDs
  and a separate DKMS fan driver. There is a full public NixOS config for the
  DXP4800 Plus (`daskladas/nasdots`, plus a NixOS Discourse write-up) covering
  disko, smartmontools and `hdparm` spindown — the best starting point of
  anything surveyed, though it uses mdadm + btrfs rather than ZFS.
- **Used mini-tower** — standard PWM off the Super I/O, driven by in-tree
  `nct6775` + `fancontrol`. Nothing to package. For a box that must never need
  a visit, this is a genuine advantage, and it is the reason the boring option
  is still on the list.

Other notes:

- On a DIY board, **check the SATA controller**: ASM1166 or JMB585 are fine
  under Linux; a JMB575 *port multiplier* is not, and behaves badly under ZFS.
- **Do not count on ECC.** Intel lists the N100 without it, and In-Band ECC is
  inconsistently exposed in this class. ZFS checksums still catch corruption on
  disk, and this is a backup target — the exposure is bounded.
- **Avoid USB dual-bay enclosures** for a ZFS mirror; a USB reset can fault the
  pool. If USB is unavoidable, pick an ASM1352R bridge and use mdraid.
- **Avoid HP MicroServer Gen8 class.** Four bays and cheap, but ~35 W idle is
  CHF 98/year — it costs more over three years than it saves.

**Pick:** the F4-424 at ~CHF 357 if four bays and a documented conversion are
worth CHF 250 over a used tower; the used mini-tower at ~CHF 100 if holding the
CHF 500 total matters more, accepting a louder box and ~10 W more idle draw.
Either way it runs NixOS, is declared in this repo, and joins the tailnet like
every other host — no port forwarding at the second location.

## Steps

1. **Check the second location's connectivity first** — this is a prerequisite,
   not a detail. The NAS must reach the tailnet *directly*, not via DERP. There
   is a known open item where Sunrise/Yallo's symmetric CGNAT forces
   `tailscale ping 201-mono` through `via DERP(headscale)` at ~800 ms
   (`plans/tailnet-p2p.md`, and the pending UniFi UDP 41641 forward). If the
   second location is on mobile or CGNAT internet, weekly incrementals will
   crawl. Verify with `tailscale ping` from there before buying anything.
2. **Measure the split** — `ssh 203-media 'du -shx /mnt/solo-sata/* /mnt/Shares/*'`.
   Confirms the seed size and whether anything large hides in the private share
   (the Jellyfin `clips` library lives under `/mnt/Shares`).
3. **Buy and build the NAS.** NixOS, ZFS mirror on the two 12 TB drives at
   `/srv/restic`, joined to the tailnet, new host entry in `lib/registry.nix`.
   `services.restic.server` with `appendOnly = true`, `privateRepos` per host,
   listening on the tailnet interface only. Monthly ZFS scrub. **Sort fan
   control before the box leaves the house** (see *Hardware*) — one that howls
   gets unplugged, one that never spins cooks the drives, and neither failure is
   visible from here.
4. **Secrets** — `restic-password` (long and random),
   `restic-rest-user`/`-password` per host, and later the Infomaniak S3 keys,
   into `modules/homelab/global-secrets/secret.yaml` via `sops set`; compose
   `sops.templates."restic.env"` for restic's `environmentFile`.
5. **Escrow the password on paper.** See *Encryption*. Not optional.
6. **Client module** `modules/backup.nix` → `flake.nixosModules.homelab-backup`,
   self-gated on a `backup-client` tag, added to `alwaysImport` in
   `modules/builder.nix`. Declares the per-host `critical` / `bulk` sets and maps
   them onto `services.restic.backups.*`. Tag 201-mono, 203-media, 204-agent.
7. **Seed over the LAN, then move the box.** This is the big practical win over
   any cloud target: keep the NAS at home for the first pass and 2.5 TB takes
   **10–14 hours on gigabit**, not the 5–12 days it would take over a
   residential uplink. Only after the seed verifies does it go to the second
   location, where it only ever has to carry weekly deltas.
8. **Retention & prune.** `critical`: `--keep-daily 14 --keep-weekly 8
   --keep-monthly 12`. `bulk`: `--keep-weekly 5 --keep-monthly 6 --keep-yearly 2`.
   Prune runs **from the Mac over sftp** (append-only blocks it from the hosts),
   monthly, staggered so the two sets never overlap.
9. **Monitoring.** `services.prometheus.exporters.restic` (port 9753, free in
   this repo's allocation — checked) on 201, pointed at the rest-server repo:
   reads are permitted in append-only mode, and it exports snapshot ages
   directly. Alert on:
   - failure: `node_systemd_unit_state{name=~"restic-backups-.*",state="failed"} == 1`
   - staleness — the worse failure, a timer that quietly stopped firing:
     `time() - node_systemd_timer_last_trigger_seconds{name="restic-backups-bulk.timer"} > 9*24*3600`
   - the NAS itself being unreachable or its pool degraded

   Senders already run Alloy with node_exporter's `systemd` and `textfile`
   collectors (`modules/observability.nix:586`), so no new plumbing. Add the
   rules to the set pushed by `mimir-rules-sync` — and scope the sync with
   `--namespaces=`, or it deletes every other rule group in the tenant.
10. **Add the 200 GB Infomaniak tier** for the crown jewels (see *Approach*),
    monthly, second repo, same password handling.
11. **Verify + drill.** Monthly `restic check --read-data-subset=10%` from the
    Mac. Quarterly, restore a real file and diff it. A backup that has never
    been restored is a hypothesis, not a backup.
12. **Then add the media set** (`/mnt/solo-sata/nixflix`) now that the disk is
    there and everything else is proven. Mark this plan `done`.

## Open decisions

- **Does the media get backed up too?** Recommending yes, in phase 12 — 12 TB
  usable against a 2.5 TB need makes the exclusion pointless, and it converts a
  multi-week re-download into an afternoon. Excluded from the *initial seed*
  only, to keep that seed short.
- **Who pays the electricity at the second location, and do they know?** ~40 W
  while running, ~12–15 W the rest of the week; call it CHF 40/year. Worth
  settling up front rather than discovering it as a grievance later.
- **ZFS mirror vs mdraid.** Recommending ZFS for scrub and checksumming. mdraid
  only if the drives end up USB-attached, where ZFS is fragile.
- **Image-level backups, later.** PBS 4.2 (April 2026) can back up whole VMs
  incrementally to S3 or local storage, which would also cover the Proxmox host
  — the one machine in the fleet not declared in this repo. Not needed for the
  data, and it cannot exclude the media disk (see *Finding*). Revisit only if
  click-to-restore-a-VM turns out to be missed. The cheap 90 % of it: have
  `critical` also pick up `/etc/pve` (VM configs, a few KB of text). Configs
  plus this flake plus restored data is a complete rebuild recipe with no OS
  images stored at all.

## Risks / rollout

- **A backup target at someone else's address can quietly stop existing.** It
  gets unplugged, moved, put behind a new router, or the household changes ISP.
  This is the main new failure mode the NAS introduces over cloud, and it is
  exactly what step 9's staleness alert is for. Do not skip it.
- **The second location's uplink.** Weekly deltas are small, but the first
  post-move `check --read-data` pulls real volume. See step 1.
- **Silent DB corruption** — backups run green for a year, then the Postgres
  restore fails. Mitigated by dumping rather than copying, and caught only by
  step 11's drill.
- **Losing the restic password loses everything.** Step 5 is not optional.
- **Garage stop/start window** briefly interrupts S3 during the weekly run.
  Seconds, at 02:00 Sunday; acceptable, or take the rclone route.
- **Rollout** is per-host and additive: NAS first, then `deploy 204-agent`
  (smallest, lowest stakes), then `deploy 203-media`, then `deploy 201-mono`
  last since it fronts everything. Backing out is deleting the module and the
  timers; nothing else depends on it.
