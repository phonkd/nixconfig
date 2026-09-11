# search-launcher — one search box over everything, Enter opens it

**Repo(s):** new repo `search-launcher` (nightly indexer + NixOS module +
Raycast extension) + `slop-trove` (paperless + mail sources) + `nixconfig`
(204 wiring, Garage read key, Samba mount, Mac cask + pull job).
**Status:** draft — written 2026-09-11, reshaped the same day after review
(two stores, nightly batch, local index).

## Goal

A global hotkey on the Mac opens a search box. Typing finds things across the
Samba shares, Garage S3, oCIS, Immich, paperless and mail (`phonkd@phonkd.net`),
and **Enter opens the result where it belongs**:

| Source | Enter | Locator stored in the index |
|---|---|---|
| paperless | browser → `https://paperless.home.phonkd.net/documents/<id>/details` | document id |
| oCIS | browser → `https://ocis.w.phonkd.net/f/<fileid>` (oCIS private link) | oCIS file id |
| Immich | browser → `https://immich.w.phonkd.net/photos/<assetId>` | asset id |
| mail | Apple Mail → `open "message://%3c<Message-ID>%3e"` | `Message-ID` header |
| Samba | Finder → mount `smb://100.64.0.3/<share>` if needed, then `open -R /Volumes/<share>/<path>` | share + path |
| S3 | download → presign on the Mac, `open` the URL (browser saves it) | bucket + key |

Secondary actions: ⌘↵ copy link, ⌥↵ reveal / alternative open. Always-present
fallback rows: "Search Immich for '<q>'" and "Search paperless for '<q>'"
open those apps' own web search. That gets you Immich's CLIP search without an
API call at query time.

**Freshness contract (accepted):** the index is rebuilt nightly. Something
created today isn't findable until tomorrow; something deleted today still
shows up and errors when opened. No incremental sync, no delete tracking.

## Approach

**Two stores, one search box.**

- **slop-trove = information.** It gains `paperless` and `mail` as sources
  (full text, chunked, embedded) so Hermes can answer questions about them.
  Each record also gets `title`, `subtitle` and an `open` locator in
  `metadata`. That costs slop-trove little and makes the next point possible.
- **The file index = files.** A new nightly job crawls Samba, S3, oCIS and
  Immich for **metadata only** (name, path, size, mtime, mime; for Immich:
  date, city, people, albums, filename). File paths don't need embeddings, and
  whole-file text extraction is out of scope for v1.
- **One output.** The same nightly job reads the paperless and mail rows
  (title/subtitle/open only) out of slop-trove's Postgres and writes
  everything into a single **SQLite file with an FTS5 table**. That file is
  the whole search backend.
- **Search runs on the Mac.** A launchd job pulls the SQLite file from 204
  over the tailnet (rsync/ssh, the same path `deploy` uses) once a day and on
  wake. The Raycast extension queries it locally through `@raycast/utils`
  `useSQL`, which uses the system `sqlite3` (FTS5 is built in). Search is
  local-disk fast, works offline, and needs no HTTP service, no auth and no
  traefik route.

Why not one store: slop-trove's shape (chunked text + 1024-dim embeddings,
agent Q&A) is expensive per record and has incremental-upsert semantics. The
file index is cheap, keyword-only and rebuilt from scratch. Forcing hundreds
of thousands of file paths through bge-m3 buys nothing. The launcher merges the
two at build time, so from the Mac it looks like one index anyway.

**Full rebuild each night.** The indexer builds `index.sqlite.new`, then
atomically renames it. A source that fails keeps its rows from yesterday's
file (copy them across) and gets logged, so one broken crawler doesn't empty
the launcher.

Phases, each usable on its own:

- **Phase 1 — Samba + paperless end to end** (paperless read straight from
  its API in phase 1, then switched to slop-trove in phase 3).
- **Phase 2 — S3, oCIS, Immich** in the file index.
- **Phase 3 — slop-trove gets paperless + mail**; the indexer reads them from
  Postgres; mail shows up in the launcher.

## Steps

### Phase 1 — Samba + paperless, end to end
**search-launcher repo (new):**
1. Scaffold: flake with package, NixOS module (`services.search-launcher`:
   sources, output path, `OnCalendar` timer), dev shell. Python, stdlib
   `sqlite3`.
2. Schema: `items(id, source, title, subtitle, path, mtime, size, mime,
   open_json)` + `items_fts` (FTS5 over title, subtitle, path; `unicode61`
   tokenizer with `tokenchars` tuned so `space-wallpaper.png` splits). Build to
   `.new`, rename on success, carry over rows for failed sources.
3. `sources/samba.py`: walk the read-only mount, skip video/audio mimetypes
   and dot-dirs, `open = {kind: smb, host: 100.64.0.3, share, path}`.
4. `sources/paperless.py` (temporary, replaced in step 16): page
   `/api/documents/`, title + correspondent + tags,
   `open = {kind: url, url: …/documents/<id>/details}`.
5. `raycast/`: List view with throttled `useSQL` queries (prefix match
   `term*`, bm25 ranking), per-source icons, open actions for `url` and
   `smb` (check `/Volumes/<share>`, else `open smb://…`, poll for the mount,
   `open -R`), fallback search rows.

**nixconfig:**
6. Flake input + `services.search-launcher` on `204-agent`, nightly timer,
   output under `/var/lib/search-launcher/index.sqlite`.
7. Read-only CIFS mount of the Samba shares on 204 (credentials via sops).
   Public + SemiPublic only; private excluded until asked.
8. Paperless API token in sops for 204.
9. Mac: `raycast` cask in `modules/hosts/types/gui/default.nix`; a launchd
   agent (home-manager) that rsyncs the index from 204 daily and at login/wake.
10. `deploy 204-agent`, Mac rebuild; verify: after one timer run, type a
    share filename → Finder reveals it (starting with the share unmounted);
    type a paperless title → Enter opens the doc.

### Phase 2 — S3, oCIS, Immich
11. `sources/s3.py`: list objects with a **read-only, bucket-scoped** Garage key
    (endpoint `https://api.s3.w.phonkd.net`, virtual-hosted, `us-east-1`);
    `open = {kind: s3, bucket, key}`.
12. `sources/ocis.py`: WebDAV `PROPFIND` (depth-walk) requesting `oc:fileid`;
    `open = {kind: url, url: https://ocis.w.phonkd.net/f/<fileid>}`. A
    dedicated oCIS app password in sops.
13. `sources/immich.py`: page all assets via the API (filename, taken date,
    city/country, people, albums); `open = {kind: url, url: …/photos/<id>}`.
    Immich API key in sops.
14. Raycast `s3` action: presign locally with the read-only key (small SigV4
    signer or `aws s3 presign`), `open` the URL; secondary action downloads to
    `~/Downloads` and reveals. The key reaches the Mac via secretspec.
15. **nixconfig:** Garage key grant on 201 (`deploy 201`), the three secrets,
    `deploy 204-agent`.

### Phase 3 — slop-trove: paperless + mail
**slop-trove:**
16. Records get `title`, `subtitle`, `open` in `metadata` (additive, no schema
    change). `ingest/paperless.py`: document text (already OCR'd) chunked +
    embedded, incremental by `modified`.
17. `ingest/mail.py`: IMAP over TLS to `mail.phonkd.net`, all folders except
    Junk/Trash, incremental by `UIDVALIDITY` + last UID; text = subject +
    from/to + plain-text body; `open = {kind: mail, message_id}`.
18. `upsert` → `ON CONFLICT … DO UPDATE` when text/metadata changed (paperless
    edits), instead of `DO NOTHING`.

**search-launcher:**
19. `sources/slop_trove.py`: read `source IN ('paperless','mail')` rows
    (title/subtitle/open only, one row per document/message) from 204's
    Postgres with a read-only role; drop the phase-1 paperless crawler.
20. Raycast `mail` action (`message://`).

**nixconfig:**
21. IMAP credential for 204 (see open decisions), read-only Postgres role for
    the indexer, `deploy 204-agent`.

## Open decisions

- **One store or two** — *recommend* **two** (above): slop-trove for
  information (embedded, agent-facing), a nightly SQLite for files. The
  launcher merges them at build time. Alternative: put files into slop-trove
  as in `plans/slop-trove-file-sources.md`. That gives one DB, but embeds
  every path and needs an online API for the launcher.
- **What happens to `slop-trove-file-sources.md`** — with this split its
  crawlers move here. *Recommend* putting it on hold. If Hermes later needs
  "give me the space wallpaper", give it a tool that queries this SQLite on
  204 rather than re-crawling into Postgres. Its image-captioning idea could
  later add a caption column here.
- **Where the indexer runs** — *recommend* **204** (next to slop-trove's DB,
  where agents live; Samba via read-only CIFS). Alternative: 203 reads
  `/mnt/Shares` from disk directly, but then it needs network access to 204's
  Postgres.
- **Getting the index to the Mac** — *recommend* a launchd rsync pull over
  ssh. Alternatives: upload to the Garage priv bucket, or syncthing. Both work
  and both add a moving part.
- **Mail credentials** — *recommend* a Dovecot **master user** on the mail VM so
  204 never holds the real account password. Alternative: the account's
  plaintext password in sops for 204.
- **S3 on the Mac** — a read-only Garage key on the Mac (recommended, needed
  to presign at open time) vs. only indexing buckets that already have a web
  endpoint and opening `https://<bucket>.s3.w.phonkd.net/<key>` directly.
- **Launcher** — *recommend* Raycast. Alternatives: Hammerspoon `hs.chooser`
  or fzf in kitty. With a local SQLite file, the fzf version is about 20 lines,
  which makes it a good throwaway prototype before the extension exists.
- **Private share** — excluded by default.

## Risks / rollout

- **The index file holds mail subjects/senders and file paths** and ends up on
  the Mac's disk. It's a local file readable by your user only, similar to
  Apple Mail's own cache. Mail *bodies* stay in slop-trove on 204 and aren't
  copied into the SQLite file.
- **Backfill load on 203's 3060 Ti** (phase 3 only): first-time embedding of
  the mail archive competes with Jellyfin NVENC and Immich ML. Run it as a
  throttled oneshot, or point it at `blac`'s ollama while that box is on.
  The file index needs no GPU at all.
- **Crawl duration**: a full nightly walk of the shares, S3, oCIS and Immich
  should be minutes to tens of minutes. The timer runs at night and failures
  keep the previous day's rows.
- **Hermes unaffected**: slop-trove changes are additive sources + metadata;
  its MCP `search` path is untouched.
- **Rollout**: `deploy 204-agent` for everything server-side, `deploy 201`
  only for the Garage key grant (phase 2), Mac rebuild for the cask + pull job.
  Nothing touches 201's traefik. Back out by disabling the timer / sources.
