# Sync local coding-agent chats between laptop and blac

`scripts/chat-sync.py` merges Claude Code and Codex chat data over SSH.
It is an **offline sync**, run manually from the laptop each time. By default,
both machines receive the merged history; `--direction push` updates only blac.
It does not sync your Git repositories;
copy those separately, preserving their absolute paths.

## Requirements

- Linux, Python 3 with SQLite support, SSH and rsync on both machines.
- The same home path (`/home/phonkd`) and project paths on both machines.
- Matching database schemas: use the same versions of each app on both machines.
- Default data locations. Custom `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are rejected when visible to the script.
- Stop **Claude Code and Codex, including their daemons, on both machines** before syncing.
  Keep them closed until verification finishes. The script checks processes and
  rechecks snapshot fingerprints, but cannot prevent an app from being restarted.
- Working noninteractive SSH: `ssh -o BatchMode=yes blac true`.

There is no Nix rebuild or remote script installation. The coordinator sends its
own worker code to Python over SSH. Existing SSH configuration is respected.

## Use

From this checkout on the laptop:

```bash
# Preview: creates private snapshots but does not change app data.
python3 scripts/chat-sync.py sync blac --dry-run

# Merge both ways, back up each host, apply and verify.
python3 scripts/chat-sync.py sync blac

# Explicitly update both machines (the default).
python3 scripts/chat-sync.py sync blac --direction both

# z14 -> blac only. z14's app data stays unchanged; blac-only chats stay on blac.
python3 scripts/chat-sync.py sync blac --direction push

# Same push, automatically keeping z14's version of every conflict.
python3 scripts/chat-sync.py sync blac --direction push --prefer-local

# List backups on this machine.
python3 scripts/chat-sync.py backups

# Restore a named local backup, saving the current state first.
python3 scripts/chat-sync.py restore ~/.local/state/chat-sync/backups/TIMESTAMP-ID
```

You can use `phonkd@blac` or an SSH alias instead of `blac`, but keep using the
same alias. Keep the laptop as coordinator; its baseline records the last
successful two-way sync. Push does not advance that shared baseline. Both modes
download a comparison snapshot under `~/.local/state/chat-sync/runs/`; this does
not install blac's history into z14's apps. Push applies the merged result only on
blac, retaining its existing independent chats. To initiate from blac, SSH into the laptop and run the command
there. The worker lock prevents overlapping syncs on either endpoint.

Afterward, open the relevant project and use `claude --resume` or
`codex resume --all`. Logging in remains separate.
The script does not start the apps or send any prompts.

## Data included

| App | Included |
| --- | --- |
| Claude Code | `projects/` (transcripts, subagents, tool results and project memory), `file-history/`, `plans/`, `paste-cache/`, `uploads/`, `history.jsonl` |
| Codex | `sessions/`, `archived_sessions/`, prompt history, session index, conversation/project tables in `state_5.sqlite`, and `thread_history_1.sqlite` |

OpenCode is excluded entirely: its databases, Git snapshot cache, tool outputs and
legacy storage are not read, transferred, merged or restored. Existing OpenCode
files and old backups remain untouched. OpenCode entries in older sync manifests
are ignored, so no cleanup or baseline reset is needed. OpenCode can remain running.

Runtime jobs, authentication tables, remote-control enrollments, permissions and
app configuration are not exchanged. Codex's separate generated memory database
is not synced.

For a schema mismatch, the error lists differing tables and columns. Install the
same app versions on both hosts and open each app normally so its own migrations
run, then close both before retrying. The sync script does not perform app schema
migrations or drop legacy tables. If native migration leaves different schemas,
keep the error details for an adapter update; do not delete a database to match it.

Referenced files outside these locations (repositories, OS temporary attachments,
external images) must be transferred separately. Symlinks in selected data paths
are rejected rather than followed. Internal database schemas
can change; unrecognised tables and database versions stop the run.

## Merge and conflict behaviour

- New sessions from either side are added to both machines.
- After the first sync, a session changed on only one side replaces that session's
  old data on the other side. Related row removals within that session follow it.
- If both sides changed the same database session differently, the terminal asks
  which device's session version to keep. It never interleaves the two branches.
- On the first sync there is no baseline: different versions of an overlapping
  database session also prompt for a choice. Identical sessions and independent sessions
  merge normally. There is intentionally no automatic "latest timestamp wins".
- A JSONL transcript that strictly extends the other copy is accepted. Other file
  changes use the baseline; incompatible changes prompt for a choice.
- Prompt-recall history is unioned; Codex's display-name index keeps the most recent
  entry per thread. Display metadata is not the conversation itself.
- Shared project metadata keeps the newest project record.
- Deleting a whole chat or file on one machine **does not delete it on the other**;
  syncing can bring it back. This is history preservation, not deletion mirroring.

On conflict, the prompt names the file/session, both device hostnames, and the
original snapshot locations. Choose `1` for local (z14), `2` for peer (blac),
`l`/`r` to keep that device for all remaining conflicts, or `q`/Enter to abort.
Choosing one version replaces the other version of that conflicting item on the
hosts being updated; independent chats are kept. Choices are saved in
`conflict-choices.json` in that run directory. Codex transcript and database
choices for a session are tied together; staging restarts if necessary so a late
database choice also applies to its transcript.

Nothing is applied until all conflicts have been resolved and the merge has
validated. Aborting leaves app data unchanged. Without an interactive terminal,
unresolved conflicts stop the run. Dry runs also ask for conflict choices, but
do not apply them. Both original snapshots remain available, and the pre-apply
backups retain any replaced data. Schema mismatches still stop the run; choosing
a device cannot safely resolve a difference in database format.

`--prefer-local` preselects local for every conflict, including in a noninteractive
terminal. It applies in either direction mode. It does not delete peer-only chats,
override schema checks, or replace a non-conflicting continuation just because it
was written on the peer. OpenCode is excluded regardless of this option.

After an app upgrade, both schemas must match. If the saved baseline uses an old
schema, the script also stops rather than guessing a migration. Keep its backup
and update the adapter/baseline deliberately before resuming sync.

## Backups, interrupted runs and restore

Each host retains its own pre-write backup at:

```text
~/.local/state/chat-sync/backups/<UTC timestamp>-<id>/
```

Backups contain the selected files and **complete original SQLite databases**,
including that host's local authentication rows. They stay on that host. Exchanged
snapshots have excluded table contents removed and the database vacuumed. Chat
text itself can contain secrets; treat snapshots and backups as private.

The worker takes SQLite snapshots using the backup API, so WAL contents are
included. It stages merged databases while preserving destination-only tables,
validates integrity and foreign keys, backs up the originals, then replaces files
atomically. The entire multi-file/multi-host operation is **not** atomic.

If a connection drops after one host applied, leave apps closed and retry from
the laptop. The baseline advances only after both hosts verify equal. A repeated
run can converge from a partial application; if it reports a conflict, use the
retained snapshots/backups rather than discarding either copy.

Restore affects only the host on which it runs, removes selected files/databases
added after that backup, and restores that host's full database images. It creates
a new pre-restore backup and verifies the restored chat data. To restore blac,
copy this script there and run `restore` there. Stop the apps first. The next sync
can reintroduce chats retained on the other host.

Backups and run snapshots have **no automatic expiry**. Large histories use
substantial disk space. After a verified sync and an appropriate retention period,
you can remove old directories under `runs/` and `backups/`. Keep `baseline/` and
`peer.json`; `baseline.previous/` is the previous successful baseline.

## Validation

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p test_chat_sync.py -v
```

Tests use temporary homes and exercise merge, continuation, conflicts, schema
drift, credential isolation, changed-source rejection, partial-sync retry,
restore, symlink rejection and the subprocess worker protocol. A read-only
snapshot of the laptop's native data was also validated during implementation.
No live two-host sync or app resume has been claimed as tested.
