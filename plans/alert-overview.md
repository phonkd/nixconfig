# Alert overview (OpsGenie-style) for homelab alerts

**Repo(s):** `nixconfig` only (new module + traefik/dashboard wiring; the obs host
gets the workload). **Status:** draft

## Goal

Today alerts fire from Mimir's bundled Alertmanager (rules in
`modules/observability.nix`) into a Discord webhook, and they land **ugly and
unstructured** — a wall of raw Alertmanager text with no grouping, no "what's
firing right now" view, no ack/silence. The want is an **OpsGenie-like overview**:
one page that shows all currently-firing alerts, grouped and deduped, with the
ability to silence/ack, instead of scrolling Discord history to reconstruct state.

Three independent wins, each shippable alone:
1. **An overview UI** — a proper alert dashboard (the OpsGenie replacement).
2. **Readable Discord messages** — fix the notification template so the webhook
   pushes are skimmable (the alerts that *do* go to Discord stop being noise).
3. **Less noise at the source** — the alerts that fire in practice are recurring
   failed-unit alerts; group/inhibit or fix-or-silence them so the board and Discord
   aren't dominated by the same three known-broken services.

**Pipeline confirmed (2026-07-18, from a raw sample).** A real Discord message —
`[FIRING:3] … SystemdServiceFailed … crowdsec-firewall-bouncer.service failed on
201-mono` — matches the repo's `SystemdServiceFailed` rule verbatim, wrapped in
Grafana's **default** message template. So everything is a **single pipeline**: Mimir
ruler → Mimir bundled Alertmanager → Discord. No Grafana-managed (Grafana-internal
Alertmanager) rules are in play, so any Mimir-Alertmanager-based overview (Karma, or
the alertlist panel on the Mimir Alertmanager datasource) sees *all* live alerts —
the earlier split-pipeline worry is retired. (If Grafana-managed UI rules are ever
added later, they'd route through Grafana's internal Alertmanager and need separate
coverage — flag it then.)

## Approach

**Don't build; view the Alertmanager we already run.** The stack already has the
hard part — Prometheus-style rules evaluated by Mimir's ruler firing into Mimir's
embedded Alertmanager (`ruler.alertmanager_url = .../alertmanager`). What's missing
is only a *view* over that Alertmanager's live alert state. Building a custom UI
would mean re-implementing grouping, silence CRUD, and the Alertmanager API client
for no gain — explicitly rejected. Two adopt-not-build options, and we ship the
cheap one first:

**Phase 1 (recommended first slice) — a Grafana `alertlist` dashboard.** Grafana is
already provisioned with dashboards-as-JSON (`modules/grafana-dashboards/*.json`,
declarative, read-only in the UI) **and** already has the "Mimir Alertmanager"
datasource. So the overview is *one new JSON file*: a dashboard whose main panel is
the native `alertlist` type reading firing alerts from that datasource, grouped by
`severity`/`instance`. Zero new service, no traefik, no firewall — reachable at
Grafana `:3000` over wg-obs like every other dashboard. Trade-off: it's a *view*,
not a console — silencing/ack still happens in Grafana → Alerting, and it's VPN-only.
This covers the core "one page of everything firing, grouped" want.

**Phase 2 (upgrade, optional) — Karma as a real wall-board.**
[Karma](https://github.com/prymitive/karma) is purpose-built: a single-binary
dashboard over the Alertmanager v2 API with richer grouping/dedup **and inline
silencing** — the closest self-hosted analog to an OpsGenie alert list. Already
packaged (`pkgs.karma`, 0.125) **with a NixOS module** (`services.karma`, freeform
YAML `settings` + `ALERTMANAGER_*` env), so it's wiring, not code. Do this only if
the Phase-1 panel feels too thin (want one-click silence, or a non-VPN internal URL).

- **Where it runs.** Co-located with the Alertmanager on the **observability Hetzner
  host** (`observability-server` tag), talking to `http://127.0.0.1:9009/alertmanager`
  — no cross-network Alertmanager exposure, same pattern as Grafana reaching Mimir on
  loopback. Bind `127.0.0.1:<port>` (NOT `openFirewall`).
- **How it's reached.** Front through **traefik on 201** as `alerts.home.phonkd.net`
  (ipfilter=internal, authelia — it can create silences), backend `10.9.0.1:<port>`
  over the existing wg-obs tunnel — the cross-host `phonkds.modules` shape from
  `apps/ocis.nix` / `arr-slime.nix` (routing/dashboard block gated on `reverse-proxy`
  pointing at the obs host's tunnel IP). 201 already reaches `10.9.0.1` over the
  tunnel; this also earns a homepage tile.

**Discord formatting (parallel track, independent of Phase 1/2).** The Discord contact point + message
template live in the Alertmanager tenant config, edited through **Grafana's Alerting
UI** (per the `alertmanager_storage` note in `observability.nix`) — i.e. *not*
repo-tracked today. Rewrite the notification template so each message leads with
`severity + summary`, then instance/description, dropping the raw label dump. Capture
the final template text in this plan / a comment so it's recoverable, even though the
source of truth is the UI-managed config on `/var/lib/mimir/alertmanager-storage`.

## Steps

### Phase 1 — Grafana alert-overview dashboard (nixconfig, cheapest slice) — **IMPLEMENTED 2026-07-18**
1. New `modules/grafana-dashboards/alerts.json` (`uid: alerts`, `tags:
   ["homelab","alerts"]`, `schemaVersion: 39`), matching the existing dashboards' shape.

   **Deviation from the original design — `ALERTS` metric, not `alertlist`.** The
   native `alertlist` panel was the planned main panel, but it's a **known Grafana
   limitation**: `alertlist` only renders Grafana's *built-in* Alertmanager, not an
   external/datasource-managed one — pointed at the Mimir Alertmanager datasource it
   comes up empty (confirmed via Grafana community reports / issue #108531). So the
   dashboard is built on the **`ALERTS` series instead**: Mimir's ruler writes
   `ALERTS{alertstate="firing"|"pending", severity, instance, alertname, …}` back to
   the ingesters, queryable via the **Mimir** (Prometheus) datasource — the same rules
   that feed the Discord Alertmanager, so it sees every live alert. What shipped:
   - **Stat row**: firing-critical / firing-warning / firing-total / pending, each
     `count(ALERTS{alertstate=…,severity=…}) or vector(0)`, colour-background.
   - **Firing table**: `ALERTS{alertstate="firing"}` (instant, `format: table`),
     `organize` transform (drop `Time`/`Value`/`__name__`/`job`/`alertstate`, rename
     `severity→Severity`, `alertname→Alert`, `instance→Host`, plus `name→Unit`,
     `mountpoint→Mount`, `zpool→Pool`, `state`, `device`, `disk`), `sortBy` Severity
     then Host, severity colour-mapped (critical=red, warning=orange).
   - **Pending table**: same, `alertstate="pending"`.
   - **Text panel**: notes it's read-only and that silence/ack lives in Grafana →
     Alerting → Silences on the Mimir Alertmanager datasource.

   Trade-off vs. `alertlist`: no silence-awareness (a silenced alert still shows here,
   since `ALERTS` is pre-Alertmanager) and no inline dedup grouping — that's Phase 2
   (Karma) territory. Covers the core "one grouped page of what's firing" want.
   import-tree ignores non-`.nix` files, so the JSON is inert as a module and just
   gets provisioned via `datasources`/`dashboards` provisioning in `observability.nix`.
2. `deploy observability`. Confirm the dashboard renders live alerts (temporarily
   lower a rule threshold, or fire a synthetic alert, to populate it). If Phase 1 is
   enough, mark the plan done and stop here. **← deploy still pending (not yet run).**

### Phase 2 — Karma wall-board (nixconfig, optional upgrade)
3. New module `modules/homelab/apps/karma.nix` defining `flake.nixosModules.karma`,
   `lib.mkMerge` of two self-gated blocks:
   - **`observability-server` block:** `services.karma` with
     `settings.listen.address = "127.0.0.1"`, `settings.listen.port = <port>`, and
     `settings.alertmanager.servers = [{ name = "mimir"; uri =
     "http://127.0.0.1:9009/alertmanager"; }]` (or the `ALERTMANAGER_URI`/`_NAME`
     env pair). Pick `<port>` free on the obs host (3100/9009/3000 taken; e.g. 8090)
     — grep per host-allocation rules.
   - **`reverse-proxy` block:** a `phonkds.modules.karma` entry — `ip = "10.9.0.1"`,
     `port = <port>`, `traefik = { enable = true; domain = "alerts.home.phonkd.net";
     ipfilter = true; auth = true; }`, `dashboard = { enable = true; icon = ...; }`.
4. Activate it: add `flake.nixosModules.karma` to `alwaysImport` in
   `modules/builder.nix` (it self-gates by tag). Since it's split across obs + 201,
   `alwaysImport` is cleaner than per-host `extraModules`.
5. **Firewall:** open `<port>` on the obs host's `wg-obs` interface only (mirror the
   existing `networking.firewall.interfaces.wg-obs.allowedTCPPorts` block in
   `observability.nix`) so traefik on 201 can reach it over the tunnel; keep it off
   every public interface.
6. `nix-instantiate --parse` the new file + grep for dangling refs, then
   `deploy observability` and `deploy 201`. Verify `alerts.home.phonkd.net` shows a
   test alert.

### Track B — readable Discord (mostly Grafana UI, not repo; parallel)
7. The current messages use Grafana's **default** message template (verbose: full
   `Labels:`/`Annotations:` dump per alert, `[FIRING:n]` header). In Grafana →
   Alerting → Contact points, define a custom message template and point the Discord
   contact point at it. Target one compact line per alert, e.g.:
   ```
   {{ range .Alerts }}{{ if eq .Labels.severity "critical" }}🔴{{ else }}🟡{{ end }} {{ .Annotations.summary }}
   {{ end }}
   ```
   (leads with severity + the already-good `summary`; drops the label wall). Keep the
   Source/silence link but make it useful — see step 9.
8. **Fix the broken `Source:` link.** It currently renders as a *relative*
   `/graph?g0.expr=…` because the Alertmanager's `external_url` is unset. Either set
   the ruler/Alertmanager external URL so links resolve, or repoint the template's
   link at the new overview (`alerts.home.phonkd.net`, or the Grafana dashboard URL)
   so a Discord alert is one click from the board.
9. Paste the finalized template into this plan (and/or a comment in
   `observability.nix`) so it survives a lost/rebuilt Alertmanager volume, since the
   contact-point config isn't declaratively managed.

### Track C — cut the noise (nixconfig + ops)
10. The sample shows the board would currently be dominated by three chronically
    failed units: `crowdsec-firewall-bouncer.service` + `crowdsec-update-hub.service`
    (201-mono) and `openipmi.service` (oldblac). For each, decide **fix vs. silence**:
    fix the unit if it should run; if it's expected-dead (e.g. openipmi on hardware
    without IPMI), either stop/mask the unit so `SystemdServiceFailed` stops matching,
    or add an inhibition/exclusion. Don't let permanent-red alerts train the eye to
    ignore the board — that defeats the whole point of building it.

## Open decisions

- **Grafana dashboard vs. Karma** — *recommend* **ship the Grafana `alertlist`
  dashboard first** (Phase 1): it reuses infra we already run, is one declarative
  JSON file, and covers the core "one grouped page of what's firing" want at
  near-zero cost. Add **Karma** (Phase 2) only if that panel proves too thin — i.e.
  you want inline silence/ack or a non-VPN internal URL. Not mutually exclusive; the
  dashboard is the floor, Karma the ceiling. **Leaning dashboard-first, Karma later.**
- **Karma exposure path (if Phase 2)** — *recommend* traefik-fronted
  `alerts.home.phonkd.net` (dashboard tile, authelia, ipfilter, consistent with
  every other app). Alternative: reach Karma directly over wg-obs like Grafana's
  `:3000` (no 201 involvement, but no tile and VPN-only). **Leaning traefik.**
- **Karma auth (if Phase 2)** — *recommend* `traefik.auth = true` (authelia) since
  Karma can create silences. Alternative: ipfilter-only. **Leaning authelia + ipfilter.**
- **Declarative Alertmanager config** — the Discord receiver/template is UI-managed
  today. Out of scope to convert to declarative `alertmanager_storage` seeding now;
  just document the template. Flag if we later want it in-repo.

## Risks / rollout

- **Phase 1** is essentially zero blast radius: a provisioned dashboard is read-only,
  reads an existing datasource, touches only the obs host, and backs out by deleting
  the JSON. Ship it freely.
- **Phase 2**: Karma is read-mostly against a loopback Alertmanager and lands on the
  **obs host** + a **routing-only** block on 201 — the reverse-proxy data path and
  existing alert *delivery* are untouched. Back out by dropping `phonkds.modules.karma`
  (route/tile vanish) and `services.karma.enable`.
- Deploy order: `deploy observability` first (workload + firewall), then `deploy 201`
  (route). If the route 404s, check 201→`10.9.0.1:<port>` over wg-obs and that the
  obs firewall opened the port on `wg-obs`, not publicly.
- Karma exposes infra state and silencing — keep it behind ipfilter+authelia; never
  `openFirewall` / never a public `*.w.phonkd.net` domain.
- Track B edits live-config on `/var/lib/mimir/alertmanager-storage` via the UI; a
  volume loss reverts it — hence capturing the template text in-repo (step 6).
