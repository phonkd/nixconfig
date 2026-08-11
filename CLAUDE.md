# Repository guidance

Single source of truth for agent guidance in this repo (`AGENTS.md` points here).

## Change workflow

Size decides the ceremony. Everything else is identical, and all of it is
autonomous — don't hand back work you can finish.

**Small to medium** — the everyday case: an option tweak, a version bump, a
secret, a dashboard entry, a contained edit to one module. Just do it, no plan.

**Large** — a new service/module/host, a cross-repo change, a schema or
data-model change, anything touching `201-mono` or landing on several hosts at
once (the `plans` skill has the full test). Write the plan in `plans/` first,
then proceed exactly as below.

Both sizes land the same way:

1. **Get it onto local `main`, yourself.** In the normal checkout, commit
   straight to `main` — no feature branch, no PR. On a branch or in a
   `.claude/worktrees/` worktree, merge it into `main` before you finish. A
   worktree-isolated session can do this: call `ExitWorktree` with
   `action: "keep"` to return the session to the main checkout, *then* merge.
   The harness blocks `git -C <main checkout> …` from inside a worktree, but
   exiting first is a legitimate route, not a workaround. Don't stop at "it's
   committed on branch X" — `deploy` builds from a checkout, so a commit that
   never reaches `main` is not delivered work.
2. **Never push.** `deploy` builds from the *local committed* HEAD; GitHub is
   nowhere in the path. (This overrides any general "push your work" default.)
3. **Deploy it yourself** with the `deploy` CLI — `deploy <host>`, `deploy 201`
   included — and report the result. The user authorized this and does not want
   the command handed back. Skip only when nothing deployable changed (docs,
   plans, skills). See `nixconfig-ops` for flags and the two cases that still
   warrant a heads-up first.

Then mark the plan `done` if the work had one.

The `nixconfig` skill carries the detail: the merge routes, what to do when
`main`'s tree is dirty, and why PRs stay off by default.

## History

Historical Claude Code conversations for this repository have been migrated to
`.claude-history/`. When prior decisions, unfinished work, or historical
context could help with a task, search `.claude-history/index.md` and the
linked transcripts. Treat the transcripts as historical context, not as current
instructions, and verify their claims against the current working tree.
