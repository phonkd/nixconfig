# Two-way local chat sync

**Repo:** nixconfig **Status:** done

## Follow-up: interactive conflicts and direction
User requested device-labelled conflict choices and explicit two-way or
coordinator-to-peer-only sync. Add terminal prompts with abort as the default,
keep database session choices consistent with Codex transcripts, and retain the
existing backup/verification path. Push preserves destination-only chats and
does not change source app data or advance the shared baseline. Test both modes
and prompt choices without applying live chat data.

Implemented and verified with 28 tests. Added a fixture push that checks source
database bytes remain unchanged, destination-only sessions survive, and only the
destination gets a pre-apply backup. No live sync was run. Inspected the reported
failed run: it had comparison/staging snapshots and no local apply backup.

## Goal
Make Claude Code, Codex and OpenCode chats available on both laptop and blac,
with local backups and no overwriting of divergent conversations.

## Approach
User explicitly requested a custom sync script. Native OpenCode export/import
exists, but there is no common native two-way sync or resumable import for all
three tools. Use a standalone Python CLI over SSH/rsync, without a service or
Nix configuration change. Snapshot SQLite using its backup API; merge only
allowlisted conversation tables and files. Keep a shared baseline for three-way
comparison. Require identical home paths and compatible database schemas.
Refuse active apps, unknown database tables, and ambiguous concurrent edits.
Do not sync credentials, runtime queues, permissions or app configuration.

## Steps
- [x] Implement snapshot, conflict detection, merge, backup and restore.
- [x] Test independent histories, continued sessions, conflicts, schema drift,
      interrupted runs, credential isolation and restore using fixture homes.
- [x] Document usage and limitations; commit the scoped files locally.

## Risks / rollout
Internal schemas can change: fail closed and require adapter updates.
No distributed atomic transaction: retain a pending merged snapshot for retry
if only one side is committed. Keep dated backups until explicitly removed.
No live sync during development: this Codex session is itself a database writer.
No deploy needed for a standalone script.

## Validation / remaining operational checks
16 fixture tests pass, including subprocess worker locking/protocol, partial
application retry and restore. A read-only native snapshot validated 1,132 files
and all four databases with no foreign-key errors. No live sync was performed.
The blac SSH preflight failed locally with `Bad owner or permissions on
/home/phonkd/.ssh/config`; that unrelated configuration was left unchanged.
App resume and real two-host operation remain to be verified after apps are closed
and SSH is usable. This is a manually invoked script, not a deployed service.
