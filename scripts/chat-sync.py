#!/usr/bin/env python3
"""Conservative, offline, two-way Claude/Codex/OpenCode chat sync. See docs/chat-sync.md."""

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone


TREES = (
    '.claude/projects', '.claude/file-history', '.claude/plans',
    '.claude/paste-cache', '.claude/uploads',
    '.codex/sessions', '.codex/archived_sessions',
    '.local/share/opencode/storage', '.local/share/opencode/tool-output',
    '.local/share/opencode/snapshot',
)
FILES = ('.claude/history.jsonl', '.codex/history.jsonl', '.codex/session_index.jsonl')
CODEX_STATE = set('threads thread_dynamic_tools thread_spawn_edges thread_sections projects '
                  'project_roots project_idempotency_keys thread_attachments guardian_review_feedback'.split())
CODEX_HISTORY = set('thread_turns thread_items thread_history_projection_state thread_realtime_items'.split())
OPENCODE = set('project project_directory message part session todo event_sequence event workspace '
               'session_message session_v2 instruction_blob instruction_entry instruction_state worktree'.split())
SKIP = set('_sqlx_migrations sqlite_sequence backfill_state remote_control_enrollments '
           'external_agent_config_imports rollout_migration_state rollout_migration_skipped_rollouts '
           'thread_read_receipts __drizzle_migrations account account_state control_account credential '
           'permission session_share migration kv session_pending session_inbox data_migration'.split())
MIGRATIONS = {'_sqlx_migrations', '__drizzle_migrations', 'migration', 'data_migration'}
DATABASES = {
    '.codex/state_5.sqlite': CODEX_STATE,
    '.codex/thread_history_1.sqlite': CODEX_HISTORY,
    '.local/share/opencode/opencode.db': OPENCODE,
    '.local/share/opencode/opencode-stable.db': OPENCODE,
}


class SyncError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.chat-sync-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_path(root, rel):
    rel = Path(rel)
    if rel.is_absolute() or '..' in rel.parts:
        raise SyncError('Unsafe relative path')
    path = root
    for part in rel.parts:
        path /= part
        if path.is_symlink():
            raise SyncError(f'Symlink not supported: {path}')
    return path


def allowed_file(rel):
    return rel in FILES or any(rel.startswith(tree + '/') for tree in TREES)


def check_idle():
    """Linux /proc check: include daemons and Electron/app-server processes."""
    if not Path('/proc').is_dir():
        raise SyncError('This version supports Linux only (requires /proc writer checks).')
    active = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            comm = (entry / 'comm').read_text().strip().lower()
            args = (entry / 'cmdline').read_bytes().split(b'\0')
            # Inspect executable/script positions, not shell command strings or prompts.
            names = [Path(os.fsdecode(arg)).name.lower() for arg in args[:3]]
            if (any(comm.startswith(x) for x in ('codex', 'claude', 'opencode')) or
                    any(n in ('codex', 'claude', 'opencode', 'codex-app-server') or
                        n.startswith(('codex-', 'opencode-')) for n in names)):
                active.append(entry.name)
        except (FileNotFoundError, ProcessLookupError):
            continue
    if active:
        raise SyncError('Close Claude Code, Codex and OpenCode, including daemons; active PIDs: ' + ', '.join(active))


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def connect(path):
    return sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)


def schema(db):
    return list(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master "
                           "WHERE sql IS NOT NULL ORDER BY type,name"))


def tables(db):
    return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def validate_db(db, rel):
    unknown = tables(db) - DATABASES[rel] - SKIP
    if unknown:
        raise SyncError(f'{rel}: unsupported tables: {", ".join(sorted(unknown))}; update adapter first')
    if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise SyncError(f'{rel}: SQLite integrity check failed')
    if 'event' in tables(db):
        kinds = [row[0] for row in db.execute('SELECT DISTINCT type FROM event')]
        if any(not str(kind).startswith(('session.', 'message.', 'part.', 'project.')) for kind in kinds):
            raise SyncError(f'{rel}: unsupported event types; review adapter before transferring event data')


def copy_db(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(connect(source)) as src, contextlib.closing(sqlite3.connect(target)) as dst:
        src.backup(dst)


def rowmap(db, table):
    cols = list(db.execute(f'PRAGMA table_info({quote(table)})'))
    pk = [r[0] for r in sorted(cols, key=lambda r: r[5]) if r[5]]
    if not pk:
        raise SyncError(f'{table}: missing primary key')
    return {tuple(row[i] for i in pk): tuple(row)
            for row in db.execute(f'SELECT * FROM {quote(table)}')}


def db_digest(path, rel):
    with contextlib.closing(connect(path)) as db:
        h = hashlib.sha256(repr(schema(db)).encode())
        for table in sorted(tables(db) & DATABASES[rel]):
            for key, row in sorted(rowmap(db, table).items(), key=lambda x: repr(x[0])):
                h.update(repr((table, key, row)).encode())
        return h.hexdigest()


def snapshot(home, dest, *, private=False):
    dest.mkdir(parents=True, exist_ok=True)
    manifest = {'home': str(home), 'files': {}, 'databases': {}}
    candidates = [safe_path(home, name) for name in FILES]
    for tree in TREES:
        root = safe_path(home, tree)
        if root.exists():
            for path in root.rglob('*'):
                safe_path(home, path.relative_to(home))
                if path.is_file():
                    candidates.append(path)
    for path in sorted(candidates):
        if not path.exists():
            continue
        rel = str(path.relative_to(home))
        target = safe_path(dest, rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        manifest['files'][rel] = digest(target.read_bytes())
    # Do not silently miss a future database version or a non-default data root.
    for pattern in ('.codex/state_*.sqlite', '.codex/thread_history_*.sqlite', '.local/share/opencode/*.db'):
        for path in home.glob(pattern):
            if str(path.relative_to(home)) not in DATABASES:
                raise SyncError(f'Unsupported chat database: {path}')
    for rel in DATABASES:
        src = safe_path(home, rel)
        if not src.exists():
            continue
        dst = safe_path(dest, rel)
        copy_db(src, dst)
        with contextlib.closing(sqlite3.connect(dst)) as db:
            validate_db(db, rel)
            if not private:
                # Full backups stay on their own host. Export contains no account tables.
                for table in tables(db) - DATABASES[rel] - MIGRATIONS - {'sqlite_sequence'}:
                    db.execute(f'DELETE FROM {quote(table)}')
                db.commit()
                db.execute('VACUUM')
            db.execute('PRAGMA journal_mode=DELETE')
        manifest['databases'][rel] = db_digest(dst, rel)
    atomic(dest / 'manifest.json', json_bytes(manifest))
    return manifest


def read_manifest(root):
    return json.loads((root / 'manifest.json').read_text())


def choose(a, b, base, label):
    # Absence is never a deletion request. Deleted chats are restored by sync.
    if a == b or b is None:
        return a
    if a is None:
        return b
    if base is not None:
        if a == base:
            return b
        if b == base:
            return a
    raise SyncError(f'Conflict: {label}. Neither copy was overwritten; inspect the saved snapshots.')


def merge_file(rel, a, b, base):
    if a == b or a is None or b is None:
        return choose(a, b, base, rel)
    if rel in ('.claude/history.jsonl', '.codex/history.jsonl'):
        # Prompt recall is a set of independent records, not conversation order.
        records = {}
        for line in (a + b'\n' + b).splitlines():
            if line.strip():
                value = json.loads(line)
                records[json_bytes(value)] = value
        return b''.join(key + b'\n' for key in sorted(records))
    if rel == '.codex/session_index.jsonl':
        # The index is append-only: keep the newest entry for each thread ID.
        entries = {}
        for line in (a + b'\n' + b).splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            key = obj['id']
            old = entries.get(key)
            if old is None or (str(obj.get('updated_at', '')), json_bytes(obj)) > (str(old.get('updated_at', '')), json_bytes(old)):
                entries[key] = obj
        return b''.join(json_bytes(entries[key]) + b'\n' for key in sorted(entries))
    if rel.endswith('.jsonl'):
        # Accept an unambiguous continuation, never concatenate divergent turns.
        if a.endswith(b'\n') and b.startswith(a):
            return b
        if b.endswith(b'\n') and a.startswith(b):
            return a
    return choose(a, b, base, rel)


def conversation_groups(db, rel):
    """Detect edits to the same session even when they touch different rows."""
    groups = {}
    for table in sorted(tables(db) & DATABASES[rel]):
        cols = [r[1] for r in db.execute(f'PRAGMA table_info({quote(table)})')]
        col = next((c for c in ('thread_id', 'session_id', 'aggregate_id') if c in cols), None)
        if table in ('threads', 'session', 'session_v2'):
            col = 'id'
        if col is None:
            continue
        for key, row in rowmap(db, table).items():
            groups.setdefault(row[cols.index(col)], []).append((table, key, row))
    return {key: digest(repr(sorted(value, key=repr)).encode()) for key, value in groups.items()}


def row_group(db, table, row):
    cols = [r[1] for r in db.execute(f'PRAGMA table_info({quote(table)})')]
    col = next((c for c in ('thread_id', 'session_id', 'aggregate_id') if c in cols), None)
    if table in ('threads', 'session', 'session_v2'):
        col = 'id'
    return row[cols.index(col)] if col else None


def project_metadata(db, table, left, right):
    """Shared Git project IDs have host-specific timestamps, even for unrelated chats."""
    cols = [r[1] for r in db.execute(f'PRAGMA table_info({quote(table)})')]
    timestamp = next((c for c in ('updated_at_ms', 'time_updated') if c in cols), None)
    rank = lambda row: ((row[cols.index(timestamp)] or 0) if timestamp else 0, repr(row))
    result = list(max((left, right), key=rank))
    if 'sandboxes' in cols:
        i = cols.index('sandboxes')
        values = [json.loads(row[i]) for row in (left, right)]
        if not all(isinstance(value, list) and all(isinstance(p, str) for p in value) for value in values):
            raise SyncError('Unexpected OpenCode project sandboxes format')
        result[i] = json.dumps(sorted(set(values[0] + values[1])), separators=(',', ':'))
    return tuple(result)


def merge_db(a, b, base, out, rel):
    present = [p for p in (a, b) if p is not None]
    shutil.copyfile(present[0], out)
    if len(present) == 1:
        return
    with contextlib.ExitStack() as stack:
        left, right = [stack.enter_context(contextlib.closing(connect(p))) for p in (a, b)]
        old = stack.enter_context(contextlib.closing(connect(base))) if base else None
        if schema(left) != schema(right) or (old and schema(old) != schema(left)):
            raise SyncError(f'{rel}: schema mismatch; use matching app versions on both hosts')
        ga, gb = conversation_groups(left, rel), conversation_groups(right, rel)
        gc = conversation_groups(old, rel) if old else {}
        winners = {}
        for key in ga.keys() & gb.keys():
            winner = choose(ga[key], gb[key], gc.get(key), f'{rel}: session {key}')
            winners[key] = 'left' if winner == ga[key] else 'right'
        dst = stack.enter_context(contextlib.closing(sqlite3.connect(out)))
        for table in sorted(tables(left) & DATABASES[rel]):
            ra, rb = rowmap(left, table), rowmap(right, table)
            rc = rowmap(old, table) if old else {}
            merged = []
            for key in sorted(ra.keys() | rb.keys(), key=repr):
                group = row_group(left, table, ra.get(key, rb.get(key)))
                winner = winners.get(group)
                if winner:
                    row = (ra if winner == 'left' else rb).get(key)
                elif table in ('project', 'projects') and key in ra and key in rb and ra[key] != rb[key]:
                    row = project_metadata(left, table, ra[key], rb[key])
                else:
                    row = choose(ra.get(key), rb.get(key), rc.get(key), f'{rel}: {table} key {key}')
                if row is not None:
                    merged.append(row)
            dst.execute(f'DELETE FROM {quote(table)}')
            if merged:
                dst.executemany(f'INSERT INTO {quote(table)} VALUES ({",".join("?" for _ in merged[0])})', merged)
        dst.commit()
        if list(dst.execute('PRAGMA foreign_key_check')):
            raise SyncError(f'{rel}: merged data has invalid foreign keys')
        validate_db(dst, rel)


def merge(left, right, baseline, output):
    ma, mb = read_manifest(left), read_manifest(right)
    mc = read_manifest(baseline) if (baseline / 'manifest.json').exists() else {'files': {}, 'databases': {}}
    if ma['home'] != mb['home']:
        raise SyncError('Home paths differ; move projects to matching absolute paths before syncing.')
    output.mkdir(parents=True, exist_ok=True)
    result = {'home': ma['home'], 'files': {}, 'databases': {}}
    for rel in sorted(ma['files'].keys() | mb['files'].keys()):
        values = [(safe_path(root, rel).read_bytes() if rel in manifest['files'] else None)
                  for root, manifest in ((left, ma), (right, mb), (baseline, mc))]
        data = merge_file(rel, *values)
        atomic(safe_path(output, rel), data)
        result['files'][rel] = digest(data)
    for rel in sorted(ma['databases'].keys() | mb['databases'].keys()):
        paths = [(safe_path(root, rel) if rel in manifest['databases'] else None)
                 for root, manifest in ((left, ma), (right, mb), (baseline, mc))]
        dst = safe_path(output, rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        merge_db(*paths, dst, rel)
        result['databases'][rel] = db_digest(dst, rel)
    atomic(output / 'manifest.json', json_bytes(result))
    return result


def apply_snapshot(home, source, expected, backup, *, restore=False):
    check_idle()
    with tempfile.TemporaryDirectory(prefix='chat-sync-check-', dir=backup.parent) as tmp:
        current = snapshot(home, Path(tmp))
    if current != expected:
        raise SyncError('Data changed since snapshot; refusing to write. Close all apps and retry.')
    target = read_manifest(source)
    if target['home'] != str(home):
        raise SyncError('Snapshot belongs to a different home path')
    # Validate every input before making any changes; stage databases retaining local-only rows.
    staged = backup.parent / (backup.name + '-staged')
    staged.mkdir()
    for rel, checksum in target['files'].items():
        if not allowed_file(rel) or digest(safe_path(source, rel).read_bytes()) != checksum:
            raise SyncError(f'Invalid file snapshot: {rel}')
        safe_path(home, rel)
    for rel, checksum in target['databases'].items():
        if rel not in DATABASES or db_digest(safe_path(source, rel), rel) != checksum:
            raise SyncError(f'Invalid database snapshot: {rel}')
        live = safe_path(home, rel)
        dst = safe_path(staged, rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not live.exists() or restore:
            copy_db(source / rel, dst)
        else:
            copy_db(live, dst)
            with contextlib.closing(sqlite3.connect(dst)) as db, contextlib.closing(connect(source / rel)) as src:
                if schema(db) != schema(src):
                    raise SyncError(f'{rel}: schema changed before apply')
                for table in sorted(tables(db) & DATABASES[rel]):
                    db.execute(f'DELETE FROM {quote(table)}')
                    rows = list(src.execute(f'SELECT * FROM {quote(table)}'))
                    if rows:
                        db.executemany(f'INSERT INTO {quote(table)} VALUES ({",".join("?" for _ in rows[0])})', rows)
                db.commit()
        with contextlib.closing(sqlite3.connect(dst)) as db:
            validate_db(db, rel)
            if list(db.execute('PRAGMA foreign_key_check')):
                raise SyncError(f'{rel}: invalid foreign keys before apply')
            db.execute('PRAGMA journal_mode=DELETE')
    snapshot(home, backup, private=True)
    # No writes if a user restarted an app during staging/backup.
    check_idle()
    with tempfile.TemporaryDirectory(prefix='chat-sync-recheck-', dir=backup.parent) as tmp:
        if snapshot(home, Path(tmp)) != current:
            raise SyncError('Data changed during backup; refusing to write')
    # File-level atomic replacement. An interruption may leave a partial application;
    # backups and the merged snapshot remain available for a safe retry/restore.
    for rel in target['files']:
        atomic(safe_path(home, rel), (source / rel).read_bytes())
    for rel in target['databases']:
        live = safe_path(home, rel)
        live.parent.mkdir(parents=True, exist_ok=True)
        for suffix in ('-wal', '-shm', '-journal'):
            sidecar = safe_path(home, rel + suffix)
            sidecar.unlink(missing_ok=True)
        os.replace(staged / rel, live)
    if restore:
        for rel in current['files'].keys() - target['files'].keys():
            safe_path(home, rel).unlink()
        for rel in current['databases'].keys() - target['databases'].keys():
            safe_path(home, rel).unlink()
    shutil.rmtree(staged)


class Endpoint:
    def __init__(self, home):
        self.home = home.resolve()
        for variable, default in (('CODEX_HOME', self.home / '.codex'),
                                  ('CLAUDE_CONFIG_DIR', self.home / '.claude'),
                                  ('XDG_DATA_HOME', self.home / '.local/share')):
            if os.environ.get(variable) and Path(os.environ[variable]).resolve() != default:
                raise SyncError(f'Non-default {variable} is not supported')
        self.state = safe_path(self.home, '.local/state/chat-sync')
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state.chmod(0o700)
        self.lock = open(self.state / 'lock', 'a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise SyncError('Another chat-sync process holds the lock') from None
        self.run = self.state / 'runs' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
        self.run.mkdir(parents=True)

    def call(self, command, **args):
        if command == 'info':
            check_idle()
            return {'home': str(self.home), 'run': str(self.run)}
        if command == 'snapshot':
            check_idle()
            self.before = snapshot(self.home, self.run / 'before')
            return self.before
        if command == 'apply':
            backup = self.state / 'backups' / self.run.name
            backup.parent.mkdir(parents=True, exist_ok=True)
            apply_snapshot(self.home, self.run / 'merged', self.before, backup)
            return str(backup)
        if command == 'verify':
            check_idle()
            return snapshot(self.home, self.run / 'after')
        raise SyncError('Unknown worker command')

    def close(self):
        self.lock.close()


class Remote:
    def __init__(self, peer):
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', peer):
            raise SyncError('Use an SSH host alias, optionally user@host')
        self.peer = peer
        source = base64.b64encode(Path(__file__).read_bytes()).decode()
        bootstrap = "import base64;exec(compile(base64.b64decode(" + repr(source) + "),'chat-sync.py','exec'))"
        command = shlex.join(['python3', '-c', bootstrap, '--worker'])
        self.proc = subprocess.Popen(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', peer, command],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def call(self, command, **args):
        self.proc.stdin.write(json.dumps({'command': command, **args}) + '\n')
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise SyncError('SSH worker disconnected; snapshots/backups retained. Retry with apps closed.')
        result = json.loads(line)
        if 'error' in result:
            raise SyncError('Peer: ' + result['error'])
        return result['result']

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=10)


def transfer(source, destination):
    subprocess.run(['rsync', '-rlt', '--protect-args', '--', source + '/', destination + '/'], check=True)


def sync(peer, dry_run):
    local = Endpoint(Path.home())
    remote = None
    try:
        li = local.call('info')
        remote = Remote(peer)
        ri = remote.call('info')
        if li['home'] != ri['home']:
            raise SyncError('Both machines must use the same absolute home/project paths')
        peer_file = local.state / 'peer.json'
        identity = {'peer': peer, 'home': ri['home']}
        if peer_file.exists() and json.loads(peer_file.read_text()) != identity:
            raise SyncError('This coordinator is paired with another peer; use its existing SSH alias')
        local.call('snapshot')
        remote.call('snapshot')
        transfer(peer + ':' + ri['run'] + '/before', str(local.run / 'remote'))
        baseline = local.state / 'baseline'
        previous = local.state / 'baseline.previous'
        # Recover a crash between the two atomic baseline renames.
        if not baseline.exists() and previous.exists():
            previous.rename(baseline)
        result = merge(local.run / 'before', local.run / 'remote', baseline, local.run / 'merged')
        print(f'Merged {len(result["files"])} files and {len(result["databases"])} databases.')
        print(f'Review snapshots: {local.run}')
        if dry_run:
            print('Dry run: no app data changed. Snapshots retained; they contain private chats.')
            return
        transfer(str(local.run / 'merged'), peer + ':' + ri['run'] + '/merged')
        # Apply peer first; a network failure never advances the coordinator baseline.
        print('Peer backup:', remote.call('apply'))
        print('Local backup:', local.call('apply'))
        if remote.call('verify') != result or local.call('verify') != result:
            raise SyncError('Post-sync verification failed; baseline not advanced. Backups retained.')
        next_baseline = local.state / 'baseline.next'
        if next_baseline.exists():
            shutil.rmtree(next_baseline)
        shutil.copytree(local.run / 'merged', next_baseline)
        if previous.exists():
            shutil.rmtree(previous)
        if baseline.exists():
            baseline.rename(previous)
        next_baseline.rename(baseline)
        atomic(peer_file, json_bytes(identity))
        print('Verified: both hosts have the same selected chat data.')
    finally:
        if remote:
            remote.close()
        local.close()


def worker():
    endpoint = Endpoint(Path.home())
    try:
        for line in sys.stdin:
            try:
                result = endpoint.call(**json.loads(line))
                response = {'result': result}
            except Exception as exc:
                response = {'error': str(exc)}
            print(json.dumps(response), flush=True)
    finally:
        endpoint.close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command')
    sp = sub.add_parser('sync', help='Two-way sync; run from the same coordinator each time')
    sp.add_argument('peer', nargs='?', default='blac')
    sp.add_argument('--dry-run', action='store_true', help='Snapshot and merge without changing app data')
    sub.add_parser('backups', help='List local pre-sync backups')
    rp = sub.add_parser('restore', help='Restore local chat data; back up the current state first')
    rp.add_argument('backup', help='Backup directory printed by sync/backups')
    args = parser.parse_args()
    try:
        if args.worker:
            worker()
        elif args.command == 'sync':
            sync(args.peer, args.dry_run)
        elif args.command == 'backups':
            for path in sorted((Path.home() / '.local/state/chat-sync/backups').glob('*/manifest.json')):
                print(path.parent)
        elif args.command == 'restore':
            endpoint = Endpoint(Path.home())
            try:
                source = Path(args.backup).expanduser().resolve()
                if source.parent != endpoint.state / 'backups':
                    raise SyncError('Restore accepts only a local backup from this script')
                endpoint.call('info')
                before = endpoint.call('snapshot')
                backup = endpoint.state / 'backups' / endpoint.run.name
                apply_snapshot(endpoint.home, source, before, backup, restore=True)
                if endpoint.call('verify') != read_manifest(source):
                    raise SyncError('Restore verification failed; pre-restore backup retained')
                print(f'Restored. Pre-restore backup: {backup}')
                print('Restore is local; the next sync may bring back chats from the other machine.')
            finally:
                endpoint.close()
        else:
            parser.print_help()
    except (SyncError, OSError, sqlite3.Error, ValueError, subprocess.SubprocessError) as exc:
        print(f'chat-sync: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
