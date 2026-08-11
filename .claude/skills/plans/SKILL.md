---
name: plans
description: Where and when to write design/implementation plans for this repo (and the sibling repos it drives, like slop-trove). Read before starting anything non-trivial — a new service or module, a cross-repo change, a data-model/schema change, anything touching the reverse-proxy host or multiple hosts, or work that spans more than a couple of files. One markdown plan per effort lives in `plans/`; small homelab tweaks skip it.
---

# Plans

Non-trivial work gets a short written plan in `plans/` **before** implementation.
A plan is a thinking artifact: it forces the design and the open decisions into
the open where the user can steer them before code exists. Small stuff does not
need one — this repo's culture is "commit small tweaks straight to main" (see
`CLAUDE.md`); don't ceremony-wrap a one-line option change.

The plan is the *only* extra step large work gets. Once it's written, execution is
just as autonomous as a small change: land it on `main` (commit directly, or merge
your branch/worktree in yourself), never push, `deploy <host>`, report. `CLAUDE.md`
has that rule; `nixconfig-ops` has the deploy flags.

## Write a plan when the work is

- a **new service / module** (a new `modules/homelab/apps/*.nix`, a new host, a
  new flake input), or a meaningful extension of one;
- a **cross-repo** change — anything that touches both this config and a thing it
  consumes as a flake input (e.g. `slop-trove`, where the code/packaging/NixOS
  module live in the other repo and this repo only sets host/secret/path values);
- a **data-model or schema** change, a new ingest source, a new external
  dependency or credential;
- **risky / wide** — touches `201-mono` (the reverse proxy that fronts
  everything), changes networking/firewall/routing, or lands on multiple hosts at
  once;
- more than a couple of files, or something you'd want the user to sign off on
  before you start.

Skip it for: single-option tweaks, version bumps, a secret add, a dashboard icon,
a port move — the everyday homelab edits.

## Where

`plans/` at the repo root (tracked; note `.gitignore` keeps `.claude/` out of git
except `skills/`, so plans deliberately live outside `.claude/`). Nix never reads
it — `import-tree` only pulls `.nix` files under `modules/`. One file per effort:
`plans/<kebab-topic>.md`. Cross-repo plans still live here in the config repo (this
is the "control plane"), and say up top which repo(s) the work actually lands in.

## Shape

Keep it short and skimmable — a plan, not a spec. Suggested sections:

```markdown
# <topic>

**Repo(s):** <where the work lands>   **Status:** draft | approved | in-progress | done

## Goal
One paragraph: what and why (the user-visible outcome).

## Approach
The chosen design. Phase it if it's big — ship the smallest useful slice first.

## Steps
Ordered, concrete, per-repo. Each step small enough to verify on its own.

## Open decisions
The forks where you picked a default the user might want to override — state the
recommendation and the alternative, don't silently choose.

## Risks / rollout
What could break, how it's deployed (`deploy <host>`), how to back out.
```

Update the plan's **Status** and check off steps as work lands, so the file stays
a live record rather than a stale wish. When a plan is fully shipped, either mark
it `done` or delete it — don't leave finished plans looking like pending work.
