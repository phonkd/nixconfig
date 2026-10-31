# Observability on Backblaze B2

**Repo:** nixconfig  **Status:** in-progress — Mimir migrated and verified; Loki S3 period scheduled for 2026-11-01 00:00 UTC (01:00 Europe/Zurich)

## Goal

Move Loki's new log chunks/indexes and Mimir's blocks, rules and Alertmanager
configuration to Backblaze B2's S3-compatible API. Keep ingestion working until
bucket access and the data migration are verified.

## Approach

- Storage is enabled with SOPS credentials; Mimir uses B2 immediately and Loki
  selects S3 for log timestamps from 2026-11-01 00:00 UTC onward.
- Use two private buckets: `phonkd-loki` and `phonkd-mimir`. Mimir's stores use
  distinct `storage_prefix` values: `blocks`, `ruler`, and `alertmanager`.
- Keep Loki's original filesystem schema and append an S3 schema with an explicit
  future UTC date. Old logs remain on disk and queryable; this is not an automatic
  migration of historical Loki objects.
- Copy Mimir's three filesystem object stores before switching. Keep its local
  TSDB/WAL, cache and compactor working directories on disk.
- Inject credentials using a SOPS environment template and native environment
  expansion. No credentials in the Nix store, custom units or migration scripts.

## Steps

- [x] Prepare disabled configuration and migration instructions.
- [x] Parse changed Nix and review native module/upstream configuration fields.
- [x] Commit preparation to local main; no push.
- [x] User supplied encrypted credentials and confirmed both bucket names and endpoint.
- [x] Verified SOPS decryption and authenticated `HeadBucket` for both B2 buckets.
- [x] Validate credentials and bucket list/put/get/delete operations.
- [x] Copy and byte-verify Mimir object stores, deploy S3, and verify historical queries.
- [x] Verify a fresh Mimir block upload and unchanged rule/Alertmanager configuration.
- [x] Deploy Loki's future S3 schema and verify existing log history.
- [ ] After 2026-11-01 00:00 UTC, verify new Loki objects and queries spanning the boundary.

## Open decisions

Confirmed endpoint: `s3.eu-central-003.backblazeb2.com`, region `eu-central-003`.
Confirmed bucket names: `phonkd-loki` and `phonkd-mimir`. Keep existing unlimited
current-object retention for now. Decide a noncurrent-version cleanup period
before production use: B2's S3 deletes create delete markers, so old versions
otherwise continue consuming storage even after compaction.

## Risks / rollout

No S3 activation before provisioning. Loki history still consumes disk; relocating
it later needs a separate migration that preserves its object keys. Mimir has no
dual-read fallback to its old filesystem backend. Preserve local data and take a
backup before cutover. Rollback after S3 receives writes needs reconciliation;
blindly disabling the switch would hide new data.

## Provisioning and cutover runbook

1. In Backblaze Console, verify `phonkd-loki` and `phonkd-mimir` are **private**,
   with Object Lock and expiration of current objects disabled. Both buckets use
   `s3.eu-central-003.backblazeb2.com`. Noncurrent-version cleanup is a separate
   lifecycle policy; do not expire current metric/log objects behind the services.
2. Use a standard Backblaze application key with list/read/write/delete access
   to both buckets and no prefix restriction. The S3 API does not accept the
   master application key. In `modules/homelab/global-secrets/secret.yaml`, the
   supplied SOPS entries must map as follows:
   `observability-s3-access-key-id` = **keyID**;
   `observability-s3-secret-access-key` = **applicationKey**.
   Never paste keys into Nix or the
   runbook. The conditional SOPS template supplies both existing services via a
   root-readable environment file and restarts them on credential changes.
3. Configure an S3 CLI (for example rclone) with those credentials outside the
   repository. Use TLS, endpoint `https://s3.eu-central-003.backblazeb2.com`, region
   `eu-central-003`. Test list/put/get/delete in each
   bucket using a disposable object, then remove it. Keep credentials out of
   shell arguments/history. Run `mimirtool bucket-validation --help` and use its
   bucket checks against the new Mimir bucket before copying production data.
4. Before the maintenance window, record representative historical Loki and
   Mimir queries and results, rule groups, and Alertmanager configuration in a
   protected backup. Check local disk capacity, dataset size, and Alloy remote
   write WAL/retry capacity; the metric senders must tolerate the copy downtime.
   Complete the build/preflight before stopping Mimir where possible.
5. Pre-copy blocks while Mimir runs to reduce downtime. Build and dry-activate the
   new configuration before the final sync. Stop `mimir-rules-sync.service`, then
   `mimir.service` on observability. Keep
   Mimir stopped until the copy is verified and the S3 configuration is activated.
   Back up its full state directory including TSDB/WAL and Alertmanager local
   state. DynamicUser may place the real directory under `/var/lib/private/mimir`;
   resolve the `/var/lib/mimir` symlink and access it as root.
6. Copy the **contents** of each following directory to the corresponding empty
   prefix in the Mimir bucket, preserving every relative key (including tenant prefixes,
   metadata and deletion markers):

   | Local object store | S3 destination |
   | --- | --- |
   | `/var/lib/mimir/blocks/` | `s3://phonkd-mimir/blocks/` |
   | `/var/lib/mimir/ruler-storage/` | `s3://phonkd-mimir/ruler/` |
   | `/var/lib/mimir/alertmanager-storage/` | `s3://phonkd-mimir/alertmanager/` |

   Use native `rclone sync` to reconcile the pre-copy with the stopped source,
   followed by `rclone check --download` for each pair
   while Mimir remains stopped. Include each configured prefix exactly once;
   preserve the original keys beneath it. Set `storage_prefix` without a slash;
   Mimir adds the path separator. Empty source stores are fine; investigate missing
   directories rather than silently assuming there is no data. Do not upload
   `/var/lib/mimir/tsdb`, `tsdb-sync` or `compactor`; preserve them on the VM.
7. Set `objectStorage.lokiFrom` to an explicit future date (`YYYY-MM-DD`, midnight
   **UTC**), allowing enough time to deploy before that midnight, and set
   `objectStorage.enable = true`. The assertion checks format/order only, not
   whether the date is still in the future. Leave the original 2024 filesystem
   schema unchanged. Once active, never move or remove either schema entry.
8. Parse the Nix, commit to local `main`, then run `deploy observability`.
   Verify SOPS rendered the environment file without printing its contents.
   Check service status, `/ready` on ports 3100 and 9009, and journals for S3
   authentication, TLS or config errors. Confirm `mimir-rules-sync` completed.
9. Repeat historical queries, check current metrics, rules, notification policies
   and receivers, and confirm new Mimir blocks appear after the next upload.
   After the scheduled UTC boundary, confirm fresh Loki chunks/indexes appear
   in S3 and queries spanning the boundary return both old and new logs.
   Late-arriving logs timestamped before the boundary still use the local store.
10. Keep all local state until validation is complete. Old Loki history is still
    required indefinitely with current unlimited retention. Mimir's old object
    stores can only be archived/removed after confirming the copy and backups;
    its TSDB/WAL/cache/working directories remain required. Mark this plan done
    only after the real cutover and historical/current query checks pass.

## Rollback

Before S3 receives any writes, revert the switch, commit and deploy the filesystem
configuration; untouched local stores allow recovery. After S3 writes begin,
preserve both sets of data and reconcile them before changing the backend. For
Loki, keep the S3 schema period and access to its bucket: removing it makes logs
from that period unreadable. Prefer fixing S3 connectivity/credentials in place.

## Validation and references

2026-10-31 rollout evidence:

- `nix-instantiate --parse` and `git diff --check` passed. The pinned Loki binary
  accepted the generated config with `-verify-config`; Mimir parsed its generated
  config with `-modules`. Both tests used dummy credential values.
- Both buckets were empty/private, with no lifecycle configuration. Disposable
  put/get/byte-compare/delete checks passed in both. Mimir's native bucket
  validator passed ten-object create/overwrite/list/read/delete checks. Test
  versions and delete markers were subsequently removed.
- `deploy observability --dry-activate --ssh-opts '-F /dev/null -o BatchMode=yes
  -o ConnectTimeout=10'` built and staged the configuration before downtime.
  The same command without `--dry-activate` then activated it successfully with
  deploy-rs confirmation. Deployment commit: `09aa246`.
- Blocks were pre-copied while Mimir ran. Mimir was then stopped, local state
  backed up, and all three prefixes reconciled using `rclone sync`. Download
  verification found **zero differences**: 348 block files (8.55 GiB), 6 ruler
  files and 2 Alertmanager files. Mimir was paused for final sync, verification
  and activation only.
- Protected recovery artifacts are on observability under
  `/var/lib/observability-migration-20261031/`: the previous system path, API
  configuration snapshots, before/after query results, and a 106 MiB compressed
  backup of local Mimir state. Blocks and disposable caches are excluded from
  that archive; the original filesystem object stores remain untouched in place.
- Both historical metric checks returned the same 23 `up` series; the fixed
  historical log query returned the same 21,676 lines. Rule and Alertmanager
  API configurations matched byte-for-byte. Current metric queries also work.
- Loki/Mimir readiness returned HTTP 200; Grafana and `mimir-rules-sync` are
  active, with the rule synchronization unit reporting success.
- Mimir's native `/ingester/flush?wait=true` uploaded a fresh block to B2:
  `cortex_ingester_shipper_uploads_total = 1`, upload failures = 0. The new
  block objects were also confirmed through the B2 S3 API.
- The temporary root-only rclone credential file under `/run` was removed;
  services use the SOPS-rendered environment file (mode 0400, root-owned).
- Loki's S3 period is deployed but its scheduled boundary has not arrived.
  New S3 log objects and queries across that boundary remain to be verified.

Separate existing issue: Mimir was already hitting its default 150,000-series
tenant limit before activation (confirmed in the old process's logs). This
caused rejected samples; the initial storage migration did not change that limit.
After the verification flush, the head held 138,689 series. Investigate
cardinality/capacity separately rather than treating this as an S3 failure.
The user-requested follow-up sets `limits.max_global_series_per_user = 400000`.

- [Backblaze endpoint and credential mapping](https://www.backblaze.com/docs/en/cloud-storage-get-started-with-a-backblaze-integration)
- [Backblaze S3 delete/version semantics](https://www.backblaze.com/apidocs/s3-delete-object)
- [Backblaze lifecycle configuration](https://www.backblaze.com/apidocs/s3-put-lifecycle-configuration)
- [Loki schema changes and UTC cutover](https://grafana.com/docs/loki/latest/operations/storage/schema/)
- [Mimir object storage and bucket separation](https://grafana.com/docs/mimir/latest/configure/configure-object-storage-backend/)
- [Mimir 3.0 configuration fields](https://archive.grafana.com/docs/mimir/v3.0.x/configure/configuration-parameters/)
