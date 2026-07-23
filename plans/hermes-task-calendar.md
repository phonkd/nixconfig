# Hermes co-managed tasks + calendar

**Repo(s):** `nixconfig` (all lands on `204-agent`, same pattern as the
`mimir-alerting` / `hermes-autofix` skills). Vault *content* lives in Syncthing,
outside git. **Status:** draft.

## Goal

Manage my calendar and task list **together with** Hermes — not delegate to it,
not take orders from it. Both of us get equal *read* access to the same CalDAV
calendar and the same Obsidian task vault; Hermes gets *write* only on things I
asked for, and it **proposes** changes into a staging area rather than silently
reorganizing my board. Works from any device (phone included) because Hermes
runs server-side on `204-agent` and I reach it over Discord — Obsidian on the
phone is just a synced *view*, never the thing the agent has to reach.

The original sketch was four pieces: CalDAV server, an MCP caldav tool, an MCP
vault tool, and a task-management skill. Reading the running config collapses two
of them:

- **The terminal toolset already *is* the "vault tool."** Hermes runs
  `bash`/`curl`/`jq`/file ops directly (that's how `mimir-alerting` and
  `hermes-autofix` work). "Scoped filesystem access" = *which folder Syncthing
  brings to `204-agent`* + a skill that says where it may write. No new tool
  server.
- **CalDAV is just HTTP**, so it's the same shape as the Mimir skill — a skill
  over a CLI/`curl`, not a bespoke MCP server. A local calendar CLI (`khal` +
  `vdirsyncer`) does the iCalendar/timezone grunt work that raw `curl` +
  hand-written `VEVENT` would make miserable.

So the real build is: **two packages, one sops secret, one Syncthing folder, two
skills, and one cron sync job.** No changes to `hermes-agent` itself, no new
inbound network path, no new service.

## Approach

### Calendar (CalDAV — server already self-hosted)

1. Add `pkgs.khal` + `pkgs.vdirsyncer` to `services.hermes-agent.extraPackages`
   on `204-agent` (alongside the existing `gh`/`claude-code`/`tmux`/`jq`).
2. `vdirsyncer` config + a `khal` config in the hermes state dir, pointed at the
   CalDAV URL; credentials from a new sops secret `hermes-caldav`
   (`owner = "hermes"`, added to `environmentFiles`), same one-var-per-file
   discipline the Discord secrets use.
3. A `caldav` skill (`$HERMES_HOME/skills/personal/caldav/SKILL.md`, installed by
   activation script like the others) teaching Hermes to:
   `vdirsyncer sync` first, then `khal list <range>` to read, `khal new` to
   create, edit via the on-disk `.ics` + `vdirsyncer sync` to push. Read is
   unrestricted; **create/modify only when I asked for that specific event; never
   `khal delete` and never bulk-reschedule** — those need a human.

### Tasks (Obsidian vault over Syncthing)

1. **Sync a task *subfolder* of the vault to `204-agent`**, not the whole vault —
   that is the write-surface scoping. Syncthing folders are GUI-managed today
   (`modules/homelab/apps/syncthing.nix` only enables the service); adding the
   `204-agent` peer + sharing just `tasks/` is a one-time runtime step, like the
   `hermes cron` job and the Spotify PKCE auth. (If `204-agent` isn't already a
   Syncthing peer, enabling `services.syncthing` on it is a small declarative add;
   the folder share itself stays GUI-side.)
2. **One file per task**, not the single Kanban-plugin board file. The Kanban
   plugin stores a whole board as one markdown file; Hermes writing it while my
   phone holds a stale copy is exactly how Syncthing produces
   `board.sync-conflict-<date>.md`. One-file-per-task + Tasks-plugin *queries* to
   render board/column views means there's no shared file to collide on — conflicts
   stay isolated to a single task I'd never be editing at the same instant.
3. **Propose, don't mutate.** Hermes writes new/uncertain items only into
   `tasks/inbox/` (or a `## Proposed` staging note); I triage them onto the board.
   It may *read* the whole `tasks/` tree, and may flip/edit only tasks I explicitly
   told it to. Enforced by the skill's rules + the folder scope (it literally can't
   see notes outside `tasks/`).
4. A `task-management` skill documents: the Tasks-plugin checkbox syntax I use,
   the column/status convention, where `inbox/` is, and the propose-don't-mutate
   rule. This is the piece I'll iterate on most — keeping it a skill (not a tool)
   means changing my mind about columns is a `SKILL.md` edit, not a service
   redeploy.

### Keeping the two in step

A `hermes cron` job (`every 15m`, created once by hand like the autofix job) runs
`vdirsyncer sync` so `khal`'s view is fresh, and optionally surfaces
today's/overdue items. `[SILENT]` when there's nothing to say, so no Discord spam.

## Steps

Per-repo, each verifiable on its own:

1. **`nixconfig` / `204-agent.nix`** — add `khal` + `vdirsyncer` to
   `extraPackages`; add `sops.secrets."hermes-caldav"` (`owner = "hermes"`) and
   append its path to `environmentFiles`. Add the CalDAV creds to `secret.yaml`.
2. **`nixconfig` / `hermes.nix` (or `204-agent.nix`)** — activation script that
   writes the `vdirsyncer`/`khal` config into the hermes state dir from the
   secret, plus the `caldav` `SKILL.md`. Model on the existing
   `hermesMimirAlertingSkill` activation script.
3. **`nixconfig`** — activation script for the `task-management` `SKILL.md`.
4. **Deploy** `deploy 204-agent`.
5. **Runtime (one-time, on the host)** — `vdirsyncer discover`/first sync;
   Syncthing: add `204-agent` as a peer and share only the vault's `tasks/`
   folder to it; create the `hermes cron` sync job. Document these in the plan's
   tail like the autofix "one-time setup".
6. **Verify** — `khal list` shows real events; Hermes over Discord can read a
   task and write a proposal into `tasks/inbox/` that shows up in Obsidian on the
   phone; a sync-conflict does *not* appear on the board.

## Open decisions

Defaults picked; say if you'd override:

- **CalDAV access = `khal`/`vdirsyncer` CLI** (recommended) vs. raw `curl` +
  hand-written iCalendar vs. a Python `caldav` MCP server. CLI wins: no new
  service, handles timezones/ETags/`VEVENT` for us, fits the "skill over a
  terminal" pattern already in the repo. The MCP server is the fallback only if I
  end up wanting the calendar reachable by something other than Hermes.
- **Tasks = one-file-per-task + Tasks-plugin queries** (recommended) vs. keeping
  the **Kanban plugin's single board file**. One-file-per-task is the only option
  that survives concurrent Syncthing edits without conflict files. Cost: I give up
  the Kanban plugin's drag-drop board and read the board through a Tasks query
  instead. If drag-drop matters more than conflict-safety, keep Kanban but then
  Hermes must stay entirely off the board file (writes to `inbox/` *only*, I move
  every card by hand).
- **Sync scope = `tasks/` subfolder only** to `204-agent` (recommended) vs. the
  whole vault. Subfolder = the agent's entire write/read surface is task data;
  nothing else in my vault is exposed to it. Only widen if I later want Hermes to
  reason over other notes.
- **Autonomy envelope** (recommended, matches the `hermes-autofix` house rule):
  read everything in scope; write only what I asked for; stage anything
  speculative into `inbox/`; **no** `khal delete`, **no** autonomous rescheduling,
  **no** deleting tasks. Loosen per-capability later if a specific chore proves
  safe.

## Risks / rollout

- **Sync conflicts** — the main hazard, addressed by one-file-per-task + the
  `inbox/` staging rule. Back-out is trivial: conflict files are recoverable and
  the agent's write scope is one folder.
- **Vault content is not in git.** The plan (this file) and all the nix wiring are
  version-controlled; the tasks/calendar data live in Syncthing/CalDAV. Losing
  `204-agent` loses no source of truth — it's a peer/consumer, not the origin.
- **Rollout** is additive and host-local: `deploy 204-agent`. Nothing touches the
  reverse proxy, networking, or other hosts. Back out by dropping the two
  `extraPackages`, the secret, and the two activation scripts, then redeploy; the
  Syncthing folder + cron job are runtime state removed by hand.
- **Credential blast radius** — `hermes-caldav` gives Hermes full calendar
  write. Scope the CalDAV account to just the calendars I want co-managed if the
  server supports per-calendar accounts.
