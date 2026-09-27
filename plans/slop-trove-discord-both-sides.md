# slop-trove: index both sides of Discord (DiscordChatExporter)

**Repo(s):** `slop-trove` (parser, CLI, NixOS module) + `nixconfig` (host wiring,
sops secret). **Status:** draft (2026-09-26)

## Goal

Today `source="discord"` in slop-trove is **half a conversation**. Discord's GDPR
data package contains only the messages *you sent* — verified on 204-agent, every
`Messages/c*/messages.json` row is exactly:

```json
{"ID": 1410665199752577024, "Timestamp": "2025-08-28 16:39:52", "Contents": "…", "Attachments": ""}
```

No author field, because there is nothing to disambiguate. `channel.json` gives
bare recipient IDs and no content from them. `ingest/discord.py`'s own docstring
already says so. The result: chunks read as a context-free monologue, and any
search for something *someone told you* cannot hit.

Replace that with a **DiscordChatExporter (DCE)** export — full channel history,
both sides, with real author metadata — so a chunk reads as a dialogue and the
other half of every conversation becomes searchable.

## Grounding

- **slop-trove** runs on **204-agent**; local Postgres+pgvector, embeds via 203's
  ollama (`bge-m3`, dim 1024), MCP on `127.0.0.1:9120` for Hermes.
- Existing GDPR export sits at `/var/lib/slop-trove/exports/discord` (owned by
  the `slop-trove` user, mode 0700).
- `discordchatexporter-cli` **2.43.3 is already in nixpkgs** (`pkgs/by-name/di/`,
  `mainProgram = "discordchatexporter-cli"`, `platforms.unix`) — no packaging work.
- The `mautrix-discord` bridge on **ext-mail** is live (259 portals) but has
  bridged only **39 messages**; Synapse holds 16 `m.room.message` events. It is
  not a history source and is not part of this plan.

## Approach

Three separable pieces. **Acquisition** lands in `nixconfig`, **parsing** in
`slop-trove`, and the **cutover** is a purge of the stale rows.

### 1. Acquisition — fully imperative, no stored credential

`slop-trove-discord-export` (a wrapper on 204-agent's PATH) takes the token at
invocation, stages it `0400` in a root-only tmpfs dir, and starts a oneshot
`slop-trove-export-discord.service` that writes one JSON per channel into
`/var/lib/slop-trove/exports/discord-dce/`.

**No timer and no sops secret.** A Discord *user* token is a full account
credential, and this is a thing you run a handful of times a year — storing it
permanently to support a schedule nobody wants is the wrong trade. It is also a
ToS-sensitive endpoint, which is not something to poll behind your back. The
unit exists (rather than running DCE inline) only so an hours-long export
outlives the ssh session that started it: journal, cgroup, `TimeoutStartSec=infinity`.
`ExecStopPost=+rm` shreds the staged token however the run ends.

`export.tokenFile` remains as an option for anyone who *does* want it unattended;
it just defaults to `null`.

Scope: **`exportdm` first** (DMs + group DMs). That is where "messages I received"
actually lives; guild channels are mostly public noise and would multiply the
volume. Guilds stay a follow-up, gated on what the DM run looks like.

### 2. Parsing — `slop-trove`

`ingest/discord.py` learns the DCE JSON layout and **auto-detects** which of the
two it is pointed at, the same way it already auto-detects `messages/` vs
`Messages/` and `.csv` vs `.json`. DCE's shape:

```json
{ "guild": {…}, "channel": {"id", "type", "name", …},
  "messages": [ { "id", "timestamp", "content",
                  "author": {"id", "name", "nickname", "isBot"}, … } ] }
```

Chunking stays as-is (`CHUNK_SIZE = 10`, `GAP = 6h`), but the embedded text
becomes `"<author>: <text>"` per line — exactly the shape `ingest/claude.py`
already uses for its human/assistant turns. Bot messages are skipped by default.
Metadata gains `authors` and `exporter: "dce"`.

The GDPR parser is **kept**, not deleted: it is the fallback for anyone without a
token, and it is what the current index was built from.

### 3. Cutover — purge the stale rows

DCE chunks get `hash_key = "dce:<channel_id>:<first_id>:<last_id>"`, so they will
not collide with the GDPR rows' `"<channel_id>:<first_id>:<last_id>"` — they would
silently **coexist**, and every message you sent would sit in the index twice, once
as a monologue and once in dialogue. So the old rows have to go.

Add `slop-trove purge --source <name>` to the CLI (small, and generally useful
whenever a source is re-derived from better data), plus a
`slop-trove-purge-discord` unit so the wrapper's `--reingest` can chain
purge → ingest without anyone hand-typing a destructive command.

## Steps

**slop-trove** — [PR #2](https://github.com/phonkd/slop-trove/pull/2)
1. [x] `ingest/discord.py`: `_parse_dce_file()` + layout auto-detection;
   `"<author>: "` line prefixes; `authors`/`exporter` metadata; bots skipped;
   attachment-only messages keep their turn. GDPR path byte-identical.
2. [x] `db.py`: `purge(conn, source)`; `cli.py`: `purge --source` (dry run by default).
3. [x] `nixos-module.nix`: `sources.discord.path` auto-detects either layout;
   `sources.discord.export` (`enable`, `tokenFile = null`, `outputPath`, `scope`)
   emitting the wrapper + `slop-trove-export-discord` + `slop-trove-purge-discord`.
4. [x] Pushed to `discord-dce-ingest`; PR open.

**nixconfig**
5. [x] `services.slop-trove.sources.discord.export` wired in `modules/hosts/204-agent.nix`;
   `sources.discord.path` moved to the DCE output dir. No sops secret — see above.
6. [ ] `flake.lock`: bump the `slop-trove` input (pinned to the PR branch until
   #2 merges, then flipped back to `main`).
7. [ ] Commit to `main`, `deploy 204`.

**Operate** — the user's call, needs their token
8. [ ] `sudo slop-trove-discord-export` → check volume and runtime.
9. [ ] `sudo slop-trove-discord-export --reingest` (or the two units by hand).
10. [ ] Spot-check with `slop-trove query` that *received* messages come back.

## Open decisions

- **DMs only, or guilds too?** Recommending `exportdm` for the first pass (see
  above). `scope` is an option, so flipping to `exportall` later is a one-line change.
- **Keep the GDPR export on disk?** Recommending yes, at least until the DCE run is
  verified — it is the only copy of anything DCE cannot reach (deleted accounts,
  channels you have since left). Costs nothing but disk.
- **Bot messages.** Skipped by default. Some bots (e.g. a music bot's now-playing)
  are arguably signal, but most are noise; flip via a parser constant if wanted.
- **Timer / stored token.** Deliberately neither. `export.tokenFile` is left in
  the module for anyone who later wants unattended runs; it defaults to `null`.
- **Back out of `--reingest`.** It purges before it ingests, so a failed DCE run
  followed by `--reingest` would empty `source=discord` and refill it from a
  partial export. The wrapper only chains when the export unit exits 0, but the
  retained GDPR package is still the real safety net.

## Risks / rollout

- **ToS.** DCE with a *user* token is a self-bot, which Discord's ToS prohibits.
  Account-action risk is real if small, and it is the reason this is a deliberate,
  user-made choice rather than a default. DCE's own rate limiting is conservative,
  which mitigates but does not eliminate it. **Accepted by the user on 2026-09-26.**
- **The token is a full account credential** — far more sensitive than a bot token.
  It is therefore *not stored at all*: handed over per run, staged `0400` in a
  root-only tmpfs dir, loaded by systemd as root via `LoadCredential`, reaching
  DCE through `DISCORD_TOKEN` and never through argv (where `ps` and the journal
  would see it), and removed by `ExecStopPost=+rm` however the run ends.
- **Volume.** A full DM history across years could be large. Embedding is the slow
  part (203's ollama, one HTTP round trip per batch of 64). Step 9 measures before
  step 10 commits.
- **Back out.** `slop-trove purge --source discord` + re-run the GDPR ingest against
  the retained export restores exactly today's state. Nothing else is destructive.
