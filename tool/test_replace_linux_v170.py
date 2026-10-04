"""Offline tests. No test calls GitHub or executes package/application bytes."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import replace_linux_v170 as r


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.old, self.new = b'old installer fixture', b'new installer fixture'
        self.snapshot = copy.deepcopy(r.SNAPSHOT)
        self.original = next(a for a in self.snapshot['assets'] if a['name'] == r.p.DEB)
        self.original.update(size=len(self.old), digest='sha256:' + r.p.sha(self.old))
        self.release = copy.deepcopy(self.snapshot)
        self.bytes = {r.OLD_ID: self.old}
        self.writes = []
        self.backup_ok = True
        self.fail_upload = False
        self.bad_upload = False
        self.fail_rename = False
        self.race_notes = False
        self.patches = [
            patch.object(r, 'SNAPSHOT', self.snapshot),
            patch.object(r, 'OLD_SHA', r.p.sha(self.old)),
            patch.object(r, 'PACKAGE_SHA256', {r.p.DEB: r.p.sha(self.new)}),
            patch.object(r.p, 'api', self.api), patch.object(r.p, 'gh', self.gh),
            patch.object(r, 'verify_backup_artifact', self.backup),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def backup(self, old):
        if not self.backup_ok:
            raise RuntimeError('Backup failed')
        self.assertEqual(old, self.old)

    def api(self, path):
        if path == f'releases/{r.p.RELEASE_ID}':
            return copy.deepcopy(self.release)
        if path == f'git/ref/tags/{r.p.TAG}':
            return {'object': {'sha': r.p.TAG_OBJECT}}
        if path == 'git/ref/heads/dev':
            return {'object': {'sha': 'head'}}
        raise AssertionError(path)

    def gh(self, *args, binary=False):
        if args[:2] == ('release', 'upload'):
            self.writes.append('upload')
            if self.fail_upload:
                raise RuntimeError('Upload failed')
            f = Path(args[3])
            data = f.read_bytes()
            asset = copy.deepcopy(self.original)
            asset.update(id=999, name=f.name, size=len(data), digest='sha256:' + r.p.sha(data))
            self.release['assets'].append(asset)
            self.bytes[999] = b'corrupt' if self.bad_upload else data
            if self.race_notes:
                self.release['body'] += 'foreign edit'
            return ''
        if args[0] == 'api' and '--method' not in args:
            ident = int(args[1].rsplit('/', 1)[1])
            return self.bytes[ident]
        if args[:3] == ('api', '--method', 'DELETE'):
            ident = int(args[3].rsplit('/', 1)[1])
            self.writes.append(('delete', ident))
            self.release['assets'] = [a for a in self.release['assets'] if a['id'] != ident]
            return ''
        if args[:3] == ('api', '--method', 'PATCH'):
            payload = json.loads(Path(args[-1]).read_text())
            self.writes.append(('patch', payload))
            if 'name' in payload:
                if self.fail_rename:
                    raise RuntimeError('Rename failed')
                ident = int(args[3].rsplit('/', 1)[1])
                next(a for a in self.release['assets'] if a['id'] == ident).update(payload)
            else:
                self.release.update(payload)
            return ''
        raise AssertionError(args)

    def run_replace(self):
        r.replace('head', self.new, self.old)

    def assert_protected(self):
        self.assertEqual([a for a in self.snapshot['assets'] if a['id'] != r.OLD_ID],
                         [a for a in self.release['assets'] if a['id'] != 999])
        for delimiter, i in ((r.p.START, 0), (r.p.END, 1)):
            self.assertEqual(self.snapshot['body'].split(delimiter)[i], self.release['body'].split(delimiter)[i])

    def test_happy_path_and_idempotence(self):
        self.run_replace()
        self.assertEqual(len(self.release['assets']), 6)
        self.assert_protected()
        self.assertEqual(self.writes[0], 'upload')
        self.assertIn(('delete', r.OLD_ID), self.writes)
        before = copy.deepcopy(self.writes)
        self.run_replace()
        self.assertEqual(before, self.writes)

    def test_wrong_old_bytes(self):
        self.bytes[r.OLD_ID] = b'foreign'
        with self.assertRaisesRegex(RuntimeError, 'bytes mismatch'):
            self.run_replace()
        self.assertEqual(self.writes, [])

    def test_wrong_old_input(self):
        with self.assertRaisesRegex(RuntimeError, 'Wrong replacement inputs'):
            r.replace('head', self.new, b'wrong')
        self.assertEqual(self.writes, [])

    def test_foreign_asset_changed(self):
        next(a for a in self.release['assets'] if a['id'] != r.OLD_ID)['digest'] = 'foreign'
        with self.assertRaisesRegex(RuntimeError, 'Protected asset changed'):
            self.run_replace()
        self.assertEqual(self.writes, [])

    def test_failed_staging_keeps_old(self):
        self.fail_upload = True
        with self.assertRaisesRegex(RuntimeError, 'Upload failed'):
            self.run_replace()
        self.assertEqual(self.release['assets'], self.snapshot['assets'])
        self.fail_upload = False
        self.run_replace()

    def test_corrupt_staging_keeps_old(self):
        self.bad_upload = True
        with self.assertRaisesRegex(RuntimeError, 'bytes mismatch'):
            self.run_replace()
        self.assertTrue(any(a['id'] == r.OLD_ID for a in self.release['assets']))
        self.assertNotIn(('delete', r.OLD_ID), self.writes)

    def test_partial_rename_recovery(self):
        self.fail_rename = True
        with self.assertRaisesRegex(RuntimeError, 'Rename failed'):
            self.run_replace()
        self.assertFalse(any(a['id'] == r.OLD_ID for a in self.release['assets']))
        self.assertTrue(any(a['name'] == r.stage_name() for a in self.release['assets']))
        self.fail_rename = False
        self.run_replace()
        self.assertEqual(self.writes.count(('delete', r.OLD_ID)), 1)
        self.assertEqual(self.writes.count('upload'), 1)
        self.assert_protected()

    def test_notes_race_after_staging(self):
        self.race_notes = True
        with self.assertRaisesRegex(RuntimeError, 'notes changed concurrently'):
            self.run_replace()
        self.assertNotIn(('delete', r.OLD_ID), self.writes)
        self.assertTrue(self.release['body'].endswith('foreign edit'))

    def test_backup_failure_no_release_writes(self):
        self.backup_ok = False
        with self.assertRaisesRegex(RuntimeError, 'Backup failed'):
            self.run_replace()
        self.assertEqual(self.writes, [])

    def test_conflicting_stable_name(self):
        original = next(a for a in self.release['assets'] if a['id'] == r.OLD_ID)
        original.update(id=887, digest='sha256:foreign')
        with self.assertRaisesRegex(RuntimeError, 'Conflicting replacement'):
            self.run_replace()
        self.assertEqual(self.writes, [])

    def test_unexpected_tar_rejected(self):
        self.release['assets'].append({'name': r.p.TAR, 'id': 777})
        with self.assertRaisesRegex(RuntimeError, 'Unexpected release asset'):
            self.run_replace()
        self.assertEqual(self.writes, [])

    def test_unfilled_pins_fail_closed(self):
        names = ('SOURCE_SHA', 'LINUX_RUN', 'ARTIFACT_ID', 'ARTIFACT_DIGEST',
                 'PACKAGE_SHA256', 'NORMAL_EXECUTABLE_SHA256', 'NORMAL_LIBAPP_SHA256')
        saved = {name: getattr(r.p, name) for name in names}
        try:
            with patch.object(r, 'SOURCE_SHA', 'REQUIRED'), self.assertRaisesRegex(RuntimeError, 'Fill final source pin'):
                r.configure_validator()
        finally:
            for name, value in saved.items():
                setattr(r.p, name, value)


class RuntimeEvidenceTests(unittest.TestCase):
    def archive(self, transcript):
        import io
        import zipfile
        out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            z.writestr('linux-runtime.log', transcript)
        return out.getvalue()

    def check(self, transcript):
        raw = self.archive(transcript)
        with patch.object(r, 'ARTIFACT_DIGEST', 'sha256:' + r.p.sha(raw)), \
             patch.object(r, 'RUNTIME_MARKERS', {'linux-runtime.log': ['resize passed']}):
            r.validate_runtime_evidence(raw)

    def test_verified_normal_exit(self):
        self.check('resize passed\nLINUX_RUNTIME_ALL_CHECKS_PASSED\n[Inferior 1 (process 123) exited normally]\n')

    def test_post_success_crash_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'did not exit normally'):
            self.check('resize passed\nLINUX_RUNTIME_ALL_CHECKS_PASSED\nThread 1 received signal SIGSEGV\n')

    def test_no_exit_evidence_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'did not exit normally'):
            self.check('resize passed\nLINUX_RUNTIME_ALL_CHECKS_PASSED\n')

    def test_resize_absent_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Resize assertion absent'):
            self.check('LINUX_RUNTIME_ALL_CHECKS_PASSED\n[Inferior 1 (process 123) exited normally]\n')


if __name__ == '__main__':
    unittest.main()
