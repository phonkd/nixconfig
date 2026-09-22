# Music taste engine: Spotify GDPR export → recommendations → (later) a player

**Repo(s):** `earworm` (new sibling repo — code + NixOS module); `nixconfig`
for host wiring, secrets, traefik, dashboard.
**Status:** draft — approved in shape, **not started**. No code until the
Spotify export lands (requested 2026-09-22, ETA ~2026-10-22).

## Goal

Spotify's own recommendations have gotten worse and they hold the only copy of a
decade of listening. Take that back: feed the **GDPR extended streaming history**
export into something local, derive an honest model of taste from it, and have it
say *what new music to listen to* — with a reason attached, not a black box.

The end state, staged: a weekly "radar" of releases worth hearing → one click to
actually acquire them through the Soulseek/lidarr stack already running here →
eventually a player that plays the result, so the loop closes without Spotify in
it at all.

The unlock is that the GDPR export is **better data than any API gives you**: it
has `ms_played`, `skipped`, `reason_end` and `shuffle` per play. A scrobble says
"heard it". This says "heard it, and bailed at 0:14" — which is the signal that
actually separates love from tolerance.

## Grounding — the homelab already owns most of this

Checked against the tree, not assumed:

- **`slskd`** (Soulseek daemon) on **203-media**, `:5030`, `slskd.home.phonkd.net`,
  API key in sops, shares `/mnt/solo-sata/nixflix/music`, downloads to
  `/mnt/solo-sata/nixflix/downloads/slskd/complete` — `modules/arr-slime.nix`.
- **`lidarr`** on 203, `:8686`, `lidarr.home.phonkd.net`, API key + password in
  sops — same module. So the "find and fetch an album" machinery exists and is
  already pointed at Soulseek.
- **Music library**: `/mnt/solo-sata/nixflix/music` on 203.
- **`jellyfin`** on 203 `:8096` — already serves the library, badly, for music.
- **`ollama`** (RTX 3060 Ti, `ollama-cuda`) on 203 `:11434`, reachable on
  `192.168.3.0/24`; slop-trove on 204 embeds against it with `bge-m3`.
- **slop-trove** on 204 is the house pattern for "Python + Postgres/pgvector +
  a NixOS module in its own repo, host values in `nixconfig`". Copy it.
- **`gigaplayer`** (`modules/gigaplayer.nix`) — snapcast multiroom on 203 with
  AirPlay + Spotify Connect sources, snapclients on the desktops. That is the
  *output* path a future player should feed, not replace.

So this project is mostly **brain**, not plumbing. The plumbing is deployed.

## The data

Request the **"Extended streaming history"**, not the 5-day "Account data"
package — they are different requests on the same privacy page. Extended covers
the whole account lifetime and **takes up to 30 days to arrive**. It is the long
pole of this entire plan, so it gets requested before any code is written.

What lands (`Streaming_History_Audio_*.json`, one object per play):

| field | why it matters |
|---|---|
| `ts`, `ms_played` | recency weighting; completion ratio |
| `master_metadata_track_name` / `_album_artist_name` / `_album_album_name` | the only identifiers that survive |
| `spotify_track_uri` | join key back to Spotify, and to MBIDs via the ListenBrainz mapper |
| `skipped`, `reason_start`, `reason_end` | **the negative signal** — `fwdbtn` at low `ms_played` = rejection |
| `shuffle`, `offline`, `incognito_mode` | context; shuffle-plays are weaker evidence of intent |
| `platform`, `conn_country` | noise mostly; useful for "what do I play in the car" |

Also in the package and worth parsing: `YourLibrary.json` (saved tracks/albums —
explicit positive signal), `Playlist1.json` (curation = the strongest signal
there is), `SearchQueries.json` (intent), `Marquee.json` (artists Spotify thought
were mine).

## Why not just use the Spotify API

Because it no longer does the interesting part. On **2024-11-27** Spotify
deprecated `audio-features`, `audio-analysis`, `recommendations`, related-artists
and algorithmic/editorial playlists for any app registered after that date; new
credentials get 403/404 on all of them. There is no official replacement. Any
design that assumes "call `/recommendations` with seed tracks" is dead on
arrival, and the third-party "Spotify-shaped" audio-feature services that sprang
up since are just someone else's server between me and my own data.

So the taste model gets built from listening behaviour plus **open** music
metadata. Which is better anyway — it doesn't evaporate on a product decision.

### The data sources that do work

- **MusicBrainz** — canonical artist/release-group IDs, *first release dates*
  (this is what makes "what's new from artists in my orbit" a solved query),
  genres, relationships (member-of, collaborated-with). Rate-limited to ~1 req/s,
  so cache hard; a local mirror is possible later if it ever hurts.
- **ListenBrainz labs** (`labs.api.listenbrainz.org`) — collaborative-filtered
  **similar-artists** and **similar-recordings** datasets, queryable anonymously,
  plus the **MBID mapper** for turning `artist + track` strings into MBIDs. This
  is the "people who liked X also liked Y" ingredient, without having to build a
  CF model from one user's history (which cannot work — CF needs a crowd).
- **Last.fm API** — similar artists/tracks and crowd tags. Free, still alive,
  complements ListenBrainz with a different bias. One API key.
- **Essentia**, later — compute real audio features (BPM, key, timbre) over the
  files we *own*, giving a content-based signal that owes nothing to any API.
  Deferred; it only helps for music already in the library.

## Approach

Four stages, each a table, each inspectable. Deliberately not one model.

**1. Ingest → `listens`.** Parse the export into Postgres, one row per play.
Then resolve `(artist, track)` → `recording_mbid` / `artist_mbid` via the
ListenBrainz mapper, cached forever in a `mbid_map` table — the mapping is the
expensive part and it never changes.

**2. Taste model — a few honest scalars, not a vector.** Per artist and per
recording:

- `affinity` = Σ over plays of `w_recency(ts) × completion(ms_played)`, where
  completion caps at 1 and a play under ~30 s counts as 0;
- `rejection` = skip rate weighted by how early the skip came — an artist with
  200 plays and a 70 % early-skip rate is a *playlist* artist, not a loved one,
  and every scrobble-based system in the world gets this wrong;
- `curation` bonus for saved/playlisted tracks;
- `era` and `clock` profiles (release-year histogram, hour-of-day);
- a `discovery_ratio` — what share of listening is first-time-heard. This one
  number says how adventurous the recommendations are allowed to be.

The output that matters is a ranked **taste graph**: artists with weights, plus
their MusicBrainz genre/tag neighbourhood.

**3. Candidates.** Union of four generators, each tagged with its provenance so
the "why" survives all the way to the UI:

- *new-from-known* — MusicBrainz release-groups with a first-release-date in the
  last N weeks by any artist in the taste graph. This alone beats Release Radar,
  because it doesn't silently drop artists;
- *new-from-adjacent* — same, for ListenBrainz/Last.fm similar artists of top
  artists, filtered to ones never listened to;
- *back-catalogue* — older releases by artists I only know one album of ("you
  played *Rings* 400 times and never heard the other four records");
- *tag-neighbourhood* — releases in genres over-represented in the taste graph
  but under-represented in the library.

**4. Ranking.** Score = taste-graph proximity × novelty × source-agreement, minus
penalties for already-heard, already-owned, and artist repetition. Then **MMR
diversification** so a radar of 20 isn't 6 albums by one band. The explore knob
is a single parameter derived from `discovery_ratio` and overridable.

**5. Feedback, from day one of the UI.** Every recommendation carries
👍 / 👎 / "already know this". Without it the engine is frozen at whatever the
export said and drifts out of date the moment Spotify stops feeding it. Feedback
rows are also what make a local ranker trainable later.

### On the "full-fledged player" end state

Recommendation: **don't write a player.** Put **navidrome** on
`/mnt/solo-sata/nixflix/music` and get the Subsonic API for free — every decent
client on every platform (Feishin, Symfonium, play:Sub, Sonixd) speaks it, plus
scrobbling back into this engine's own `listens` table, which closes the loop:
local plays become new taste signal. The bespoke part stays the *radar* UI —
"here's what's new, why, and a button to get it" — which is the thing that
doesn't exist anywhere.

The engine's web UI then embeds a minimal player for preview/queue and hands off
to Subsonic clients for real listening. A from-scratch player is months of work
to arrive at a worse Feishin. Flagged as an open decision because the ask said
"full fledged music player" — say the word and it becomes Phase 5b.

### On acquisition

Also mostly don't build it: a picked album goes to **lidarr's API** (add artist /
album, monitored, search now) and lidarr drives slskd through the paths already
configured. Direct slskd search is the *fallback* for releases lidarr can't match
(bootlegs, mixes, anything without a clean MusicBrainz release). That keeps one
importer, one naming scheme, one library — rather than a second pile of files
this tool manages itself.

## Steps

Phased so each phase is useful standing alone. Phase 0 ships before the homelab
is touched at all.

**Phase −1 — done, waiting on delivery:**
- [x] **Request the Spotify extended streaming history export.** Requested
      2026-09-22 (along with the other providers'); Spotify quotes up to 30
      days, so expect it by ~2026-10-22. Nothing here can be validated on real
      data until it lands — build against a fixture meanwhile.
- [x] Repo/service name decided: **`earworm`** (`~/git/earworm`, service
      `earworm`, traefik `music.home.phonkd.net`).
- [ ] Create a Last.fm API key.

**Phase 0 — offline taste report (no service, no deploy).**
- [ ] New repo `earworm`, Python, `slop-trove`'s shape (`src/earworm/`,
      `pyproject.toml`, `package.nix`, `flake.nix`, `nixos-module.nix`).
- [ ] `parse` — export zip → Postgres `listens` + `library` + `playlists`.
- [ ] `report` — a printed/HTML taste report: top artists by affinity vs by raw
      plays (the gap is the interesting bit), skip-rate rankings, era profile,
      discovery ratio over time, "artists I dropped", "one-album artists".
      **This is the first deliverable and it's fun on its own.**

**Phase 1 — identity + the open-metadata spine.**
- [ ] `resolve` — ListenBrainz MBID mapper over distinct (artist, track), cached.
- [ ] MusicBrainz client with on-disk cache and 1 req/s throttle; artist,
      release-group, genre, first-release-date.
- [ ] Last.fm + ListenBrainz similarity clients, same cache discipline.

**Phase 2 — the radar (CLI).**
- [ ] Taste graph build; the four candidate generators; scoring + MMR.
- [ ] `radar --since 8w` → JSON + a static HTML page, each row carrying its
      provenance sentence ("new album by X, whose *Y* you finished 43 times").
- [ ] Validate by hand against a month of known releases. If it can't beat
      "albums by artists I already follow", the ranking is wrong — fix that
      before building a UI on top of it.

**Phase 3 — deploy it.**
- [ ] `nixos-module.nix`: service + local Postgres + daily `radar` timer.
- [ ] Wire on **203-media**; register in `phonkds.modules` (traefik
      `music.home.phonkd.net`, ipfilter, dashboard entry) in `nixconfig`.
- [ ] Web UI: the radar list, the taste report, and 👍/👎/"known" feedback.
- [ ] Notification on a fresh radar (ntfy / the existing alert path).
- [ ] `deploy 203`.

**Phase 4 — acquisition.**
- [ ] lidarr API client; "Get it" → add + monitor + search.
- [ ] Poll lidarr/slskd for state; show per-recommendation acquisition status.
- [ ] Direct-slskd fallback search for unmatched releases, landing in the same
      download dir so lidarr imports it.

**Phase 5 — the player.**
- [ ] navidrome on `/mnt/solo-sata/nixflix/music`, traefik + dashboard, on 203.
- [ ] Subsonic scrobbles → `listens`, so local plays feed the taste model and the
      engine keeps learning post-Spotify.
- [ ] Radar UI gains preview playback via the Subsonic API; "play in client"
      hand-off links.
- [ ] *(5b, only if bespoke-player is chosen)* — see open decisions.

**Phase 6 — keep it fed.** The Spotify export is one-shot unless re-requested;
`plans/export-drop-s3-index-jobs.md` is how a re-requested export gets picked up
without hand-copying. Once Phase 5 scrobbles exist, re-exports become optional.

## Open decisions

- **Host: 203-media (recommended) vs 204-agent.** 203 has the library, lidarr,
  slskd, jellyfin and the GPU; 204 has the existing Postgres/slop-trove pattern
  and nothing else this needs. Local file access (for Essentia later) and local
  API calls decide it — **203**, with its own Postgres, exactly as slop-trove has
  its own on 204.
- **Separate repo (recommended) vs a slop-trove source.** slop-trove is *semantic
  search over text*; music taste is a different data model on a different host.
  Separate repo, same shape, shared conventions.
- **Submit listening history to ListenBrainz?** Their *user* CF recommendation
  endpoints need a real account with your listens uploaded — i.e. handing a decade
  of listening to a third party, publicly by default. **Recommendation: don't.**
  Use the anonymous labs similarity datasets + Last.fm, which cover the same need
  without publishing anything. Reversible later if the recommendations
  disappoint; flagged because it's the one privacy-relevant fork here.
- **Player: navidrome + Subsonic clients (recommended) vs bespoke.** Argued
  above. Bespoke is genuinely months and lands worse; the interesting, unbuilt
  thing is the radar, not the transport controls.
- **Acquisition via lidarr (recommended) vs direct slskd.** lidarr for anything
  with a MusicBrainz release; slskd direct as the escape hatch.
- ~~**Repo/service name.**~~ **Decided 2026-09-22: `earworm`.**
- **LLM in the loop?** 203's ollama is right there. Recommendation: **not for
  ranking** (a small local model is worse than the arithmetic above and can't be
  debugged), but yes for *prose* — turning a provenance tuple into the one-line
  "why" and writing a weekly digest paragraph. Cheap, contained, nicer to read.

## Risks / rollout

- **The export is the critical path.** Up to 30 days, and it can arrive
  incomplete. Phases 0–1 can be built against a hand-rolled fixture; nothing
  should block on it except validation.
- **MusicBrainz rate limits** (1 req/s) make a first full resolve of ~10 years of
  listening a multi-hour job. Make it resumable and cached from the start, not as
  a later optimisation — this is the single most likely thing to make the project
  annoying to work on.
- **Recommendation quality is unfalsifiable if you don't check.** Hence the
  explicit Phase-2 hand-validation gate before any UI work. A radar that just
  lists new albums by followed artists is Release Radar with more steps.
- **Cold start for genuinely new music.** CF datasets lag by weeks for brand-new
  releases; the *new-from-known/adjacent* generators exist precisely to cover that
  gap, because they lean on MusicBrainz release dates rather than similarity.
- **Scope creep into a Spotify replacement.** The staging is the mitigation: if
  Phase 3 lands and nothing after it ever does, that is still a working weekly
  music radar, which is the thing that was actually asked for.
- **Rollout:** `deploy 203` per phase; back out by disabling the module. Nothing
  here touches 201 except a traefik route and a dashboard tile. Phase 4 is the
  first phase that *writes* anywhere shared (lidarr's library) — gate it behind an
  explicit confirm in the UI rather than auto-acquiring the radar.
