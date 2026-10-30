# Observability on Hetzner Object Storage

**Repo:** nixconfig  **Status:** in-progress — preparation; purchase and cutover pending

## Goal

Move Loki's new log chunks/indexes and Mimir's blocks, rules and Alertmanager
configuration to Hetzner S3. Keep ingestion working while the buckets do not exist.

## Approach

- Keep the storage switch disabled until buckets and SOPS credentials exist.
- Use four private buckets: Loki, Mimir blocks, Mimir ruler, Mimir Alertmanager.
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
- [ ] Purchase/create buckets and supply credentials.
- [ ] Copy Mimir object stores, activate S3 and verify old and new data.

## Open decisions

Provisional location: Helsinki (`hel1`); choose the VM's location when purchasing.
Bucket names below are suggestions and must be available. Keep existing unlimited
retention for now; setting a retention policy is a separate decision.

## Risks / rollout

No S3 activation before provisioning. Loki history still consumes disk; relocating
it later needs a separate migration that preserves its object keys. Mimir has no
dual-read fallback to its old filesystem backend. Preserve local data and take a
backup before cutover. Rollback after S3 receives writes needs reconciliation;
blindly disabling the switch would hide new data.

## Provisioning and cutover runbook

1. In Hetzner Console, create four **private** buckets, with Object Lock and
   automatic expiration disabled. Proposed names in `modules/observability.nix`:
   `phonkd-loki`, `phonkd-mimir-blocks`, `phonkd-mimir-ruler`,
   `phonkd-mimir-alertmanager`. Use the same location for all four and update
   `objectStorage.region` and names if necessary. No buckets have been purchased.
2. Generate S3 credentials for that project. Using the SOPS editor, add
   `observability-s3-access-key-id` and `observability-s3-secret-access-key` to
   `modules/homelab/global-secrets/secret.yaml`. Never paste keys into Nix or the
   runbook. The conditional SOPS template supplies both existing services via a
   root-readable environment file and restarts them on credential changes.
3. Configure an S3 CLI (for example rclone) with those credentials outside the
   repository. Use TLS, endpoint `https://hel1.your-objectstorage.com`, region
   `hel1` (adjust both to the purchased location). Test list/put/get/delete in each
   bucket using a disposable object, then remove it. Keep credentials out of
   shell arguments/history. Run `mimirtool bucket-validation --help` and use its
   bucket checks against the new blocks bucket before copying production data.
4. Before the maintenance window, record representative historical Loki and
   Mimir queries and results, rule groups, and Alertmanager configuration in a
   protected backup. Check local disk capacity, dataset size, and Alloy remote
   write WAL/retry capacity; the metric senders must tolerate the copy downtime.
   Complete the build/preflight before stopping Mimir where possible.
5. Stop `mimir-rules-sync.service`, then `mimir.service` on observability. Keep
   Mimir stopped until the copy is verified and the S3 configuration is activated.
   Back up its full state directory including TSDB/WAL and Alertmanager local
   state. DynamicUser may place the real directory under `/var/lib/private/mimir`;
   resolve the `/var/lib/mimir` symlink and access it as root.
6. Copy the **contents** of each following directory to the corresponding empty
   bucket root, preserving every relative key (including tenant prefixes,
   metadata and deletion markers):

   | Local object store | Bucket |
   | --- | --- |
   | `/var/lib/mimir/blocks/` | `phonkd-mimir-blocks` |
   | `/var/lib/mimir/ruler-storage/` | `phonkd-mimir-ruler` |
   | `/var/lib/mimir/alertmanager-storage/` | `phonkd-mimir-alertmanager` |

   Use native `rclone copy` followed by `rclone check --download` for each pair
   while Mimir remains stopped. Do not introduce an extra `blocks/`, `ruler/` or
   `alertmanager/` prefix. Empty source stores are fine; investigate missing
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

Preparation: `nix-instantiate --parse modules/observability.nix` and
`git diff --check` pass. Native `extraFlags` and systemd environment injection were
checked against pinned nixpkgs modules; S3 fields against Loki 3.7.8 source and
Mimir 3.0.8 CLI help/config reference. No full NixOS evaluation/build was run,
per repository guidance. No bucket access, data copy or live activation is
possible yet; enabled-mode runtime validation is pending provisioning.
The preparation leaves the storage switch disabled and does not require a live
deployment; deploy only during the provisioned cutover above.

- [Hetzner endpoints and billing](https://docs.hetzner.com/storage/object-storage/overview/)
- [Creating private buckets](https://docs.hetzner.com/storage/object-storage/getting-started/creating-a-bucket/)
- [Loki schema changes and UTC cutover](https://grafana.com/docs/loki/latest/operations/storage/schema/)
- [Mimir object storage and bucket separation](https://grafana.com/docs/mimir/latest/configure/configure-object-storage-backend/)
- [Mimir 3.0 configuration fields](https://archive.grafana.com/docs/mimir/v3.0.x/configure/configuration-parameters/)
