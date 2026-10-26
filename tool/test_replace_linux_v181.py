import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import replace_linux_v181 as p


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.release = copy.deepcopy(p.SNAPSHOT)
        self.release['body'] = 'original notes'
        self.snapshot = copy.deepcopy(p.SNAPSHOT)
        self.snapshot['body_sha256'] = p.sha(self.release['body'].encode())
        self.digest = p.sha(b'candidate')
        self.stage = p.NAME + '.candidate-' + self.digest[:16]
        self.writes = []

    def candidate(self, name=None):
        return {'id': 999, 'name': name or self.stage, 'size': 9,
                'digest': 'sha256:' + self.digest, 'state': 'uploaded',
                'content_type': p.OLD['content_type'], 'browser_download_url': 'https://example.invalid/candidate'}

    def check(self):
        with patch.object(p, 'SNAPSHOT', self.snapshot):
            return p.check_release(self.release, self.digest, 9)

    def test_original_staged_partial_and_final_states(self):
        self.assertIsNone(self.check()[1])
        self.release['assets'].append(self.candidate())
        self.check()
        next(a for a in self.release['assets'] if a['id'] == p.OLD['id'])['name'] = p.BACKUP
        self.check()
        self.release['assets'][-1]['name'] = p.NAME
        self.check()

    def test_protected_asset_change_is_rejected(self):
        next(a for a in self.release['assets'] if a['id'] != p.OLD['id'])['digest'] = 'sha256:bad'
        with self.assertRaisesRegex(RuntimeError, 'Protected asset changed'):
            self.check()

    def test_release_notes_change_is_rejected(self):
        self.release['body'] += 'changed'
        with self.assertRaisesRegex(RuntimeError, 'notes changed'):
            self.check()

    def test_different_candidate_and_unexpected_assets_are_rejected(self):
        self.release['assets'].append(self.candidate())
        self.release['assets'][-1]['digest'] = 'sha256:bad'
        with self.assertRaisesRegex(RuntimeError, 'Candidate identity mismatch'):
            self.check()
        self.release['assets'].append(self.candidate('other'))
        self.release['assets'][-1]['id'] = 1000
        with self.assertRaisesRegex(RuntimeError, 'Unexpected release assets'):
            self.check()

    def test_backup_alone_is_rejected(self):
        next(a for a in self.release['assets'] if a['id'] == p.OLD['id'])['name'] = p.BACKUP
        with self.assertRaisesRegex(RuntimeError, 'Backup without candidate'):
            self.check()

    def api(self, path):
        self.assertEqual(path, f'releases/{p.SNAPSHOT["id"]}')
        return copy.deepcopy(self.release)

    def command(self, *args, **kwargs):
        self.assertEqual(args[:4], ('gh', 'api', '--method', 'POST'))
        self.assertIn('uploads.github.com/repos/L1Xu4n/FocuBili/releases/', args[4])
        self.assertNotIn('--clobber', args)
        self.assertIn('Content-Length: 9', args)
        self.writes.append(('upload', self.stage))
        self.release['assets'].append(self.candidate())
        return json.dumps(self.candidate())

    def rename(self, asset_id, name):
        self.writes.append(('rename', asset_id, name))
        next(a for a in self.release['assets'] if a['id'] == asset_id)['name'] = name

    def download(self, asset, path):
        path.write_bytes(b'old' if asset['id'] == p.OLD['id'] else b'candidate')

    def publish(self, phase, expected=None):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / 'old.deb', Path(tmp) / 'new.deb'
            old.write_bytes(b'old')
            new.write_bytes(b'candidate')
            proof = {'new_sha256': self.digest, 'size': 9}
            with patch.object(p, 'SNAPSHOT', self.snapshot), patch.object(p, 'api', self.api), \
                 patch.object(p, 'command', self.command), patch.object(p, 'rename', self.rename), \
                 patch.object(p, 'download', self.download), patch.object(p, 'validate_candidate', return_value=proof), \
                 patch.dict(p.os.environ, {'GITHUB_SHA': 'head'}), patch('builtins.print'):
                p.publish(phase, old, new, self.digest if expected is None else expected)

    def source(self, bad_ci=False, changed=False, moved_tag=False):
        def api(path):
            return {'object': {'sha': ('moved' if moved_tag else p.TAG_OBJECT)
                               if 'tags/' in path else 'head'}}
        def command(*args, **kwargs):
            if args[:3] == ('git', 'diff', '--name-only'):
                return 'lib/main.dart\n' if changed else 'tool/replace_linux_v181.py\n'
            if args[:3] == ('gh', 'run', 'list'):
                return json.dumps([{'headSha': 'head', 'status': 'completed',
                                    'conclusion': 'failure' if bad_ci else 'success'}])
            return ''
        env = {'GITHUB_REPOSITORY': p.REPO, 'GITHUB_REF': 'refs/heads/master',
               'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_ACTOR': 'L1Xu4n', 'GITHUB_SHA': 'head'}
        with patch.object(p, 'api', api), patch.object(p, 'command', command), patch.dict(p.os.environ, env):
            return p.check_source()

    def test_exact_source_and_ci_gate(self):
        self.assertEqual(self.source(), 'head')
        with self.assertRaisesRegex(RuntimeError, 'CI not green'):
            self.source(bad_ci=True)
        with self.assertRaisesRegex(RuntimeError, 'Application or packaging changed'):
            self.source(changed=True)
        with self.assertRaisesRegex(RuntimeError, 'tag moved'):
            self.source(moved_tag=True)

    def test_prepare_uploads_only_candidate_and_is_idempotent(self):
        self.publish('prepare')
        self.assertEqual(self.writes, [('upload', self.stage)])
        self.writes.clear()
        self.publish('prepare')
        self.assertEqual(self.writes, [])
        self.assertEqual(next(a for a in self.release['assets'] if a['id'] == p.OLD['id'])['name'], p.NAME)

    def test_promote_renames_backup_before_candidate_and_is_idempotent(self):
        self.release['assets'].append(self.candidate())
        self.publish('promote')
        self.assertEqual(self.writes, [('rename', p.OLD['id'], p.BACKUP), ('rename', 999, p.NAME)])
        self.writes.clear()
        self.publish('promote')
        self.assertEqual(self.writes, [])

    def test_partial_promotion_resumes_without_deletion(self):
        self.release['assets'].append(self.candidate())
        self.rename(p.OLD['id'], p.BACKUP)
        self.writes.clear()
        self.publish('promote')
        self.assertEqual(self.writes, [('rename', 999, p.NAME)])

    def test_unverified_candidate_cannot_be_promoted(self):
        self.release['assets'].append(self.candidate())
        with self.assertRaisesRegex(RuntimeError, 'Independently verified'):
            self.publish('promote', 'bad')
        self.assertEqual(self.writes, [])

    def test_public_bytes_mismatch_blocks_rename(self):
        self.release['assets'].append(self.candidate())
        with patch.object(self, 'download', lambda asset, path: path.write_bytes(b'bad')):
            with self.assertRaisesRegex(RuntimeError, 'Public candidate differs'):
                self.publish('promote')
        self.assertEqual(self.writes, [])

    def test_payload_and_control_validation(self):
        old_control = 'Package: focubili\nDepends: libjsoncpp25\nVersion: 1.8.1\n'
        new_control = old_control.replace('libjsoncpp25', p.SNAPSHOT['depends'])
        def command(*args, **kwargs):
            if args[:2] == ('ar', 't'):
                control = 'control.tar.zst' if args[2].endswith('old.deb') else 'control.tar.xz'
                return f'debian-binary\n{control}\ndata.tar.zst\n'
            if args[-1] == 'Architecture':
                return 'Package: focubili\nVersion: 1.8.1\nArchitecture: amd64\n'
            return old_control if args[-1].endswith('old.deb') else new_control
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / 'old.deb', Path(tmp) / 'new.deb'
            old.write_bytes(b'original')
            new.write_bytes(b'candidate')
            with patch.object(p, 'OLD', {'digest': 'sha256:' + p.sha(b'original')}), \
                 patch.object(p, 'command', command), patch.object(p, 'member', return_value=b'identical'):
                p.validate_candidate(old, new)
            with patch.object(p, 'OLD', {'digest': 'sha256:' + p.sha(b'original')}), \
                 patch.object(p, 'command', command), \
                 patch.object(p, 'member', side_effect=lambda deb, name: deb.read_bytes()):
                with self.assertRaisesRegex(RuntimeError, 'Original payload changed'):
                    p.validate_candidate(old, new)
            with patch.object(p, 'OLD', {'digest': 'sha256:' + p.sha(b'original')}), \
                 patch.object(p, 'command', command), patch.object(p, 'member', return_value=b'identical'):
                new_control += 'Recommends: unexpected\n'
                with self.assertRaisesRegex(RuntimeError, 'Unexpected control changes'):
                    p.validate_candidate(old, new)


if __name__ == '__main__':
    unittest.main()
