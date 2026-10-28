# Consolidate security work and roll out SABnzbd

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Put the six October security workstreams and unrelated changes in the shared
checkout onto local main, then deploy the SABnzbd fixes on 203. The user explicitly
requested this integration and rollout on 2026-10-28. Do not push, reboot hosts,
or activate the deferred Immich/oCIS migrations.

## Approach

Merge the already deployed ingress/server rollout and the shared security branch
into the clean existing main worktree. Include the current z14 Bluetooth change
as its own commit; preserve existing desktop changes and the Teams revert.
Restore the existing native Immich 3.0.2 package pin before deploying 203 so the
held schema migration cannot start. Keep the deployed Jellyfin 12.2, Headscale
0.29.6, Traefik 3.7.15 and Immich/oCIS ingress restrictions.

## Steps

- [x] Commit the shared checkout's unrelated Bluetooth change without discarding work.
- [x] Integrate security branches and unrelated shared-checkout commits into main.
- [x] Keep Immich at 3.0.2 and verify syntax, lock preservation and merged source.
- [x] Build/dry-activate 203 through native deploy and review all service changes.
- [x] Quiesce SABnzbd and take/verify a protected consistent state backup.
- [ ] Activate 203 over a non-tailnet management path and verify SABnzbd 5.1.3,
      preserved state, API denials and existing client integrations where possible.
- [ ] Record deployed revision, remaining acceptance checks and clean main state.

## Risks / rollout

Deploying a NixOS generation may update services besides SABnzbd; review the dry
activation before proceeding. Any unrelated application migration that needs its
own backup must remain held. SABnzbd rollback requires matching trusted saved
state and the old generation and reintroduces the old archive/API vulnerabilities.
Keep Jellyfin's existing migration backups; never boot its old binary against the
12.2 database. Use a management path via 201 to avoid the target's Tailscale
restart interrupting deploy-rs. No custom glue, package override or new unit.

## Integration evidence

The deployed ingress rollout and shared security branch, including the unrelated
desktop and z14 Bluetooth changes, are merged on local main. The restored Immich
input is byte-for-byte the old native package pin; all existing rollout lock nodes
and input references, including Android's paired pins, are unchanged. Seerr stays
on stable 3.2.0 for this rollout; its reviewed unstable 3.5.0 upgrade remains deferred.

The first native deploy dry run stopped before building/activation because the
unstable SABnzbd package's mandatory unrar dependency was disallowed by that
package set's default license policy. Use the repository's existing scoped-import
pattern, permitting only unrar in this SABnzbd package set. This changes no native
derivation, adds no overlay and does not blanket-enable unfree packages.

## Rollout evidence

Native dry activation of main commit `f0ef1d5` completed after building/copying the
203 closure. Target system: `/nix/store/rimjgxqsc93imxgykcminwq4kyn689gg-nixos-system-203-media-26.05.20261025.1f607aa`.
Generated commands retain the exact running Immich server/ML 3.0.2 paths, Seerr
3.2.0 and Jellyfin 12.2; SABnzbd selects native 5.1.3. No Immich/PostgreSQL unit
restart is proposed. Dry activation restarts media services, Alloy, Nix and
Tailscale, so activation uses LAN SSH through 201, independent of 203's tunnel.

Pre-upgrade SABnzbd: 5.1.2, idle/unpaused, zero queued/incomplete jobs, five
categories; history SQLite integrity passes with 53 rows. Existing Sonarr,
Radarr, Lidarr and Prowlarr versions are 4.0.19.2979, 6.4.4.10685, 3.1.0.4875
and 2.6.5.5623 respectively. Existing update-check warnings/errors are not new
download-client failures. No failed systemd units before the window.

SABnzbd, Seerr and Sonarr were stopped for a consistent protected archive:
`/mnt/solo-sata/backups/sabnzbd-security-20261028-pre-5.1.3/pre-5.1.3.tar`.
It includes `/var/lib/sabnzbd`, the complete Usenet tree (including queue/admin,
history, watch/RSS, incomplete/complete data), and `/var/lib/nixflix/{seerr,sonarr}`.
Ownership, permissions, ACLs and xattrs are retained; tar comparison passed while
services were stopped. Size 1.2 GiB; SHA-256
`b630b96c52a402484baac5031b7aada438b3245ceb5ff550b5e625b743b5dd67`.
Previous generation/profile paths are retained beside it. This is a verified
on-disk archive, not an off-host copy or a full restore rehearsal.
