"""Run: python3 -m unittest discover -s scripts -p 'test_chat_sync.py' -v"""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('chat_sync', Path(__file__).with_name('chat-sync.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
REL = '.codex/state_5.sqlite'
OC = '.local/share/opencode/opencode.db'


class ChatSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.a = self.root / 'a'
        self.b = self.root / 'b'
        self.a.mkdir()
        self.b.mkdir()
        self.idle = patch.object(sync, 'check_idle')
        self.idle.start()
        self.addCleanup(self.idle.stop)
        self.addCleanup(self.tmp.cleanup)
        env_patch = patch.dict(os.environ)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        for key in ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'XDG_DATA_HOME'):
            os.environ.pop(key, None)

    def db(self, home, rows=(), secret='local', rel=REL):
        path = home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(path) as db:
            if rel == REL:
                db.executescript('''CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT);
                    CREATE TABLE thread_dynamic_tools(thread_id TEXT, position INTEGER, name TEXT,
                    PRIMARY KEY(thread_id,position), FOREIGN KEY(thread_id) REFERENCES threads(id));
                    CREATE TABLE remote_control_enrollments(id TEXT PRIMARY KEY, token TEXT);''')
                db.executemany('INSERT INTO threads VALUES (?,?)', rows)
                db.execute('INSERT INTO remote_control_enrollments VALUES (?,?)', ('auth', secret))
            else:
                db.executescript('''CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT);
                    CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, data TEXT,
                    FOREIGN KEY(session_id) REFERENCES session(id));
                    CREATE TABLE account(id TEXT PRIMARY KEY, access_token TEXT);''')
                db.executemany('INSERT INTO session VALUES (?,?)', rows)
                db.execute('INSERT INTO account VALUES (?,?)', ('auth', secret))
        return path

    def snap(self, home, name):
        dest = self.root / name
        sync.snapshot(home, dest)
        # Unit fixtures represent identical home paths on two distinct hosts.
        m = sync.read_manifest(dest)
        m['home'] = '/home/test'
        sync.atomic(dest / 'manifest.json', sync.json_bytes(m))
        return dest

    def merged(self, left, right, baseline=None, name='merged'):
        out = self.root / name
        sync.merge(left, right, baseline or self.root / 'absent', out)
        return out

    def rows(self, root, table='threads', rel=REL):
        with contextlib.closing(sync.connect(root / rel)) as db:
            return list(db.execute(f'SELECT * FROM {sync.quote(table)} ORDER BY 1'))

    def apply(self, home, source, name='backup'):
        manifest = sync.read_manifest(source)
        manifest['home'] = str(home)
        sync.atomic(source / 'manifest.json', sync.json_bytes(manifest))
        before = sync.snapshot(home, self.root / (name + '-before'))
        sync.apply_snapshot(home, source, before, self.root / name)

    def test_independent_histories_merge_and_credentials_stay_local(self):
        self.db(self.a, [('a', 'laptop')], 'SECRET_A')
        self.db(self.b, [('b', 'desktop')], 'SECRET_B')
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        self.assertEqual(self.rows(left, 'remote_control_enrollments'), [])
        self.assertNotIn(b'SECRET_A', (left / REL).read_bytes())
        out = self.merged(left, right)
        self.apply(self.a, out)
        self.assertEqual(self.rows(self.a), [('a', 'laptop'), ('b', 'desktop')])
        self.assertEqual(self.rows(self.a, 'remote_control_enrollments'), [('auth', 'SECRET_A')])
        self.assertEqual(self.rows(self.root / 'backup'), [('a', 'laptop')])

    def test_continuation_and_removed_child_rows_follow_whole_session(self):
        for home in (self.a, self.b):
            path = self.db(home, [('x', 'before')])
            with sqlite3.connect(path) as db:
                db.execute('INSERT INTO thread_dynamic_tools VALUES (?,?,?)', ('x', 0, 'old tool'))
        base = self.snap(self.a, 'base')
        with sqlite3.connect(self.b / REL) as db:
            db.execute("UPDATE threads SET title='continued'")
            db.execute('DELETE FROM thread_dynamic_tools')
        out = self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'), base)
        self.assertEqual(self.rows(out), [('x', 'continued')])
        self.assertEqual(self.rows(out, 'thread_dynamic_tools'), [])

    def test_concurrent_changes_in_different_rows_of_same_session_conflict(self):
        for home in (self.a, self.b):
            self.db(home, [('x', 'before')])
        base = self.snap(self.a, 'base')
        with sqlite3.connect(self.a / REL) as db:
            db.execute("UPDATE threads SET title='left'")
        with sqlite3.connect(self.b / REL) as db:
            db.execute("INSERT INTO thread_dynamic_tools VALUES ('x',0,'right')")
        with self.assertRaisesRegex(sync.SyncError, 'Conflict'):
            self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'), base)

    def test_first_sync_divergence_conflicts(self):
        self.db(self.a, [('x', 'left')])
        self.db(self.b, [('x', 'right')])
        with self.assertRaisesRegex(sync.SyncError, 'Conflict'):
            self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'))

    def test_claude_append_and_divergence(self):
        rel = '.claude/projects/project/session.jsonl'
        self.assertEqual(sync.merge_file(rel, b'1\n', b'1\n2\n', None), b'1\n2\n')
        with self.assertRaises(sync.SyncError):
            sync.merge_file(rel, b'1\nleft\n', b'1\nright\n', b'1\n')

    def test_history_union_and_index_latest(self):
        a = b'{"id":"a","updated_at":"2026-01-01","thread_name":"old"}\n'
        b = b'{"id":"a","updated_at":"2026-02-01","thread_name":"new"}\n'
        self.assertEqual(json.loads(sync.merge_file('.codex/session_index.jsonl', a, b, None))['thread_name'], 'new')
        history = sync.merge_file('.codex/history.jsonl', b'{"a":1}\n', b'{"a":2}\n', None)
        self.assertEqual(len(history.splitlines()), 2)

    def test_unknown_tables_and_schema_drift_fail_closed(self):
        self.db(self.a)
        self.db(self.b)
        with sqlite3.connect(self.b / REL) as db:
            db.execute('ALTER TABLE threads ADD COLUMN new_field TEXT')
        with self.assertRaisesRegex(sync.SyncError, 'schema mismatch'):
            self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'))
        with sqlite3.connect(self.a / REL) as db:
            db.execute('CREATE TABLE future_chats(id TEXT)')
        with self.assertRaisesRegex(sync.SyncError, 'unsupported tables'):
            self.snap(self.a, 'unknown')

    def test_changed_source_aborts_before_write(self):
        self.db(self.a, [('a', 'original')])
        before = sync.snapshot(self.a, self.root / 'before')
        with sqlite3.connect(self.a / REL) as db:
            db.execute("UPDATE threads SET title='changed'")
        with self.assertRaisesRegex(sync.SyncError, 'Data changed'):
            sync.apply_snapshot(self.a, self.root / 'before', before, self.root / 'backup')
        self.assertEqual(self.rows(self.a), [('a', 'changed')])

    def test_retry_after_only_peer_applied_is_idempotent(self):
        self.db(self.a, [('a', 'A')])
        self.db(self.b, [('b', 'B')])
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        out = self.merged(left, right)
        self.apply(self.b, out)
        retry = self.merged(left, self.snap(self.b, 'right-after'), name='retry')
        self.assertEqual(self.rows(retry), [('a', 'A'), ('b', 'B')])

    def test_restore_restores_files_and_databases_with_new_backup(self):
        self.db(self.a, [('a', 'A')])
        saved = self.root / 'saved'
        sync.snapshot(self.a, saved, private=True)
        with sqlite3.connect(self.a / REL) as db:
            db.execute("INSERT INTO threads VALUES ('b','B')")
        rel = '.claude/projects/project/new.jsonl'
        sync.atomic(self.a / rel, b'{}\n')
        before = sync.snapshot(self.a, self.root / 'before')
        sync.apply_snapshot(self.a, saved, before, self.root / 'backup', restore=True)
        self.assertEqual(self.rows(self.a), [('a', 'A')])
        self.assertFalse((self.a / rel).exists())
        self.assertEqual(self.rows(self.root / 'backup'), [('a', 'A'), ('b', 'B')])

    def test_opencode_merge_and_foreign_keys(self):
        for home, sid in ((self.a, 'a'), (self.b, 'b')):
            path = self.db(home, [(sid, sid)], rel=OC)
            with sqlite3.connect(path) as db:
                db.execute('INSERT INTO message VALUES (?,?,?)', ('msg-' + sid, sid, 'text'))
        out = self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'))
        self.assertEqual(len(self.rows(out, 'message', OC)), 2)
        self.assertEqual(self.rows(out, 'account', OC), [])
        self.apply(self.a, out)
        self.assertEqual(self.rows(self.a, 'account', OC), [('auth', 'local')])

    def test_symlinks_and_traversal_rejected(self):
        (self.a / '.claude').symlink_to(self.b)
        with self.assertRaisesRegex(sync.SyncError, 'Symlink'):
            self.snap(self.a, 'left')
        with self.assertRaises(sync.SyncError):
            sync.safe_path(self.a, '../escape')

    def test_tampered_snapshot_rejected(self):
        sync.atomic(self.a / '.claude/history.jsonl', b'{}\n')
        before = sync.snapshot(self.a, self.root / 'before')
        (self.root / 'before/.claude/history.jsonl').write_text('tampered')
        with self.assertRaisesRegex(sync.SyncError, 'Invalid file snapshot'):
            sync.apply_snapshot(self.a, self.root / 'before', before, self.root / 'backup')
        self.assertEqual((self.a / '.claude/history.jsonl').read_bytes(), b'{}\n')

    def test_worker_protocol_snapshot_apply_verify_and_lock_release(self):
        self.db(self.a, [('a', 'A')])
        script = str(Path(sync.__file__).resolve())
        code = ("import importlib.util; "
                f"s=importlib.util.spec_from_file_location('sync',{script!r}); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "m.check_idle=lambda:None; m.worker()")
        env = dict(os.environ, HOME=str(self.a))
        for key in ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'XDG_DATA_HOME'):
            env.pop(key, None)
        proc = subprocess.Popen([sys.executable, '-c', code], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        def call(command):
            proc.stdin.write(json.dumps({'command': command}) + '\n')
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            self.assertNotIn('error', reply)
            return reply['result']
        try:
            info = call('info')
            with self.assertRaisesRegex(sync.SyncError, 'holds the lock'):
                sync.Endpoint(self.a)
            call('snapshot')
            run = Path(info['run'])
            shutil.copytree(run / 'before', run / 'merged')
            with sqlite3.connect(run / 'merged' / REL) as db:
                db.execute("INSERT INTO threads VALUES ('b','B')")
            manifest = sync.read_manifest(run / 'merged')
            manifest['databases'][REL] = sync.db_digest(run / 'merged' / REL, REL)
            sync.atomic(run / 'merged/manifest.json', sync.json_bytes(manifest))
            backup = Path(call('apply'))
            self.assertEqual(self.rows(backup), [('a', 'A')])
            self.assertEqual(call('verify'), manifest)
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)
            proc.stdout.close()
            errors = proc.stderr.read()
            proc.stderr.close()
        self.assertEqual(proc.returncode, 0, errors)
        endpoint = sync.Endpoint(self.a)
        endpoint.close()

    def test_unknown_event_types_are_not_exported(self):
        self.db(self.a, [('a', 'A')], rel=OC)
        with sqlite3.connect(self.a / OC) as db:
            db.executescript("CREATE TABLE event(id TEXT PRIMARY KEY, type TEXT);"
                             "INSERT INTO event VALUES ('x','credential.created');")
        with self.assertRaisesRegex(sync.SyncError, 'unsupported event types'):
            self.snap(self.a, 'snapshot')

    def test_shared_project_metadata_does_not_block_independent_chats(self):
        for home, sid, timestamp in ((self.a, 'a', 1), (self.b, 'b', 2)):
            self.db(home, [(sid, sid)], rel=OC)
            with sqlite3.connect(home / OC) as db:
                db.execute('CREATE TABLE project(id TEXT PRIMARY KEY, time_updated INTEGER, sandboxes TEXT)')
                db.execute('INSERT INTO project VALUES (?,?,?)', ('same-git-id', timestamp, json.dumps([sid])))
        out = self.merged(self.snap(self.a, 'left'), self.snap(self.b, 'right'))
        self.assertEqual(self.rows(out, 'project', OC), [('same-git-id', 2, '["a","b"]')])


if __name__ == '__main__':
    unittest.main()
