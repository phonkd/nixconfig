# Jellyfin security migration and declarative deployment

**Repo(s):** nixconfig   **Status:** in-progress

## Goal / authorization

Resolve Jellyfin GHSA-hw73-62vp-9gxf on 203 with a native package, without
interrupting its first database migration. The user explicitly authorized the
migration and subsequently requested deployment to reconcile live and repository
state. This does not authorize merging/deploying the rest of draft security PR
#63 or pushing changes. Preserve the other sessions' checkout and completed
Headscale work; use an isolated worktree and a clean, checked main integration.

## Approach

Select `nixflix.jellyfin.package` from main's **existing** unstable pin
`55bfb4d7437bd4e09ab7cba58a43bd68eb310044`, which already supplies Jellyfin
**12.2** and matching web/FFmpeg dependencies. No lock update, package override,
new unit or migration wrapper. Deploy only 203 using the native deploy CLI;
no separate full-host evaluation/build verification.

The resulting package is
`/nix/store/wpc6ga77p1qabsr21ywlgmn8r6l708xq-jellyfin-12.2`, with web 12.2,
.NET 10.0.12 and FFmpeg 8.1.2-5. This is the existing main-pin build of the same
server release, not the newer security-PR package closure used for the one-off
migration. Its FFmpeg also passed the synthetic H.264 NVENC smoke test on 203.

The live database has already been migrated using native `--mode MigrateSystem`
outside nixflix's normal startup lifecycle. Keep the existing persistent
ExecStart bridge until successful deployment, then verify the generated unit
selects 12.2 before removing the bridge and restarting once. This protects
against accidentally starting 10.11 on the migrated database during rollback.

## Steps

- [x] Match the advisory and pinned Nix backports against upstream source.
- [x] Verify an offline full backup and preconditions; isolate ingress and starts.
- [x] Quarantine incompatible plugins, migrate natively, and verify database.
- [x] Restore service/helpers and public access; verify health and NVENC smoke test.
- [x] Integrate only the Jellyfin native package option and this record on main.
- [ ] Deploy 203; verify generated package and remove only our service bridge.
- [ ] Verify service/helpers, public version/health, and no remaining bridge drift.

## Applicability and first-start risk

The [advisory](https://github.com/jellyfin/jellyfin/security/advisories/GHSA-hw73-62vp-9gxf)
lists `<12.0` as affected. The configured 10.11.11 package's six backports do not
modify `HlsSegmentController`. Its canonical-path directory-prefix check lacks a
separator boundary and accepts siblings like `transcodes-extra`; upstream
`617ebf3` and `95cebff` supply the validation/boundary fixes present in 12.2.
Unrestricted HTTP file read was not demonstrated: routing, extension constraints,
the video playlist prerequisite and filesystem permissions still matter. The
configured route is public, with no outer auth or IP filtering.

Pinned nixflix `b92d266` sets `ExecStartPost` to a 240-attempt readiness helper
and `TimeoutStartSec = 300`; either can stop a first migration. Raising only the
unit timeout does not repair the helper. Retry exhaustion can also falsely
succeed when public info is available but startup configuration remains unready.
The completed native migration did not run under those limits or automatic
restarts. Native migration mode still starts a temporary setup HTTP listener;
ingress was isolated, and migration/error logs were checked in addition to exit.

## Migration completed — 2026-10-26

The full offline archive is on 203:
`/mnt/solo-sata/backups/jellyfin-security-20261026T181500Z/pre-12.2.tar.gz`.
It covers `/var/lib/nixflix/jellyfin`, external metadata `/var/lib/jellyfin`, and
`/var/cache/jellyfin`, preserving ownership/modes/ACLs/xattrs. SHA-256:
`fdbed0d22f61e19b1bd125f7677dba26044d4511f846956f53c4c979215f9319`.
Archive comparison passed; an extracted DB passed integrity checks (4 users,
71 migration-history rows). No case-colliding usernames were found.

Native 12.2 from security PR unstable `3ec6363` was fetched from the binary cache
and run as jellyfin:media. Pre/core/app migrations and optimization completed at
18:30 UTC; integrity/foreign-key checks passed afterwards (4 users, 107 migration
rows). Music-path warnings were checked: the directory is traversable but empty.
No media paths/permissions were changed.

The backup's `quarantined-plugins/` retains Jellyfin Tweaks 4.0.0.0, File
Transformation 2.5.11.0 and Jellyfin Enhanced 12.5.0.0, all targeting 10.11. Their
settings remain live. The existing nixflix managed-plugin package set is empty,
so it does not reinstall these binaries. Compatible replacements remain separate
acceptance work; do not restore the old binaries to 12.2.

The temporary bridge is
`/etc/systemd/system.control/jellyfin.service.d/90-security-package.conf`.
It selects `/nix/store/wrgf29ri1kf6aliwnjb7a9lymljc65q7-jellyfin-12.2`, retained
by `/nix/var/nix/gcroots/jellyfin-security-12.2`. The old 10.11.11 package is
separately GC-rooted for full-state rollback only. Root-only maintenance notes
and migration log are under `/var/lib/jellyfin-security-maintenance/`; notes
are also in the backup directory.

Normal startup, all eight nixflix helper units, public 12.2.0 version/health, and
a synthetic one-frame H.264 NVENC encode passed, with zero restarts. All temporary
ingress/start guards were removed. Credential values were not inspected.

## Deployment preparation

Code commit `620fd0b` was fast-forwarded onto clean local main, preserving the
completed Headscale commits and the shared security checkout. The native deploy
CLI dry activation completed successfully: only `jellyfin.service` restarts and
`dbus-broker.service` reloads; no Tailscale or other application restart. The
built generated unit directly selects the existing-pin 12.2 executable above.
The deployment system output is
`/nix/store/08z1bksb90gvp03csxxkmqwr6vgxys00-nixos-system-203-media-26.05.20261013.a033e66`.
The deployment is pinned to the same reviewed branch/commit rather than allowing
another session's later main commit into this activation.

The first real activation failed when `seerr-jellyfin.service` ran its
authenticated Jellyfin connection test while Jellyfin was restarting; Seerr
reported HTTP 500 `INVALID_URL`. deploy-rs automatically restored the previous
generation. The persistent 12.2 bridge kept Jellyfin healthy throughout recovery;
no old executable opened the migrated DB. Restarting the unchanged Seerr helper
after Jellyfin was ready succeeded, confirming the ordering race. Add native
`after`/`requires = [ "jellyfin.service" ]` dependencies to that existing helper:
Jellyfin's post-start readiness command must finish before the helper's API test.
No wrapper, retry glue, package override or new unit is introduced.

## Rollback / remaining acceptance

Never start 10.11 against the migrated DB. Application rollback requires stopping
Jellyfin/helpers, restoring the complete archived state and external metadata,
then selecting the old package. Keep ingress isolated during recovery; a binary
or generation rollback alone is not a data rollback.

The required post-upgrade full library scan has not been verified (last recorded
completed scan was before migration). Real client login/playback/HDR, Seerr and
dashboard behavior, and compatible plugin replacements remain acceptance checks.
No exploit, full closure audit or universal CVE-free claim is made. Initial
review/migration commits `0d615ee` and `2ea2173` stay on the isolated security
review branch; this main integration intentionally excludes its other PR changes.
