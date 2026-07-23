# Hermes co-managed tasks + calendar

**Repo(s):** `nixconfig` (all lands on `204-agent`, same pattern as the
`mimir-alerting` / `hermes-autofix` skills). Vault *content* lives in a synced
Obsidian vault, outside this repo. **Status:** draft.

## Goal

Manage my calendar and task list **together with** Hermes — not delegate to it,
not take orders from it. Both of us get equal *read* access to the same CalDAV
calendar and the same Obsidian vault; Hermes gets *write* only on things I asked
for, and it stages speculative items rather than silently reorganizing my list.
Works from any device (phone included) because Hermes runs server-side on
`204-agent` and I reach it over Discord — Obsidian on the phone is just a synced
*view*, never the thing the agent has to reach.

**Task model I want:** *one big list* of all open tasks (a single backlog file,
not a file-per-task), and a **daily list** — either of us plans the day by
picking tasks from the backlog that fit. The daily list is a *lens*, not a copy:
each task carries an optional scheduled date, and "today" is a Tasks-plugin query
over the one backlog. Planning the day = setting scheduled dates; there's only
ever one source of truth, so the day plan can't drift from the backlog.

The original sketch was four pieces: CalDAV server, an MCP caldav tool, an MCP
vault tool, and a task-management skill. Reading the running config collapses two
of them:

- **The terminal toolset already *is* the "vault tool."** Hermes runs
  `bash`/`git`/file ops directly (that's how `mimir-alerting` and `hermes-autofix`
  work). "Vault access" = *the agent keeps a checkout/replica of the vault* + a
  skill that says where it may write. No new tool server.
- **CalDAV is just HTTP**, so it's the same shape as the Mimir skill — a skill
  over a CLI/`curl`, not a bespoke MCP server. A local calendar CLI (`khal` +
  `vdirsyncer`) does the iCalendar/timezone grunt work that raw `curl` +
  hand-written `VEVENT` would make miserable.

## The conflict problem (and why the sync layer is the whole decision)

I want the **entire vault synced** and **one big shared list**, not
one-file-per-task. That reopens the concurrent-edit problem: one file, two
writers (me on mobile, Hermes on `204-agent`), and a sync layer decides what
happens when both touch it.

**The key fact:** plain **S3 and plain Syncthing replicate, they don't merge.**
Two edits to one file → last-write-wins clobber, or a `.sync-conflict-<date>.md`
dupe. They're fine for whole-vault device sync, but a file *two of us edit* needs
a layer that actually merges. The two that do:

- **Git (recommended).** Obsidian Git plugin on every device (auto pull/commit)
  + Hermes as an ordinary git client with a checkout. Line-level 3-way merge:
  collisions happen only on the *same line*, and they surface as real, resolvable
  conflicts — never a silent dupe. Fits this repo's culture, and Hermes editing
  is just `git pull --rebase` → edit → commit → push. S3 can still back it (git
  remote or plain object push), but git — not S3 — is what merges.
- **Obsidian LiveSync (self-hosted CouchDB).** Purpose-built for concurrent
  Obsidian editing, best mobile story, chunk-level merge. Cost: Hermes editing
  *outside* Obsidian is harder — it talks to CouchDB or keeps a replica, more
  moving parts than a git checkout. A homelab CouchDB is a new service.

On top of whichever merge layer, **convention keeps real collisions near zero:**
Hermes works in short pull→edit→push bursts and edits *append-mostly* (drops new
items under an `## Inbox` heading, sets a scheduled date on its own line) rather
than reordering my lines. Same-line collisions with me become vanishingly rare,
and when one happens it's a git conflict I can resolve, not lost data.

## Approach

### Tasks (one Obsidian vault, git-synced)

1. **Whole vault synced, via git as the merge layer.** Obsidian Git plugin on
   desktop + mobile; the vault is a git repo (remote on the homelab or a private
   GitHub repo — small sub-decision). Hermes keeps a checkout on `204-agent` and
   `git pull --rebase` / commit / push around every edit.
2. **One big backlog file** — e.g. `tasks/backlog.md`, every open task as a
   Tasks-plugin checkbox with optional metadata (`📅 scheduled`, `⏳`,
   `🔺 priority`, tags). No file-per-task, no Kanban single-board file.
3. **Daily list = a query, not a copy.** A daily note `daily/YYYY-MM-DD.md` holds
   a Tasks query (`(scheduled on YYYY-MM-DD) OR (due before tomorrow)`) that
   renders today's picks live from the backlog. **Planning the day** — by me or
   Hermes — is just *setting scheduled dates* on backlog items. One source of
   truth; the day is a lens over it.
4. **Propose, don't mutate.** Hermes appends new/uncertain tasks under an
   `## Inbox` region (of `backlog.md` or a separate `inbox.md`); I triage them
   into the list. It may set scheduled dates / check off only tasks I explicitly
   asked it to. Enforced by the skill's rules + the append-mostly convention.
5. A `task-management` skill documents: the Tasks-plugin syntax I use, the
   backlog/daily-note layout, the `## Inbox` staging rule, the "planning = set a
   `📅` date" workflow, and the git pull→edit→push discipline. This is the piece
   I'll iterate on most — keeping it a skill (not a tool) means changing my mind
   about the layout is a `SKILL.md` edit, not a service redeploy.

### Calendar (CalDAV — server already self-hosted)

1. Add `pkgs.khal` + `pkgs.vdirsyncer` to `services.hermes-agent.extraPackages`
   on `204-agent` (alongside the existing `gh`/`claude-code`/`tmux`/`jq`).
2. `vdirsyncer` + `khal` config in the hermes state dir, pointed at the CalDAV
   URL; credentials from a new sops secret `hermes-caldav` (`owner = "hermes"`,
   added to `environmentFiles`), same one-var-per-file discipline the Discord
   secrets use.
3. A `caldav` skill (`$HERMES_HOME/skills/personal/caldav/SKILL.md`, installed by
   activation script like the others): `vdirsyncer sync` first, `khal list <range>`
   to read, `khal new` to create, edit via the on-disk `.ics` + `vdirsyncer sync`
   to push. Read unrestricted; **create/modify only for events I asked for; never
   `khal delete`, never bulk-reschedule** — those need a human.

### Keeping it in step

A `hermes cron` job (`every 15m`, created once by hand like the autofix job) runs
`vdirsyncer sync` + `git pull` so `khal`'s and the vault's views are fresh, and
optionally surfaces today's/overdue items. `[SILENT]` when there's nothing to
say, so no Discord spam. This is also the natural "plan my day" entry point in
the morning.

## Steps

Per-repo, each verifiable on its own:

1. **`nixconfig` / `204-agent.nix`** — add `khal` + `vdirsyncer` to
   `extraPackages`; add `sops.secrets."hermes-caldav"` (`owner = "hermes"`) and
   append its path to `environmentFiles`. Add the CalDAV creds to `secret.yaml`.
   If a git remote needs a token for the vault repo, add that secret too.
2. **`nixconfig` / `hermes.nix` (or `204-agent.nix`)** — activation script that
   writes the `vdirsyncer`/`khal` config from the secret, plus the `caldav`
   `SKILL.md`. Model on the existing `hermesMimirAlertingSkill` activation script.
3. **`nixconfig`** — activation script for the `task-management` `SKILL.md`.
4. **Deploy** `deploy 204-agent`.
5. **Runtime (one-time, on the host)** — `vdirsyncer discover`/first sync; clone
   the vault repo to Hermes' checkout and configure git identity/credentials;
   create the `hermes cron` sync job. On my devices: install + configure the
   Obsidian Git plugin (or LiveSync). Document these in the plan's tail like the
   autofix "one-time setup".
6. **Verify** — `khal list` shows real events; I add a task on the phone and
   Hermes sees it after a pull; Hermes drops an item under `## Inbox` and it
   shows up in Obsidian; concurrent edits to `backlog.md` produce a git merge,
   **not** a `.sync-conflict` dupe.

## Open decisions

Defaults picked; say if you'd override:

- **Sync/merge layer = git** (Obsidian Git + Hermes git client) — recommended,
  because it's the only option that both (a) merges one shared list without dupes
  and (b) lets Hermes edit with plain terminal/git, no new service. Alternative:
  **Obsidian LiveSync/CouchDB** (better concurrent-edit + mobile UX, but a new
  homelab service and Hermes-access is clunkier). **Plain S3 or plain Syncthing
  alone is rejected** for the shared list — they replicate without merging, so a
  two-writer file conflicts. (S3 can still be the git *remote* if I want it.)
- **CalDAV access = `khal`/`vdirsyncer` CLI** (recommended) vs. raw `curl` vs. a
  Python `caldav` MCP server. CLI wins: no new service, handles
  timezones/ETags/`VEVENT`, fits the skill-over-terminal pattern. MCP server is
  the fallback only if I want the calendar reachable by something other than
  Hermes.
- **Whole-vault exposure (accepted).** Syncing the entire vault means Hermes can
  *read* every note, not just tasks — I chose this so it can reason over context.
  Write restraint now rests on skill rules + the append-mostly convention, not on
  folder scope. Fine as long as I'm okay with the whole vault being in the agent's
  read surface.
- **Vault git remote** — homelab-hosted (Forgejo/Gitea, keeps it in-network) vs.
  a private GitHub repo (Hermes already has `gh`/`GITHUB_TOKEN`). Lean private
  GitHub for zero new infra; homelab if I want the vault to never leave the LAN.
- **Autonomy envelope** (recommended, matches the `hermes-autofix` house rule):
  read everything; write only what I asked for; stage speculative items under
  `## Inbox`; **no** `khal delete`, **no** autonomous rescheduling, **no**
  deleting tasks. Loosen per-capability later if a specific chore proves safe.

## Risks / rollout

- **Sync conflicts** — the main hazard, now addressed by the *merge layer* (git)
  + append-mostly convention rather than one-file-per-task. Worst case is a git
  conflict on `backlog.md`, which is resolvable and non-destructive — not silent
  data loss. Back-out is trivial.
- **Vault content is not in this repo.** The plan and all nix wiring are
  version-controlled here; task/calendar data live in the vault's own git repo +
  CalDAV. Losing `204-agent` loses no source of truth — it's a peer/consumer.
- **Whole-vault read exposure** — see the decision above; the trade for
  context-awareness is that the agent's read surface is my entire vault.
- **Rollout** is additive and host-local: `deploy 204-agent`. Nothing touches the
  reverse proxy, networking, or other hosts. Back out by dropping the two
  `extraPackages`, the secret(s), and the activation scripts, then redeploy; the
  git checkout + cron job are runtime state removed by hand.
- **Credential blast radius** — `hermes-caldav` gives Hermes full calendar
  write; the git token gives full vault write. Scope both as tightly as the
  servers allow.
