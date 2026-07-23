# Hermes co-managed tasks + calendar (SilverBullet)

**Repo(s):** `nixconfig`. Service + Hermes skills land on **`204-agent`**; the
traefik route registers on **`201-mono`** (same cross-host split as
`hermes.nix`). The notes/tasks live in a SilverBullet *space* (markdown files) on
`204-agent`; the calendar stays on the existing self-hosted CalDAV server.
**Status:** draft.

## Goal

Manage my calendar and tasks **together with** Hermes — equal access, not
delegation. I write detailed prose state for tasks/projects, so tasks must live
**next to my notes** (note-adjacency). I also want **one big list of every open
task** plus a **daily list** where either of us picks what fits the day. And it
has to survive an agent and me writing concurrently, from any device including
the phone.

**Why not Obsidian (the pivot):** Obsidian is a single-user editor over flat
files. Every hard thing in the earlier drafts — git merge layers, LiveSync,
sync-conflict files, append-only conventions — existed only to make *two replicas
+ dumb sync* fake a shared datastore. That's the real defect: wrong storage
model. Switching to another flat-file PKM (Logseq, Joplin, Foam) changes nothing.

**The fix: a server-authoritative notes tool — SilverBullet.** It keeps
note-adjacent markdown, but there is **one authoritative copy** (a `spaceDir` of
`.md` files on one server) that my phone (PWA), my desktop, and Hermes all talk
to — not N replicas that need merging. That single fact deletes the entire
conflict-layer question. On top of that SilverBullet gives:

- **Note-adjacency** — I write full project state in a page; tasks (`- [ ]`) live
  inline in that page with the prose around them.
- **A query/index engine** — it indexes tasks across the whole space, so "one big
  list of every open task" and "today" are **live queries**, not files I hand-
  maintain. My backlog+daily model is native, and note-adjacency stops fighting
  the one-big-list want: tasks live where they belong; the queries assemble them.
- **Trivial Hermes access** — the space is plain `.md` files *on the same host as
  Hermes* (`204-agent`). Hermes reads/writes them with the terminal toolset it
  already has — no MCP tool, no API, no replica. (`services.silverbullet` is in
  our nixpkgs: `silverbullet-2.6.1`, module `services.silverbullet` with
  `spaceDir`/`listenPort`/`listenAddress`/`envFile`.)

## Approach

### Notes + tasks (SilverBullet on `204-agent`)

1. **Run SilverBullet on `204-agent`**, colocated with Hermes, following the
   `hermes.nix` cross-host structure (not the generic `homelab-server` gate,
   because `204-agent` isn't that tag):
   - On **`reverse-proxy`** (201-mono): register `phonkds.modules.silverbullet`
     with `ip = "192.168.3.204"`, the port, a dashboard tile, and a traefik route
     (`silverbullet.w.phonkd.net`, `ipfilter = true`).
   - On **`204-agent`**: `services.silverbullet.enable = true` with
     `listenAddress = "0.0.0.0"`, a `listenPort`, `spaceDir =
     /var/lib/silverbullet/space`, and `envFile` (basic-auth creds from a sops
     secret). Add an nftables rule allowing that port from `192.168.3.201` only —
     copy the hermes-dashboard firewall pattern.
2. **Bridge the space to Hermes.** SilverBullet runs as its own user; Hermes runs
   as `hermes`. Give both read/write on `spaceDir` — simplest is to set
   `services.silverbullet.group = "hermes"` (or a shared group) and make the space
   group-writable, so Hermes edits pages directly. SilverBullet watches the space
   and re-indexes external file changes, so Hermes writing `.md` files straight to
   disk is a supported path.
3. **Task model in the space:**
   - Tasks are inline `- [ ]` items inside project/note pages, with attributes for
     scheduling (SilverBullet task attributes, e.g. a `due`/`scheduled` date or a
     `#today` tag).
   - A **`Backlog`** page holds a live query: every open task across the space.
   - A **daily page** (`Journal/YYYY-MM-DD` or a `Today` page) holds a query
     filtering tasks scheduled/due today. **Planning the day** — me or Hermes — is
     just *setting the date attribute* on backlog tasks; the day view assembles
     itself. One source of truth; the day is a lens.
4. **Propose, don't mutate.** Hermes drops new/uncertain tasks onto an **`Inbox`**
   page; I triage them into their real project pages. It may set date attributes /
   check off only tasks I explicitly asked about. Read = the whole space; write is
   governed by the skill rules below.

### Calendar (CalDAV — unchanged from the earlier draft)

1. `pkgs.khal` + `pkgs.vdirsyncer` in `services.hermes-agent.extraPackages`.
2. `vdirsyncer`/`khal` config in the hermes state dir; creds from sops secret
   `hermes-caldav` (`owner = "hermes"`, in `environmentFiles`).
3. A `caldav` skill: `vdirsyncer sync` → `khal list` to read, `khal new` to
   create, edit `.ics` + sync to push. Read unrestricted; **create/modify only for
   events I asked for; never `khal delete`, never bulk-reschedule.**

### The Hermes skill

A single **`task-notes`** skill (installed via activation script like
`mimir-alerting`/`hermes-autofix`) documents: the SilverBullet space layout, the
task syntax + date attributes, the `Backlog`/daily/`Inbox` pages, the "planning =
set a date attribute" workflow, and the read-all / stage-to-`Inbox` /
write-only-what-I-asked rule. Editing pages = plain file ops under `spaceDir`.
This is the piece I'll iterate on most — a `SKILL.md` edit, not a redeploy.

### Keeping it in step

A `hermes cron` job (`every 15m`, created once by hand like the autofix job) runs
`vdirsyncer sync` so `khal`'s view is fresh; it can also surface today's
overdue/near items. `[SILENT]` when nothing's up. This is the natural "plan my
day" entry point each morning.

## Steps

1. **`nixconfig` / new `modules/homelab/apps/silverbullet.nix`** — the cross-host
   module: traefik registration on `reverse-proxy`, `services.silverbullet` +
   firewall rule on `204-agent`, group bridge to `hermes`. Model on `hermes.nix`.
2. **`nixconfig` / `204-agent.nix`** — `pkgs.khal` + `pkgs.vdirsyncer` to
   `extraPackages`; sops secrets `hermes-caldav` and `silverbullet-auth`
   (`owner`/env as needed); append caldav secret to `environmentFiles`. Add both
   secrets to `secret.yaml`.
3. **`nixconfig`** — activation scripts writing the `vdirsyncer`/`khal` config +
   the `caldav` and `task-notes` `SKILL.md` files into the hermes state dir.
4. **Deploy** `deploy 204-agent` (and `deploy 201-mono` for the traefik route).
5. **Runtime (one-time)** — `vdirsyncer discover`/first sync; seed the SilverBullet
   space with `Backlog`, `Today`, `Inbox` pages + their queries; create the
   `hermes cron` job; log into the SilverBullet PWA on my phone/desktop.
6. **Verify** — `khal list` shows real events; I add a task in a note on the phone
   and it appears in the `Backlog` query; Hermes sets a `due:today` on one and it
   shows on the daily page; Hermes and I edit the same page seconds apart and the
   server reconciles to one page — **no `.sync-conflict` file anywhere**.

## Open decisions

Defaults picked; say if you'd override:

- **Notes tool = SilverBullet** (recommended) vs. Trilium/TriliumNext (server DB +
  REST API, but not markdown and tasks aren't first-class) vs. staying on Obsidian
  with LiveSync/CouchDB (keeps the editor, but Hermes access is clunkier and it's
  a heavier service). SilverBullet uniquely gives markdown note-adjacency + a task
  query engine + plain-file Hermes access on one authoritative store.
- **Host placement = `204-agent`, colocated with Hermes** (recommended) — gives
  Hermes direct filesystem access to the space. Alternative: run it on a
  `homelab-server` host and have Hermes reach it over the HTTP API — cleaner tag
  fit, but loses the plain-file access that makes the skill trivial.
- **Hermes edit path = direct file ops on `spaceDir`** (recommended; SilverBullet
  re-indexes external changes) vs. the SilverBullet **HTTP API**. Direct files is
  simplest; switch to the API only if we ever see a race writing the same page.
- **CalDAV access = `khal`/`vdirsyncer` CLI** (recommended) vs. raw `curl` vs. a
  `caldav` MCP server — unchanged rationale.
- **Whole-space read exposure (accepted)** — Hermes can read every page, chosen so
  it has project context. Write restraint rests on the skill rules + `Inbox`
  staging.
- **Autonomy envelope** (matches the `hermes-autofix` house rule): read
  everything; write only what I asked; stage speculative items to `Inbox`; **no**
  `khal delete`, **no** autonomous rescheduling, **no** deleting tasks.

## Risks / rollout

- **Concurrent edits** — the whole reason for SilverBullet. One authoritative
  on-disk space + a re-indexing server means there's no two-replica merge and no
  `.sync-conflict` files. Residual surface: Hermes and a client writing the *exact
  same page* in the same instant is last-write on one store (not a fork); the
  `Inbox`-staging + set-attributes-not-reorder convention keeps even that near
  zero. Far smaller than the Obsidian model.
- **Space is not in this repo.** The plan + nix wiring are versioned here; the
  notes/tasks live in the SilverBullet space, the calendar in CalDAV. Both are
  worth their own backup (a periodic `git`/`restic` snapshot of `spaceDir`) since
  they're now a primary source of truth on `204-agent`, not just a replica.
- **Whole-space read exposure** — see the decision above.
- **Permissions bridge** — silverbullet-user vs hermes-user access to `spaceDir`
  is the one fiddly bit; get the shared group + group-writable dir right or Hermes
  can't write.
- **Rollout** is additive: `deploy 204-agent` + `deploy 201-mono`. Nothing else on
  the reverse proxy changes beyond one route. Back out by removing the
  silverbullet module, the two `extraPackages`, the secrets, and the activation
  scripts, then redeploy; the space dir + cron job are runtime state removed by
  hand.
- **Credential blast radius** — `hermes-caldav` = full calendar write;
  SilverBullet basic-auth guards the notes. Scope each as tightly as the servers
  allow; the traefik `ipfilter` already gates network reach.
