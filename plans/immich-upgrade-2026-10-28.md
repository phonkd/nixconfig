# Immich backed-up upgrade

**Repo:** nixconfig   **Status:** in-progress

## Goal
Execute the user-authorized native Immich 3.0.2 → 3.3.5 upgrade on 203-media, with a consistent database/media backup and retained rollback artifacts. Keep tailnet containment.

## Steps
- [x] Inspect live storage, extensions, external libraries, state and deployed configuration; verify target package pairing.
- [ ] Retain old generation/config; stop Immich writers, dump its database and back up media/state to a protected separate disk with sufficient headroom.
- [ ] Verify copied files and restore the dump into an isolated database with compatible extensions; record limits of rehearsal.
- [ ] Select native target server/ML, parse/check and commit only this effort's files on main.
- [ ] Deploy 203 through deploy-rs, supervise migrations and verify versions, health, counts, ML and exposure; record remaining functional checks.

## Risks / rollout
PostgreSQL is shared with AFFiNE: use an Immich-scoped logical backup/restore and leave the shared cluster running. Verify deploy scope against the live generation before activation. Preserve the old closure against GC. A schema migration is not undone by deploy-rs automatic generation rollback: keep Immich runtime-masked during activation and start the new services explicitly after successful activation. If migration fails, stop Immich and restore paired database/media before running old binaries. Native Node/Brotli/Pillow coverage gaps from the earlier review remain; this upgrade is not complete security remediation. Backups contain sensitive data and must not enter git or tool output. Other agents' shared plan edits are excluded from this effort.

## Preflight evidence
- User confirmed the concurrent SABnzbd rollout finished. Rechecked live 203: SABnzbd 5.1.3 active, no failed units, current system `/nix/store/rimjgxqsc93imxgykcminwq4kyn689gg-nixos-system-203-media-26.05.20261025.1f607aa`. No other deployment process remains locally.
- PostgreSQL 17.11, pgvector 0.8.2, VectorChord 1.1.1; Immich DB 169 MB. Media 28,355,792,896 bytes, ML cache about 1.6 GB, empty auxiliary `/var/lib/immich`. No external libraries/assets, out-of-tree original paths or media symlinks.
- Separate disk `/mnt/Shares` has approximately 1.4 TB free; root has 175 GB. Backup destination: `/mnt/Shares/.immich-backups/2026-10-28-pre-3.3.5`, root-only. Same-host separate disk protects this migration but is not an off-host disaster-recovery copy.
- Target remains the reviewed unstable revision `3ec636362e1816bc2f0888fa0fa2c69f1bc9e504`: server 3.3.5 and its matching ML passthru. Root nixpkgs stays `1f607aa79b6356ed45d3cd3c8079c196e79efa2c`; no lock changes. Old Immich input retained solely as a recovery source reference.
- Initial live media copy started before downtime; final synchronization and database dump will happen with Immich writers stopped. Old system/profile have explicit GC roots.
