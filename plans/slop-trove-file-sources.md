# slop-trove: file storage sources (S3 / Samba / oCIS)

**Repo(s):** `slop-trove` (code, packaging, NixOS module) + `nixconfig` (host wiring,
secrets, mount). **Status:** approved

## Goal

Today slop-trove indexes *text* exports (Discord, Claude.ai) so Hermes can answer
"find that argument about coffee setups". Extend it to index **files living in the
homelab's storage backends** — Garage S3, the Samba shares, and (optionally) oCIS —
so a request like *"give me the space wallpaper I saved"* works end to end: the
agent semantically finds the file, learns it lives on S3, and gets a URL it can
hand back to the user.

The unlock is two-part: (1) **find** a file by meaning, not by remembering its
path; (2) **fetch** it — the result has to be actionable, not just a filename.

## Where things live (grounding)

- **slop-trove** runs on **204-agent**: local Postgres+pgvector, embeds via 203's
  ollama, MCP server on `127.0.0.1:9120` exposed to Hermes. 204 reaches 203 over
  `192.168.3.0/24`.
- **S3 (Garage)** on **201-mono**: S3 API bound to `127.0.0.1:3900`, reachable from
  204 only through traefik at `https://api.s3.w.phonkd.net` (ipfilter=internal,
  region `us-east-1`, virtual-hosted-style under `.api.s3.w.phonkd.net`). Web
  buckets are already served at `<bucket>.s3.w.phonkd.net`.
- **Samba** on **203-media**: `/mnt/Shares/{Public,SemiPublic,private}`.
- **oCIS** on **203-media**: `:9200`, WebDAV, admin password in sops,
  `ocis.w.phonkd.net`.

## Approach

**Index files as text records; keep retrieval separate.** A file becomes a
`Record(source="files", ...)` in the existing `records` table — no schema change.
The embedded `text` is a synthesized description; the `metadata` carries an
actionable **locator**. This reuses the whole embed/upsert/search spine unchanged
and keeps true image-vector (CLIP) search as the already-planned v2 (see the note
in `db.py` — image embeddings get a separate vector space, out of scope here).

What goes into the embedded `text` per file:
- backend + human path + filename (tokenized: `space-wallpaper.png` →
  "space wallpaper png"), extension, mime type, size, mtime;
- **for images, an optional caption** from a local vision model on 203's ollama
  (e.g. a `llava`/`qwen2.5vl` pull) — this is what makes "space wallpaper" match a
  nebula screenshot whose filename is `IMG_4432.png`. Captioning is best-effort and
  cached by content hash so it runs once per file.

What goes into `metadata` (the locator):
- `backend` (`s3`|`samba`|`ocis`), `bucket`/`share`/`space`, object `key`/path,
  `etag`/mtime, `size`, `mime`, and a `uri` for display.

**Retrieval — a new MCP tool `get_file`.** `search_personal_data` stays text-only;
a second tool resolves a chosen result to a fetchable, time-limited URL so Hermes
never needs storage credentials itself:
- **S3:** native **presigned GET URL** (clean, expiring). Best case.
- **Samba / oCIS:** slop-trove serves a short-lived tokenized URL from its own HTTP
  server that streams the bytes (from a read-only CIFS mount for Samba; via WebDAV
  GET for oCIS). oCIS can alternatively mint a public share link via its API.

**Incremental + reconciliation.** `content_hash` for files keys on
`backend:path:etag` so an edited file re-embeds. A crawl records every key it saw;
rows for that backend not seen in the latest crawl are deleted (files move/vanish).
This is a real correctness point, not a nicety — call it out as its own step rather
than letting the DB accrete orphans (`upsert` today is `ON CONFLICT DO NOTHING`).

## Steps

Phased so the smallest useful slice — S3, the actual wallpaper example — ships
first. "possibly oCIS" is deliberately last and independently droppable.

### Phase 0 — shared `files` scaffolding (slop-trove)
1. `ingest/files.py`: a backend-agnostic crawler yielding `Record`s from a uniform
   `FileEntry` (backend, path, size, mtime, mime, opener); pluggable backends.
2. Text synthesis + filename tokenization; wire `content_hash` to `backend:path:etag`.
3. Optional image captioner (`caption.py`) hitting ollama's vision endpoint;
   gated by config, cached by hash. New `embed`-style client.
4. `mcp_server.py`: add `get_file(record_id | locator) -> {url, expires_at, mime}`.
   Give `records` a stable id in results so a search hit can be resolved.
5. Reconciliation pass in `db.py` (`prune(conn, source, seen_hashes)`), called at
   end of a files crawl.
6. `config.py` + `cli.py`: `ingest --source files --backend s3|samba|ocis`; new env
   vars for each backend.

### Phase 1 — S3 / Garage (slop-trove + nixconfig)
7. `backends/s3.py` via `boto3` (add dep): endpoint `https://api.s3.w.phonkd.net`,
   virtual-hosted-style, region `us-east-1`; list objects, HEAD for metadata,
   `generate_presigned_url` for `get_file`.
8. **nixconfig:** a **read-only S3 access key** for slop-trove (Garage `key create`
   + bucket-scoped read grant); store id/secret in the global sops file; expose to
   204 via `sources.s3` options on the slop-trove module (endpoint, buckets, key
   refs). Add the systemd oneshot `slop-trove-ingest-files-s3` (+ optional timer).
9. Verify the wallpaper path end to end from Hermes.

### Phase 2 — Samba (slop-trove + nixconfig)
10. `backends/samba.py`: walk a read-only mount; `get_file` streams via the
    slop-trove HTTP server behind a short-lived token.
11. **nixconfig:** read-only CIFS mount of the shares on 204 (credentials via sops);
    `sources.samba` options + ingest oneshot. Decide which shares to index (Public /
    SemiPublic yes; the private share — confirm with user).

### Phase 3 — oCIS (optional) (slop-trove + nixconfig)
12. `backends/ocis.py`: WebDAV list/get (a `webdav4`/httpx client); `get_file` via
    WebDAV GET or an oCIS public-link API call.
13. **nixconfig:** a dedicated oCIS app-password/service account in sops;
    `sources.ocis` options + ingest oneshot.

### Cross-cutting
14. README roadmap: fold this into v1/v2 (files = v1.5; CLIP image search stays v2).
15. `pyproject.toml`: add `boto3` (and `webdav4` if Phase 3 lands).

## Open decisions

- **Retrieval mechanism** — *recommend* `get_file` returning a presigned URL (S3)
  / proxied token URL (Samba, oCIS), so Hermes stays credential-free. Alternative:
  return raw bytes over MCP (simpler for the agent, but base64-bloats the transcript
  and caps file size). **Leaning presigned/proxy URL.**
- **Image understanding in v1** — *recommend* filename/path + optional vision
  caption (text embedding, reuses the whole spine). Alternative: ship filenames-only
  first and defer captions. True CLIP multimodal is explicitly v2. **Leaning
  caption-on, behind a config flag so it can be turned off if the vision model is
  too slow on the shared GPU.**
- **Samba access** — *recommend* a read-only CIFS mount on 204 (no new Python dep,
  simplest walk + stream). Alternative: `smbprotocol` in-process. **Leaning mount.**
- **Private share** — index it or not? User call. Default: **exclude** the private
  share until asked.
- **S3 credential scope** — *recommend* a dedicated **read-only, bucket-scoped**
  Garage key rather than reusing admin creds.

## Risks / rollout

- All new work self-gates and lands on **204-agent** (+ read-only touches to 201's
  Garage keys and a mount to 203) — **201-mono's reverse-proxy path is untouched**,
  so blast radius is low. Deploy with `deploy 204` (and `deploy 201` only for the
  S3 key grant). Back out by disabling the `sources.*` flags — the MCP server and
  existing text sources keep working.
- Captioning competes with Jellyfin transcode / bge-m3 for the RTX 3060 Ti on 203;
  the config flag + hash-cache keep it bounded and one-shot.
- Presigned URLs and proxy tokens are bearer secrets — keep TTLs short; the proxy
  server binds `127.0.0.1` like the MCP server (Hermes is co-located).
- Reconciliation (`prune`) deletes rows — scope it strictly to the one backend
  being crawled so a failed/partial crawl can't wipe another source (same class of
  footgun as the mimir `rules sync` note in the ops skill).
