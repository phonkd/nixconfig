"""Run: python3 -m unittest discover -s scripts -p 'test_chat_sync.py' -v"""
import contextlib
import importlib.util
import json
import io
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

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


    def test_symlinks_and_traversal_rejected(self):
        (self.a / '.claude').symlink_to(self.b)
        with self.assertRaisesRegex(sync.SyncError, 'Symlink'):
            self.snap(self.a, 'left')
        with self.assertRaises(sync.SyncError):
            sync.safe_path(self.a, '../escape')

    def test_opencode_is_not_inspected_or_copied(self):
        # Even invalid/new OpenCode databases and a conflicting snapshot cache
        # must not participate in a Claude/Codex sync.
        for home, data in ((self.a, b'local'), (self.b, b'peer')):
            self.db(home, [(data.decode(), data.decode())])
            sync.atomic(home / OC, b'not a SQLite database')
            sync.atomic(home / '.local/share/opencode/new-version.db', b'unknown format')
            sync.atomic(home / '.local/share/opencode/snapshot/repo/hooks/test', data)
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        out = self.merged(left, right)
        for root in (left, right, out):
            manifest = sync.read_manifest(root)
            self.assertFalse(any('opencode' in rel for section in ('files', 'databases') for rel in manifest[section]))
            self.assertFalse((root / '.local/share/opencode').exists())

    def test_legacy_backup_restore_ignores_opencode_entries(self):
        self.db(self.a, [('a', 'original')])
        saved = self.root / 'saved'
        sync.snapshot(self.a, saved, private=True)
        manifest = sync.read_manifest(saved)
        old_file = '.local/share/opencode/snapshot/repo/hooks/test'
        manifest['files'][old_file] = 'old-checksum'
        manifest['databases'][OC] = 'old-checksum'
        # No backing OpenCode snapshot files: proves restore never reads them.
        sync.atomic(saved / 'manifest.json', sync.json_bytes(manifest))
        sync.atomic(self.a / OC, b'keep current OpenCode database')
        sync.atomic(self.a / old_file, b'keep current OpenCode snapshot')
        with sqlite3.connect(self.a / REL) as db:
            db.execute("UPDATE threads SET title='modified'")
        before = sync.snapshot(self.a, self.root / 'before')
        sync.apply_snapshot(self.a, saved, before, self.root / 'backup', restore=True)
        self.assertEqual(self.rows(self.a), [('a', 'original')])
        self.assertEqual((self.a / OC).read_bytes(), b'keep current OpenCode database')
        self.assertEqual((self.a / old_file).read_bytes(), b'keep current OpenCode snapshot')

    def test_old_baseline_opencode_entries_do_not_reenter_merge(self):
        self.db(self.a, [('a', 'A')])
        self.db(self.b, [('b', 'B')])
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        manifest = sync.read_manifest(left)
        manifest['databases'][OC] = 'old-checksum'
        manifest['files']['.local/share/opencode/snapshot/old'] = 'old-checksum'
        sync.atomic(left / 'manifest.json', sync.json_bytes(manifest))
        out = self.merged(left, right, left)
        self.assertEqual(self.rows(out), [('a', 'A'), ('b', 'B')])
        self.assertFalse((out / '.local/share/opencode').exists())

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


    def test_interactive_file_conflict_keeps_selected_device(self):
        rel = '.claude/plans/shared.md'
        sync.atomic(self.a / rel, b'z14 hook')
        sync.atomic(self.b / rel, b'blac hook')
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        output = io.StringIO()
        with patch.object(sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='2'), contextlib.redirect_stdout(output):
            sync.merge(left, right, self.root / 'absent', self.root / 'merged', resolver)
        self.assertEqual((self.root / 'merged' / rel).read_bytes(), b'blac hook')
        self.assertIn('z14 (local)', output.getvalue())
        self.assertIn('blac (peer)', output.getvalue())
        self.assertEqual((self.a / rel).read_bytes(), b'z14 hook')

    def test_choose_local_for_remaining_conflicts_prompts_once(self):
        for name in ('one', 'two'):
            sync.atomic(self.a / '.claude/plans' / name, b'local')
            sync.atomic(self.b / '.claude/plans' / name, b'peer')
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        with patch.object(sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='l') as ask, contextlib.redirect_stdout(io.StringIO()):
            sync.merge(left, right, self.root / 'absent', self.root / 'merged', resolver)
        self.assertEqual(ask.call_count, 1)
        for name in ('one', 'two'):
            self.assertEqual((self.root / 'merged/.claude/plans' / name).read_bytes(), b'local')

    def test_prefer_local_resolves_files_and_sessions_without_terminal(self):
        rel = '.claude/plans/shared.md'
        for home, title in ((self.a, 'local'), (self.b, 'peer')):
            self.db(home, [('shared', title)])
            sync.atomic(home / rel, title.encode())
        with sqlite3.connect(self.b / REL) as db:
            db.execute("INSERT INTO threads VALUES ('peer-only','keep me')")
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        resolver.remaining = 'left'
        with patch.object(sys.stdin, 'isatty', return_value=False), patch('builtins.input') as ask:
            sync.merge(left, right, self.root / 'absent', self.root / 'merged', resolver)
        ask.assert_not_called()
        self.assertEqual((self.root / 'merged' / rel).read_bytes(), b'local')
        self.assertEqual(self.rows(self.root / 'merged'), [('peer-only', 'keep me'), ('shared', 'local')])

    def test_prefer_local_file_conflicts_do_not_restart_whole_merge(self):
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        resolver.remaining = 'left'
        with patch('builtins.input') as ask:
            for i in range(10):
                self.assertEqual(sync.choose('local', 'peer', None, f'file-{i}', resolver), 'local')
        ask.assert_not_called()

    def test_conflict_prompt_abort_and_noninteractive_fail_closed(self):
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        with patch.object(sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value=''), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(sync.SyncError, 'aborted'):
                sync.choose('left', 'right', None, 'test', resolver)
        with patch.object(sys.stdin, 'isatty', return_value=False):
            with self.assertRaisesRegex(sync.SyncError, 'Run in a terminal'):
                sync.choose('left', 'right', None, 'test', resolver)
        self.assertEqual(resolver.choices, {})

    def test_session_choice_rebuilds_transcript_and_uses_whole_session(self):
        transcript = '.codex/sessions/session.jsonl'
        header = b'{"type":"session_meta","payload":{"id":"x"}}\n'
        for home, title, content in ((self.a, 'left', header), (self.b, 'right', header + b'{"extra":1}\n')):
            self.db(home, [('x', title)])
            sync.atomic(home / transcript, content)
            with sqlite3.connect(home / REL) as db:
                db.execute('INSERT INTO thread_dynamic_tools VALUES (?,?,?)', ('x', 0, title))
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        resolver = sync.ConflictResolver('z14', 'blac', self.root)
        with patch.object(sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='1') as ask, contextlib.redirect_stdout(io.StringIO()):
            sync.merge(left, right, self.root / 'absent', self.root / 'merged', resolver)
        self.assertEqual(ask.call_count, 1)
        self.assertEqual(self.rows(self.root / 'merged'), [('x', 'left')])
        self.assertEqual(self.rows(self.root / 'merged', 'thread_dynamic_tools'), [('x', 0, 'left')])
        self.assertEqual((self.root / 'merged' / transcript).read_bytes(), header)

    def test_push_applies_only_peer_and_checks_source_unchanged(self):
        local, remote = Mock(), Mock()
        local.before = {'source': 'original'}
        local.call.return_value = local.before
        result = {'merged': 'both histories'}
        remote.call.side_effect = ['peer-backup', result]
        with contextlib.redirect_stdout(io.StringIO()):
            sync.apply_merged(local, remote, result, 'push')
        self.assertEqual([call.args[0] for call in local.call.call_args_list], ['verify'])
        self.assertEqual([call.args[0] for call in remote.call.call_args_list], ['apply', 'verify'])

    def test_two_way_applies_and_verifies_both(self):
        local, remote = Mock(), Mock()
        result = {'merged': 'both histories'}
        local.call.side_effect = ['local-backup', result]
        remote.call.side_effect = ['peer-backup', result]
        with contextlib.redirect_stdout(io.StringIO()):
            sync.apply_merged(local, remote, result, 'both')
        for endpoint in (local, remote):
            self.assertEqual([call.args[0] for call in endpoint.call.call_args_list], ['apply', 'verify'])

    def test_push_rejects_changed_source_on_verification(self):
        local, remote = Mock(), Mock()
        local.before = {'source': 'original'}
        local.call.return_value = {'source': 'changed'}
        result = {'merged': 'both histories'}
        remote.call.side_effect = ['peer-backup', result]
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(sync.SyncError, 'verification failed'):
            sync.apply_merged(local, remote, result, 'push')

    def test_push_fixture_preserves_source_and_peer_only_sessions(self):
        self.db(self.a, [('a', 'z14')], 'z14-secret')
        self.db(self.b, [('b', 'blac')], 'blac-secret')
        left, right = self.snap(self.a, 'left'), self.snap(self.b, 'right')
        out = self.merged(left, right)
        manifest = sync.read_manifest(out)
        manifest['home'] = str(self.b)
        sync.atomic(out / 'manifest.json', sync.json_bytes(manifest))
        local, remote = sync.Endpoint(self.a), sync.Endpoint(self.b)
        original_db = (self.a / REL).read_bytes()
        try:
            local.call('snapshot')
            remote.call('snapshot')
            shutil.copytree(out, remote.run / 'merged')
            with contextlib.redirect_stdout(io.StringIO()):
                sync.apply_merged(local, remote, manifest, 'push')
            self.assertEqual((self.a / REL).read_bytes(), original_db)
            self.assertEqual(self.rows(self.a), [('a', 'z14')])
            self.assertEqual(self.rows(self.b), [('a', 'z14'), ('b', 'blac')])
            self.assertEqual(list((local.state / 'backups').glob('*')), [])
            self.assertTrue(list((remote.state / 'backups').glob('*/manifest.json')))
            self.assertEqual(self.rows(self.b, 'remote_control_enrollments'), [('auth', 'blac-secret')])
        finally:
            local.close()
            remote.close()


if __name__ == '__main__':
    unittest.main()
