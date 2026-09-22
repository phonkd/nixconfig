# Export drop: manual export in, automatic index out (S3 as the inbox)

**Repo(s):** `nixconfig` (bucket, secrets, timers) + `slop-trove` (fetch stage,
new source) + whatever the music tool ends up being (see
`plans/music-taste-recommender.md`).   **Status:** draft

## Goal

Every personal-data export in this house arrives the same way: a human goes to a
web UI, clicks "request my data", waits, downloads a zip. Today the *second*
half — getting that zip onto the right host and re-running the indexer — is also
manual: `scp` to `/var/lib/slop-trove/exports/discord`, then
`systemctl start slop-trove-ingest-discord`. That step gets forgotten, so the
index quietly rots.

Keep the **export manual** (it has to be — every provider gates it behind a
login and a human click, and that's fine), and make **everything after the drop
automatic**. One shared convention: *put the zip in S3, the index catches up on
its own.*

The export is the only human action. Nothing downstream should need one.

## Grounding — what exists today

- **S3 is Garage on 201-mono** (`modules/homelab/apps/s3-garage.nix`): S3 API on
  `127.0.0.1:3900`, reachable from other hosts only via traefik at
  `https://api.s3.w.phonkd.net` (ipfilter=internal, region `us-east-1`,
  virtual-hosted style under `.api.s3.w.phonkd.net`). Web buckets serve at
  `<bucket>.s3.w.phonkd.net`.
- **slop-trove on 204-agent** (`modules/hosts/204-agent.nix`) already has two
  sources, `discord` and `claude`, each an **oneshot** unit
  (`slop-trove-ingest-<name>`) that runs `slop-trove ingest --source <n> --path
  <dir>` against a local directory. No timers, no fetching — the path is assumed
  to be populated by hand.
- The ingest layer is content-hash keyed (`content_hash`, `ON CONFLICT DO
  NOTHING`), so **re-running over a superset export is already safe** — a fresh
  export that contains everything plus the last month re-adds only the new
  records. That's the property this whole design leans on.

## Approach

### The bucket is an append-only inbox, not a sync target

One private bucket, `exports`, with one prefix per source:

```
exports/
  discord/discord-2026-09-14.zip
  claude/claude-2026-09-20.zip
  spotify/spotify-extended-2026-10-02.zip
  google-takeout/...
```

Rules that make the "newest" question answerable without a database:

- **Never overwrite.** Every drop is a new key. The zip's own name is fine;
  the object's `LastModified` is the ordering key, not the filename (filenames
  from providers are inconsistent — `my_spotify_data.zip` twice in a row).
- **Newest wins, full reindex.** Each export from these providers is cumulative,
  so the newest object *is* the complete state. No stitching, no deltas. This
  is why the design can be this dumb.
- **Keep the old ones.** Storage is cheap and an old export is the only backup
  of data the provider may have since deleted. Lifecycle-expire after N (say 5)
  versions per prefix if it ever matters; don't bother on day one.

### The fetch stage belongs to the indexer, not to a sidecar

Resist the urge to write a generic "s3 → disk" syncer unit. Each indexer already
knows how to unpack its own source; give it one more verb:

    <tool> fetch --source discord      # newest object in exports/discord/ → work dir
    <tool> ingest --source discord --path <work dir>

`fetch` is: list the prefix, take max by `LastModified`, compare its **ETag**
against a marker file (`<statedir>/fetch/<source>.etag`), and if unchanged
**exit 0 having done nothing**. If changed: download to a temp path, verify,
extract, atomically swap into the source path, write the new marker. So the
timer can fire daily and cost one `ListObjectsV2` call on the 364 days nothing
was exported.

An exit code distinguishes the two outcomes so the unit that follows can skip
work (`fetch` exits 0 for "new data staged", 75/`EX_TEMPFAIL`-style or a marker
file for "nothing new" — pick one and document it).

### Wire it as fetch → ingest → timer

Per source, three units:

- `<tool>-fetch-<source>.service` — oneshot, `fetch`.
- `<tool>-ingest-<source>.service` — oneshot, `ingest` (already exists for
  slop-trove). Gains `After=`/`Requires=` on the fetch unit.
- `<tool>-index-<source>.timer` → `.target` or a wrapper unit pulling both,
  `OnCalendar=daily`, `Persistent=true`, `RandomizedDelaySec=1h`.

`Persistent=true` matters: 204 is a VM that gets rebooted by deploys, and a
missed daily run should catch up rather than wait for tomorrow.

### Credentials

One Garage access key scoped to the `exports` bucket, **read-only**. The
indexer hosts never need write access — writes come from the Mac (or from
whatever browser downloaded the zip). Key + secret into sops as
`exports-s3-access-key` / `exports-s3-secret-key`, mounted for the service user,
read via `AWS_*` env or a `~/.aws/credentials`-style file (`EnvironmentFile=` on
the units, matching how the repo does secrets elsewhere).

Endpoint config: `https://api.s3.w.phonkd.net`, `us-east-1`, path-style off
(Garage's `root_domain` is set for virtual-hosted style). 204 reaches 201 fine;
203 too.

### The upload side stays a one-liner, deliberately

A tiny wrapper on the Mac — `~/.claude/bin/drop-export <source> <file>` or a
`nixconfig` package — that does `aws s3 cp <file>
s3://exports/<source>/<source>-$(date +%F).zip` with the write key. That is the
whole human workflow: download the zip, run one command. Anything more
ambitious (a watched `~/Downloads` folder, browser automation against provider
export pages) is explicitly out of scope — the providers gate exports behind
login + 2FA + email confirmation, and automating that is a maintenance treadmill
for a job that happens four times a year.

## Steps

1. **`nixconfig`** — create the `exports` bucket in Garage with two keys (rw for
   the Mac, ro for indexer hosts); sops entries for both. Verify with
   `aws --endpoint-url https://api.s3.w.phonkd.net s3 ls s3://exports/`.
2. **`nixconfig`** — `drop-export` wrapper script packaged for the Mac; drop the
   existing Discord + Claude zips through it so the prefixes are populated.
3. **`slop-trove`** — `fetch` subcommand: S3 list/newest/ETag-marker/extract,
   with a `--dry-run`. Config: endpoint, bucket, prefix per source.
4. **`slop-trove`** — nixos-module: `fetch` units + `index` timers per enabled
   source; new options `s3.endpoint`, `s3.bucket`, `sources.<n>.prefix`.
5. **`nixconfig`** — wire the new options on 204-agent, `deploy 204`, confirm a
   manual `systemctl start slop-trove-index-claude.service` pulls the newest zip
   and adds only new records.
6. **`slop-trove`** — add `spotify` as a third source *if* the music tool ends up
   living inside slop-trove (see the open decision in
   `plans/music-taste-recommender.md`); otherwise the music tool implements the
   same `fetch` contract against `exports/spotify/`.

Steps 1–5 are independently useful and fix a real rot problem today; step 6 is
the hand-off to the music plan.

## Open decisions

- **One `fetch` implementation, or one per tool?** Recommendation: copy the ~80
  lines into each tool rather than build a shared library — the contract (newest
  object, ETag marker, atomic swap) is the reusable part, and a shared package
  across two Python repos buys a flake input and a version skew for very little.
  Revisit at the third consumer.
- **Timer cadence.** Daily is proposed. Exports arrive maybe monthly, so daily
  is nearly free (one list call) and keeps latency low. Alternative: weekly.
- **Trigger on upload instead of polling?** Garage does not do S3 event
  notifications, so this would mean a bucket-watching sidecar. Not worth it;
  polling a prefix is the cheap, boring answer.
- **Keep old exports forever?** Proposed yes (see above). Say so if you'd rather
  cap it.

## Risks / rollout

- **A truncated upload gets indexed.** Mitigate in `fetch`: only accept an
  object whose zip opens cleanly (`zipfile.testzip()`) before swapping it in;
  leave the old extraction in place and fail the unit otherwise.
- **Provider changes the export layout.** The ingest parsers are the fragile
  part, not the fetch. A failed parse should leave the previous index intact —
  ingest already being idempotent-by-hash means a bad run adds nothing rather
  than corrupting.
- **Secret sprawl.** Two more keys. Scoped to one bucket, read-only where it can
  be, which is the whole reason for splitting rw/ro.
- **Rollout:** `deploy 204` (and `deploy 201` for the bucket/key). Back out by
  disabling the timers — the manual `ingest` path is untouched throughout.

Co-designed alongside `plans/music-taste-recommender.md`, which is the first
*new* consumer of this convention.
