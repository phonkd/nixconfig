# llm-NOOBservability — natural-language Loki/Mimir querier

**Repo(s):** new repo `llm-noobservability` (service code, package, NixOS module,
flake) + `nixconfig` (flake input, host wiring on `204-agent`, traefik/dashboard
entries). **Status:** draft.

## Goal

Ask an observability question in plain language ("errors from jellyfin in the
last hour", "cpu on 203 today") and get back real data + a summary, without
Grafana in the loop. A small local LLM (ollama on 203) translates NL → LogQL or
PromQL, the service executes it **directly** against Loki (`10.9.0.1:3100`) and
Mimir (`10.9.0.1:9009`), and self-corrects when a query parses wrong or returns
nothing. First a simple API; later a tiny chat web UI that draws a graph as soon
as data arrives and lets you download the JSON/CSV.

Explicitly *not* Grafana-MCP-shaped: the Grafana MCP detour proved unusable in
practice — we already curl Loki/Mimir directly (see `nixconfig-ops`), and this
service does the same.

## Approach

A 7B-class model can't free-associate correct LogQL, so the design is
deterministic scaffolding around a small model:

1. **Grounding cache** (the biggest quality lever): the service periodically
   pulls Loki label names + values (`/loki/api/v1/labels`,
   `/loki/api/v1/label/<name>/values`) and Mimir metric names
   (`/prometheus/api/v1/label/__name__/values`) and injects the relevant subset
   into the prompt. Proactive schema-in-context beats reactive retry for small
   models — the retry loop is the backstop, not the plan.
2. **Route**: one constrained-JSON LLM call decides logs vs metrics (or both).
3. **Generate**: constrained decoding (ollama structured outputs) emits
   `{target: loki|mimir, query, start, end, step}` — never free text.
4. **Execute**: `POST /loki/api/v1/query_range` or
   `GET /prometheus/api/v1/query_range`. Single-tenant Mimir, no
   `X-Scope-OrgID`. Read-only endpoints only (never anything ruler-shaped —
   see the mirror-op scar in the `nixconfig` skill).
5. **Repair loop** (max ~3 iterations), the user's core idea:
   parse error → feed the API's error text back; empty result → the model gets
   tools `list_labels`, `label_values(name)`, `search_metrics(substr)` and
   regenerates with a corrected selector.
6. **Respond**: final query (always shown — it's also how a noob *learns*
   LogQL), raw result JSON, and an LLM summary computed over a downsampled
   view (stats + sample lines, never 10k raw points into a 7B context).

**API** (phase 1): `POST /api/ask {question, range?}` → NDJSON/SSE stream of
events (`attempt`, `query`, `error`, `data`, `summary`) so a client can render
progress; `GET /api/health`. The `data` event is the downloadable artifact.

**Web UI** (phase 2): one static page served by the same process — chat pane,
each answer shows the query it ran, a chart (uPlot: ~40 kB, handles Prom
matrices and Loki metric queries; log streams render as a table) and
download-as-JSON/CSV buttons.

**Guardrails**: default `since=1h`, hard caps on range/`limit`/`step` so a
mis-generated query can't ask Loki for a month of raw logs.

**Model**: ollama on `192.168.3.203:11434`. Start with a Qwen-class 7–8B
instruct model (strong structured output for its size); the model name is
config. A config-flag escape hatch to a cloud model (OpenRouter/Anthropic)
for hard questions later — off by default, this is a local-first project.

**Placement**: `204-agent`. It already reaches both 203's ollama and
`10.9.0.1` (Alloy pushes there today), so no new network paths.

## Steps

**`llm-noobservability` repo (new):**
1. Scaffold: flake with package + NixOS module + dev shell; service skeleton
   with config (Loki/Mimir/ollama URLs, model, port, caps).
2. Grounding cache + Loki/Mimir read-only client.
3. Route → generate → execute → repair loop; CLI entry point
   (`noob "question"`) for fast iteration against the real stack.
4. `POST /api/ask` streaming endpoint + `/api/health`.
5. Phase 2: static chat UI + uPlot graph + download.

**`nixconfig`:**
6. Flake input + module activation for `204-agent`; port chosen after the
   mandatory `grep -rn "<port>" modules` collision check.
7. `phonkds.modules.noobservability`: `lib.mkMerge` two-block pattern —
   workload gated on the 204 host, routing/dashboard gated on `reverse-proxy`
   (`noob.int.w.phonkd.net`, `ipfilter = true`). Phase 2, once the UI exists.
8. `deploy 204-agent`, verify with real questions end-to-end.

## Open decisions

- **Language** — recommend **Python** (FastAPI + httpx): fastest iteration,
  best ollama/structured-output ecosystem, matches slop-trove precedent.
  Alternative: Go for a single static binary — nicer artifact, slower to
  iterate on prompt/loop logic.
- **Model** — recommend starting with `qwen2.5-coder:7b-instruct` (or the
  current Qwen3 8B) and measuring hit-rate on ~20 real questions before
  considering anything else. It's a config string; cheap to swap.
- **Streaming vs blocking API** — recommend streaming (NDJSON) from day one;
  the repair loop makes answers slow enough that progress events matter, and
  the phase-2 chat UI wants them anyway.
- **UI auth** — `ipfilter` only (internal domain) vs also `forward-auth`
  (authelia). Recommend ipfilter-only: read-only data, LAN-only, zero login
  friction for a toy-that-should-get-used.
- **Hermes overlap** — Hermes on 204 could grow an MCP connection to this
  service later (like `slop_trove`), giving Discord access for free. Out of
  scope now; the API-first design keeps it possible.

## Risks / rollout

- **7B query quality** is the whole risk. Mitigations: grounding cache,
  constrained decoding, repair loop, always displaying the executed query so
  wrong answers are *visibly* wrong. If hit-rate stays bad after tuning, the
  cloud-model flag is the fallback — the scaffolding is model-agnostic.
- **Query cost/blast radius**: read-only endpoints + hard range/limit caps;
  worst case is a slow Loki response, nothing mutable is reachable.
- **Rollout**: all changes land via `deploy 204-agent`; nothing touches
  `201-mono` until the phase-2 traefik entry, which is a registry-file change
  rolled out with `deploy 201` and backed out the same way.
