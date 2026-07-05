---
name: observability
description: How to query Loki (logs) and Mimir (metrics) directly via curl for hosts in this homelab — label schema, endpoint URLs, auth (none), reachability requirements, and example queries for node-level and per-service data (e.g. oCIS on 203-media). Read before debugging a service or checking resource usage instead of reaching for a dashboard.
---

# Querying logs and metrics directly

## Reachability

Loki (3100), Mimir (9009), Grafana (3000) run on the Hetzner `observability` VM at
`10.9.0.1`, firewalled to the `wg-obs` WireGuard interface only (see
`modules/observability.nix`). No auth on Loki or Mimir — reachable unauthenticated
from anywhere on the tunnel/home LAN. If `curl -m 3 http://10.9.0.1:9009/` doesn't
return a response, this machine isn't on the tunnel and nothing below will work.

## Label schema

Two different labeling paths feed Mimir, so the "which label do I filter on" answer
depends on the metric:

| Metric source | job | reliable host filter | notes |
|---|---|---|---|
| node_exporter (`prometheus.exporter.unix`) | `integrations/unix` | `hostname` **or** `instance` (both = hostname, e.g. `203-media`) | `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`/`MemTotal_bytes`, `node_filesystem_avail_bytes`/`size_bytes`, `node_load1`, `node_systemd_unit_state` |
| process exporter (per-service CPU/mem) | `integrations/process` | `hostname` **only** — `instance` is the exporter's own address (`127.0.0.1:9256`), not the host | `namedprocess_namegroup_cpu_seconds_total{groupname="..."}`, `namedprocess_namegroup_memory_bytes`, `namedprocess_namegroup_num_procs` |

Loki labels (from `loki.source.journal` + relabeling): `hostname`, `unit` (systemd
unit name, e.g. `ocis.service`), `job`, `component`, `service_name`. Loki also
auto-derives `detected_level` (`error`/`warn`/`info`/...) from log content — filter on
it instead of grepping. Never guess a `groupname` or `unit` value; list it first (see
below) — process/unit names don't always match the service's nix attribute name.

## Metrics (Mimir, PromQL, Prometheus-compatible API under `/prometheus`)

Instant query:
```sh
curl -s -G http://10.9.0.1:9009/prometheus/api/v1/query \
  --data-urlencode 'query=up{hostname="203-media"}'
```

Range query (trend over time):
```sh
curl -s -G http://10.9.0.1:9009/prometheus/api/v1/query_range \
  --data-urlencode 'query=namedprocess_namegroup_memory_bytes{hostname="203-media",groupname="ocis"}' \
  --data-urlencode "start=$(($(date +%s)-3600))" \
  --data-urlencode "end=$(date +%s)" \
  --data-urlencode 'step=60'
```
Mimir's `start`/`end` are **seconds** since epoch.

Discover values before querying blind:
```sh
curl -s http://10.9.0.1:9009/prometheus/api/v1/label/instance/values   # known hosts
curl -s -G http://10.9.0.1:9009/prometheus/api/v1/query \
  --data-urlencode 'query=namedprocess_namegroup_num_procs{hostname="203-media",groupname=~".*ocis.*"}'   # find the right groupname
```

Extract just the values with jq:
```sh
... | jq -r '.data.result[] | "\(.metric.groupname // .metric.instance): \(.value[1])"'
```

## Logs (Loki, LogQL, native API)

```sh
NOW=$(date +%s); START=$((NOW-3600))
curl -s -G http://10.9.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={hostname="203-media", unit="ocis.service"}' \
  --data-urlencode "start=${START}000000000" \
  --data-urlencode "end=${NOW}000000000" \
  --data-urlencode 'limit=50'
```
Loki's `start`/`end` are **nanoseconds** since epoch (`$(date +%s)000000000`) — the
most common mistake switching between the two APIs is reusing Mimir's second-based
timestamps here.

Filter to just errors: `{hostname="203-media", unit="ocis.service"} | detected_level="error"`.

Discover unit names before querying: `curl -s http://10.9.0.1:3100/loki/api/v1/label/unit/values`.

Extract just the log lines with jq:
```sh
... | jq -r '.data.result[].values[] | .[1]'
```

## Worked example: oCIS (203-media)

```sh
curl -s -G http://10.9.0.1:9009/prometheus/api/v1/query \
  --data-urlencode 'query=namedprocess_namegroup_num_procs{hostname="203-media",groupname="ocis"}'

NOW=$(date +%s); START=$((NOW-3600))
curl -s -G http://10.9.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={hostname="203-media",unit="ocis.service"} | detected_level="error"' \
  --data-urlencode "start=${START}000000000" \
  --data-urlencode "end=${NOW}000000000" \
  --data-urlencode 'limit=20' | jq -r '.data.result[].values[] | .[1]'
```

(Verified live 2026-07-05: oCIS's search service is repeatedly failing to
initialize — `error parsing mapping JSON: unexpected end of JSON input` —
recurring in the journal. Worth investigating separately; not fixed by this change.)

## Adding a new host/service

Any host tagged `observability-sender` (see `lib/registry.nix`) already ships node +
process metrics and journal logs via Alloy — no extra config needed to query a newly
deployed service on an existing sender host. A host without that tag isn't shipping
anything yet (see the `observability-sender` module in `modules/observability.nix`).
