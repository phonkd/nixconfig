# Hermes alert-autofix pipeline

**Repo(s):** `nixconfig` (one new Hermes skill on `204-agent`, plus a one-time
`hermes cron` setup step) and, at runtime, **draft PRs against `nixconfig`
itself**. **Status:** draft.

## Goal

Close the loop from *alert fires* → *fix proposed*. Today an alert goes
Mimir ruler → Mimir Alertmanager → Discord webhook (see
`plans/alert-overview.md`) and then just sits there as a red line a human has to
read, diagnose, and hand-fix. The want: **Hermes reacts to a firing alert,
spawns a Claude Code instance that opens a (draft) PR against this repo fixing
the cause, and Hermes presents that PR back in Discord** for the human to review,
merge, and `deploy`.

Autonomy envelope (the safe default this plan builds):

- Hermes **proposes**, never applies. The pipeline ends at a **draft PR** + a
  Discord summary. A human merges and runs `deploy <host>`. No auto-merge, no
  auto-deploy, no push to `main`. This matches the repo rule that *the user opens
  and merges PRs themselves*, and the scar tissue that GitHub-style autofix
  commits have invented nonexistent nix options before (see the `nixconfig`
  skill).
- **One PR per distinct alert**, deduped by alert fingerprint so a
  chronically-firing unit doesn't spawn a PR every poll.
- Hermes only opens a PR for alerts it judges **fixable in `nixconfig`**;
  everything else gets a one-line triage note (or stays `[SILENT]`).

## What already exists (nothing new to build in Hermes)

Confirmed against `NousResearch/hermes-agent` @ `daedf4f` (the flake-locked rev):

| Primitive | How | Where |
|---|---|---|
| Scheduled unattended prompt | `hermes cron create "every 10m" "<prompt>" --skills … --deliver …`; in-process 60s ticker runs a full agent turn and delivers the result | `cron/`, jobs in `~/.hermes/cron/jobs.json` |
| Inbound HTTP webhook → agent run | `POST :8644/webhooks/<route>`, HMAC-authed, templates the payload into a prompt | `gateway/platforms/webhook.py` |
| Read live alerts | `GET http://10.9.0.1:9009/alertmanager/api/v2/alerts` (no auth, single-tenant) | already documented in the `mimir-alerting` skill on this host |
| Claude Code coding task → PR | claude-code skill shells out to `claude -p '<task>' --output-format json` in a workdir; can branch/commit/`gh pr create` | `skills/autonomous-ai-agents/claude-code/SKILL.md`, already installed |
| Deliver back to Discord | cron job's final agent response is delivered to `--deliver` target | `cron/scheduler.py` (`[SILENT]` sentinel suppresses delivery) |

The `204-agent` host already ships everything the coding step needs:
`pkgs.gh` + `GITHUB_TOKEN` (fine-grained PAT for the `gh` CLI), `pkgs.claude-code`
+ `CLAUDE_CODE_OAUTH_TOKEN`, `tmux`, `jq`, and the bundled claude-code skill
(`modules/hosts/204-agent.nix`). So the pipeline is **one new skill + one cron
job**, no new packages, no new inbound network path.

## Trigger: cron-poll, not webhook (decision)

Two ways to wake Hermes on an alert. This plan picks **poll**:

- **Poll (chosen).** A `hermes cron` job every ~10m curls
  `GET 10.9.0.1:9009/alertmanager/api/v2/alerts`, diffs against a watermark, and
  triages only *new* firing alerts. Hermes already reaches `10.9.0.1` outbound
  (it ships metrics there via Alloy and the `mimir-alerting` skill hits this exact
  endpoint), so **no new network path and no Alertmanager config change** — the
  Alertmanager receiver/template is UI-managed on the obs host and out of repo
  scope (see `plans/alert-overview.md`). Watermarking gives free dedup. Cost:
  up-to-poll-interval latency, which is irrelevant for a "open a PR for a human"
  loop.
- **Webhook (rejected for now).** `POST 204:8644/webhooks/alert-triage` from
  Alertmanager is lower-latency and HMAC-clean, but needs (a) obs→`192.168.3.204`
  inbound reachability that doesn't exist today, and (b) a new Alertmanager
  webhook receiver added through the Grafana UI on the obs host — reintroducing
  exactly the UI-managed, non-repo-tracked config the poll avoids. Keep as a
  future upgrade if poll latency ever matters.
- **Discord passthrough (rejected).** The existing Alertmanager→Discord message
  could trigger Hermes, but only with `DISCORD_ALLOW_BOTS=all|mentions` (default
  `none` drops other-bot/webhook posts), and routing an agent off a bot message
  in a channel is brittle vs. a structured API poll.

## The pipeline, end to end

1. **Cron fires** (`every 10m`). The skill itself (no `--script` preprocessor)
   curls the Alertmanager alerts API via the terminal toolset, filters
   `status.state == "active"` (firing), and keeps only fingerprints not already in
   the watermark; nothing new → the agent responds `[SILENT]` and delivery is
   suppressed.
2. **Triage** (`hermes-autofix` skill, below). For each new firing alert Hermes:
   pulls the alert's labels/annotations, optionally cross-checks Loki/Mimir for
   context (the `nixconfig-ops` conventions), and decides: **fixable in
   nixconfig?** Recurring failed-unit alerts, a wrong threshold, a missing
   firewall port, a misconfigured service option — yes. A dead disk, upstream
   outage, or something needing a human decision — no (triage note only).
3. **Spawn Claude Code** for a fixable alert. The skill invokes
   `claude -p '<task>' --output-format json` in a **fresh clone** of the repo
   (`gh repo clone` to a temp dir per run — no persistent checkout to drift),
   instructing it to: read the `nixconfig` skill, make the minimal change, verify
   with `nix-instantiate --parse` + grep (never a full eval — repo rule), branch,
   commit in the repo's style, and `gh pr create --draft`.
4. **Present.** Hermes' final response — delivered to the Discord ops channel —
   leads with the alert, one-line root-cause, and the **draft PR link**, e.g.
   `🔧 crowdsec-firewall-bouncer failing on 201-mono → draft PR #NN: pin bouncer
   to … / mask the unit`. If not fixable: `⚠️ <alert>: <why not auto-fixable>`.
5. **Human** reviews the draft PR, merges (or closes), and runs `deploy <host>`.
   The watermark keeps the same alert from re-triggering while the PR is open.

## nixconfig changes (this PR)

**One thing, declarative:** a new `hermes-autofix` skill installed into
`$HERMES_HOME/skills/devops/hermes-autofix/SKILL.md` via an activation script on
`204-agent`, mirroring the existing `hermesMimirAlertingSkill` block in
`modules/hosts/204-agent.nix` (same install pattern, same owner/group). The
skill body encodes the whole procedure above, including the hard guardrails:
draft-only, never merge/deploy/push-to-main, `nix-instantiate --parse` not full
evals, match commit style, and *distrust invented options — diff against a known
rule/module before trusting a generated change*.

Nothing else in nix is required: no new packages (all present), no new secret
(`GITHUB_TOKEN` already authorizes `gh`), no firewall change (poll is outbound),
no new systemd service (the cron ticker lives inside the already-running
`hermes-agent` gateway process).

## One-time setup (documented, user runs once — like the spotify/copilot auth)

After `deploy 204-agent` installs the skill, create the cron job once on the host
(cron jobs are runtime state in `~/.hermes/cron/jobs.json`, not declarative):

```bash
# as the hermes user on 204-agent
hermes cron create "every 10m" \
  "Run the hermes-autofix triage procedure for any newly-firing alerts." \
  --name alert-autofix \
  --skills hermes-autofix,autonomous-ai-agents/claude-code \
  --deliver discord:<ops-channel-id>
```

The skill is self-contained (it does the poll + watermark inline via the terminal
toolset), so no `--script` preprocessor is needed. Verify with
`hermes cron run alert-autofix` (one manual tick) and `hermes cron status`, and
sanity-check the first PR it opens by hand before trusting the loop.

## Guardrails / risks

- **Blast radius is a draft PR.** The pipeline never mutates a running host; the
  worst case is a bad draft PR the human ignores or closes. No auto-merge, no
  deploy, no push to `main`.
- **Cost / runaway.** Each fixable alert spends one `claude -p` run. The
  watermark caps this to one run per new alert; recurring alerts don't re-spawn
  while their PR is open. Optionally cap with `--max-budget-usd` on the
  `claude -p` call and a per-tick alert limit in the poll script.
- **Bad-fix risk.** Generated nix has invented options before — the skill forces
  `nix-instantiate --parse` + grep and a diff-against-known-good check, and the
  draft/human-merge gate is the backstop. A merged bad branch is diffable against
  the prior commit (repo rule).
- **Noise.** If it ever PRs the same known-broken units repeatedly, either fix or
  silence those at the source (`plans/alert-overview.md` Track C) or add an
  allowlist/denylist of alert names the skill will act on.

## Open decisions

- **Poll interval** — `every 10m` proposed; tighten to `5m` or loosen to `30m`
  freely (cron edit, no redeploy).
- **Fixable-alert scope** — start with Hermes' own judgement ("fixable in
  nixconfig?"); add an explicit allowlist of alert names if it acts on things it
  shouldn't. **Recommend** starting judgement-based and watching the first few.
- **Latency upgrade** — move poll → webhook only if 10-minute latency ever
  matters; requires the obs→204 path + Alertmanager receiver (above).
- **Deliver target** — which Discord channel the presentation lands in (the ops
  channel that already gets the Alertmanager webhook is the natural home).
