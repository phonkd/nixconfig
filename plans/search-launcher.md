# search-launcher — homelab results inside Spotlight

**Repo(s):** new repo `trove` (macOS app: Spotlight indexer + open router) +
`search-launcher` indexer on 204 (nightly crawl → SQLite + thumbnails) +
`nixconfig` (204 wiring, Garage read key, Samba mount incl. private, Mac
install + pull job) + `slop-trove` (paperless/mail text for Hermes, optional).
**Status:** draft — written 2026-09-11, reshaped 2026-09-12 to Spotlight-native
rich results (no Raycast, no "open the app's search page" handoff).

## Goal

Hit ⌘Space, type, and homelab things appear **as real rows in Spotlight**:
an Immich photo shows its thumbnail, an S3 object shows its name and bucket, a
Samba file shows its filename and path, a paperless document shows its title
and OCR snippet. Enter opens the thing itself — never a search-results page.

| Source | Row shows | Enter |
|---|---|---|
| Immich | thumbnail, date, album/people | browser → `https://immich.w.phonkd.net/photos/<assetId>` |
| Samba (incl. **private**) | filename, share + path, file icon | Finder → mount if needed, `open -R` |
| S3 (Garage) | key, bucket, size | presign locally → `open` (browser downloads) |
| oCIS | filename, space/path | browser → `https://ocis.w.phonkd.net/f/<fileid>` |
| paperless | title, correspondent, OCR snippet | browser → `https://paperless.home.phonkd.net/documents/<id>/details` |
| mail | **already native** — Apple Mail indexes into Spotlight | Mail (nothing to build) |

## Why this needs an app (the question asked)

Spotlight only shows third-party content that an **installed app bundle has put
into its index**. There is no file, daemon or config that injects rows from
outside. So the deliverable is a small macOS app (`trove.app`) that does two
jobs and nothing else:

1. **Index:** donate items to Spotlight with title, description, keywords and
   **thumbnail**, in bulk, once a night.
2. **Route the open:** when a row is selected, the system launches the app with
   the item's identifier; the app then opens the browser URL, reveals the file
   in Finder, or presigns and downloads the S3 object. The app itself has no
   window beyond a menu-bar status item and a preferences pane.

Two Apple APIs can carry this, and step 1 of the plan is a spike to pick one:

- **Core Spotlight** (`CSSearchableIndex` / `CSSearchableItem` +
  `CSSearchableItemAttributeSet`): the bulk-indexing path, explicitly supports
  `thumbnailData` / `thumbnailURL`, per-source `domainIdentifier` (so a nightly
  rebuild is "delete domain, re-add"), and selection arrives as an
  `NSUserActivity` of type `CSSearchableItemActionType`.
- **App Intents `IndexedEntity`** (`indexAppEntities`): the macOS 26 layer, adds
  meaning-based matching and Spotlight **Actions**; in 26 Xcode extracts index
  metadata at build time, so entities are findable without launching the app.
  This is the same family as the yubioath-flutter Spotlight patch already in
  use here (`modules/hosts/types/gui/default.nix`).

*Recommendation:* Core Spotlight for the bulk rows (it is the one with
first-class thumbnails and batch delete), and `IndexedEntity` later for Actions
("download to Downloads", "copy link") and semantic matching. The spike decides
whether macOS 26's redesigned Spotlight ranks CoreSpotlight items visibly
enough; if it buries them under files, the App Intents path is the fallback.

## Approach

**Crawl on the server, index on the Mac.**

- **Nightly indexer on 204** (unchanged idea from the previous draft, still the
  right split): walks Samba (via read-only CIFS mount, **private share
  included**), Garage S3, oCIS and Immich, and writes `index.sqlite` plus a
  **thumbnail directory** (Immich thumbs, and optionally Quick Look-able icons
  for files). Full rebuild each night, atomic rename, a failed source keeps
  yesterday's rows. Nothing is embedded; this is metadata only.
  The Mac can't do this job: it sleeps, roams, and has no CIFS mount.
- **`trove.app` on the Mac** pulls that bundle over the tailnet (rsync/ssh,
  daily + at login), then re-donates every source to Spotlight. Thumbnails are
  referenced from the local cache via `thumbnailURL`.
- **Opening is local and credential-light**: browser URLs need nothing, Finder
  reveal mounts `smb://100.64.0.3/<share>` on demand, S3 presigns with a
  read-only Garage key from the Keychain.
- **Freshness stays nightly** (accepted): new things appear tomorrow; deleted
  things linger a day and error on open.

**Mail drops out of the launcher entirely** — Apple Mail already puts messages
in Spotlight, so indexing them again would only duplicate rows. Mail (and
paperless full text) into slop-trove stays worthwhile for *Hermes*, but it is
now an independent, optional phase, not part of this interface.

## Steps

### Phase 0 — spike (half a day, decides everything)
1. Throwaway Swift app: donate ~100 fake items to Core Spotlight with
   thumbnails across two `domainIdentifier`s, plus one `IndexedEntity` variant.
   Check in macOS 26 Spotlight: do rows show the thumbnail, how are they
   ranked/grouped, does selection reach the app, does domain-delete work.
   Outcome: Core Spotlight vs App Intents, and whether thumbnails render.

### Phase 1 — Samba + paperless, end to end
**`search-launcher` indexer (204):**
2. Flake + NixOS module (`services.search-launcher`: sources, output dir,
   nightly `OnCalendar`), Python + stdlib `sqlite3`.
3. Schema `items(id, source, title, subtitle, detail, path, mtime, size, mime,
   thumb, open_json)`; build to `.new`, atomic rename, carry over failed
   sources.
4. `sources/samba.py`: walk the read-only mount (Public, SemiPublic **and
   private**), skip video/audio blobs by mime, `open = {kind: smb, host, share,
   path}`.
5. `sources/paperless.py`: `/api/documents/`, title + correspondent + tags +
   OCR text (first ~2 kB as the Spotlight description), `open = {kind: url}`.

**`trove` app (new repo):**
6. Menu-bar app skeleton; rsync pull of `index.sqlite` + thumbs; a
   `CSSearchableIndex` donor that maps one SQLite row → one searchable item
   (one `domainIdentifier` per source).
7. Open router for `url` and `smb` (check `/Volumes/<share>`, else
   `open smb://…`, poll for mount, then `open -R`).
8. Build/install: Xcode build → copy `trove.app` into `/Applications`
   (a nix-store symlink is invisible to Spotlight — same reason the affine and
   yubioath entries in `gui/default.nix` are casks/local builds). Ship a
   `make install` and document it in the repo.

**`nixconfig`:**
9. Flake input + `services.search-launcher` on `204-agent` (nightly timer,
   output `/var/lib/search-launcher/`).
10. Read-only CIFS mount of **all three** shares on 204, credentials via sops.
11. Paperless API token in sops.
12. Mac: launchd agent (home-manager) that rsyncs the bundle daily/at login;
    the app itself installed manually per step 8 (documented, not nix-managed).
13. `deploy 204-agent`; verify in Spotlight: type a private-share filename →
    row with path → Enter reveals it in Finder (share initially unmounted);
    type a paperless title → Enter opens the document.

### Phase 2 — Immich, S3, oCIS
14. `sources/immich.py`: page all assets (filename, taken date, city, people,
    albums); download a thumbnail per asset into the thumb dir (bounded, see
    open decisions); `open = {kind: url, url: …/photos/<id>}`.
15. `sources/s3.py`: list objects with a read-only bucket-scoped Garage key;
    `open = {kind: s3, bucket, key}`.
16. `sources/ocis.py`: WebDAV `PROPFIND` with `oc:fileid`;
    `open = {kind: url, url: …/f/<fileid>}`.
17. `trove`: thumbnails wired to `thumbnailURL`; `s3` open action — SigV4
    presign with the key from Keychain, `open` the URL; ⌥ variant downloads to
    `~/Downloads` and reveals.
18. **nixconfig:** Garage read-only key grant (`deploy 201`), oCIS app password
    and Immich API key in sops, `deploy 204-agent`.

### Phase 3 — Hermes side (optional, independent)
19. slop-trove gains `paperless` and `mail` sources (full text, embedded) so
    Hermes can answer questions about them; the launcher doesn't depend on it.
    Mail there needs an IMAP credential — a Dovecot master user preferred over
    the account password (see `plans/slop-trove-file-sources.md` for the file
    side, now on hold).

### Phase 4 — polish
20. App Intents Actions ("copy link", "download", "reveal") if the spike says
    they are worth it; `IndexedEntity` for semantic matching.
21. Per-source toggles in the app's preferences; a "reindex now" menu item.

## Open decisions

- **Spotlight API** — Core Spotlight (recommended, thumbnails + batch) vs App
  Intents `IndexedEntity` (semantic + Actions). Phase 0 decides; they can
  coexist.
- **Immich thumbnail scope** — thumbnails are the whole point of Immich rows,
  but they cost disk on the Mac (~20 kB × asset count). *Recommend* a bounded
  set (favorites + last N years, configurable) rather than the whole library;
  the rest still index with metadata and a generic icon.
- **Immich rows vs Photos** — indexing every asset could crowd Spotlight.
  *Recommend* starting with a filter (favorites/albums/people) and widening.
- **Where the app's config lives** — a preferences pane + Keychain
  (recommended, it's a GUI app) vs a nix-managed config file. The app can't be
  nix-installed anyway (Spotlight + signing), so nix owns only the pull job.
- **Indexer language** — Python on 204 (recommended, matches slop-trove) vs
  writing the crawl in Swift inside the app (fewer moving parts, but then the
  Mac must reach CIFS/S3/oCIS itself and crawl while awake).
- **`slop-trove-file-sources.md`** — stays on hold; if Hermes should find files
  too, give it a tool that reads this SQLite rather than re-crawling.

## Risks / rollout

- **Spotlight may not rank third-party items where you want them.** This is
  the real project risk and why phase 0 exists before any server work.
- **The private share is indexed**, so filenames from it land in the Mac's
  Spotlight index (local, user-readable). File *contents* are never copied —
  only names, paths and metadata.
- **App distribution is manual** (Xcode build → `/Applications`), matching the
  yubioath-flutter precedent. A macOS update or signing change can require a
  rebuild; document the command in the repo.
- **Index size**: hundreds of thousands of items is fine for Spotlight, but the
  nightly full re-donate must batch (delete domain, then chunked adds) to avoid
  a long CPU spike; run it on the pull, not at login.
- **Rollout**: `deploy 204-agent` for the indexer, `deploy 201` only for the
  Garage key, Mac rebuild for the launchd pull job. Nothing touches traefik.
  Back out by deleting the app (its Spotlight domains go with it) and disabling
  the timer.
