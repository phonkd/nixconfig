# crowdsec: Grafana dashboards instead of Discord pings

**Repo(s):** nixconfig
**Status:** done (2026-09-11 — `bc8a6b2`, deployed to 201 + observability)

## Goal

Make CrowdSec's work visible in Grafana, and drop the custom Discord
notification path (slack-plugin build, sops template, plugin broker tweaks),
which was ugly and has been 404ing on every ban anyway. Grafana alerting keeps
using the shared `discord_webhook_url` secret — only crowdsec's use goes.

## Why two hosts

- **201-mono** (crowdsec + firewall bouncer): enable the bouncer's Prometheus
  endpoint on `127.0.0.1:60601` and scrape it with Alloy next to the existing
  `:6060` crowdsec scrape. Remove the notification plumbing.
- **observability** (Grafana): provision two dashboards from grafana.com,
  vendored as JSON in `modules/grafana-dashboards/`.

## Dashboards (grafana.com)

| id | name | verdict |
|---|---|---|
| 21419 | CrowdSec Metrics (bossm8) | **take** — all `cs_*` metrics from :6060 |
| 23110 | CrowdSec Firewall Bouncer (bossm8) | **take** — `fw_bouncer_*`, needs :60601 |
| 21689 | Crowdsec Cyber Threat Insights | skip — `cs_lapi_decision` comes from a separate third-party exporter |
| 24049 | Crowdsec monitoring | skip — Kubernetes-shaped (pods, operator) |

Import fix-ups: drop `__inputs`/`__requires`, point `${DS_PROMETHEUS}` at the
dashboards' own `datasource` variable, default that variable to Mimir, pin a
stable `uid`.

## Steps

1. crowdsec.nix: remove slack plugin / notifications / `plugin_config` /
   sops template + secret decl / tmpfiles plugin+notification entries; keep the
   ban profile. Enable bouncer prometheus + add the Alloy scrape.
2. Vendor the two dashboards.
3. `deploy 201`, then `deploy observability`.
4. Verify: crowdsec + bouncer active, `:60601/metrics` serves `fw_bouncer_*`,
   no `slack` lines in the crowdsec journal after restart.
