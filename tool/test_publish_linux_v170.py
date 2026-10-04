import copy
import io
import json
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch
import zipfile
import publish_linux_v170 as p


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.release = copy.deepcopy(p.BASELINE)
        self.payloads = {p.DEB: b'deb', p.TAR: b'tar', p.SUMS: b'sums'}
        self.writes = []
        self.downloads = {}

    def api(self, path):
        if path == f'releases/{p.RELEASE_ID}':
            return copy.deepcopy(self.release)
        if path == f'git/ref/tags/{p.TAG}':
            return {'object': {'sha': p.TAG_OBJECT}}
        if path == 'git/ref/heads/dev':
            return {'object': {'sha': 'head'}}
        self.fail(f'Unexpected API: {path}')

    def gh(self, *args, binary=False):
        if args[:3] == ('api', '--method', 'PATCH'):
            self.writes.append(('patch',))
            self.release['body'] = json.loads(Path(args[-1]).read_text())['body']
            return '{}'
        if args[:2] == ('release', 'upload'):
            self.assertNotIn('--clobber', args)
            path = Path(args[3])
            self.writes.append(('upload', path.name))
            data = path.read_bytes()
            ident = 900 + len(self.release['assets'])
            self.release['assets'].append({'name': path.name, 'id': ident, 'size': len(data),
                                          'digest': 'sha256:' + p.sha(data), 'state': 'uploaded'})
            self.downloads[ident] = data
            return ''
        if args[0] == 'api' and '/releases/assets/' in args[1]:
            return self.downloads[int(args[1].split('/')[-1])]
        self.fail(f'Unexpected gh: {args}')

    def publish(self):
        with patch.object(p, 'api', self.api), patch.object(p, 'gh', self.gh):
            p.publish({p.DEB: self.payloads[p.DEB]}, 'head')

    def test_additive_and_rerun_idempotence(self):
        original = copy.deepcopy(self.release['assets'])
        self.publish()
        self.assertEqual(self.release['assets'][:5], original)
        self.assertEqual(len(self.writes), 2)
        self.assertTrue(self.release['body'].startswith(p.BASELINE['body']))
        self.writes.clear()
        self.publish()
        self.assertEqual(self.writes, [])

    def test_non_installer_payload_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Only the DEB'):
            p.publish(self.payloads, 'head')
        self.assertEqual(self.writes, [])

    def test_notes_only_list_installer(self):
        body = p.build_body({p.DEB: b'deb'})
        section = body.split(p.START)[1]
        self.assertNotIn('tar.gz', section)
        self.assertNotIn(p.SUMS, section)
        self.assertIn(p.sha(b'deb'), section)

    def test_partial_rerun(self):
        self.publish()
        self.release['assets'] = [a for a in self.release['assets'] if a['name'] != p.DEB]
        self.writes.clear()
        self.publish()
        self.assertEqual(self.writes, [('upload', p.DEB)])

    def test_different_existing_linux_asset_is_never_uploaded(self):
        self.release['assets'].append({'name': p.DEB, 'size': 3, 'digest': 'sha256:bad', 'state': 'uploaded'})
        with self.assertRaisesRegex(RuntimeError, 'Different existing Linux'):
            self.publish()
        self.assertEqual(self.writes, [])

    def test_original_asset_mismatch(self):
        self.release['assets'][0]['digest'] = 'sha256:bad'
        with self.assertRaisesRegex(RuntimeError, 'Original asset changed'):
            self.publish()
        self.assertEqual(self.writes, [])

    def test_metadata_mismatch(self):
        self.release['target_commitish'] = 'dev'
        with self.assertRaisesRegex(RuntimeError, 'metadata mismatch'):
            self.publish()
        self.assertEqual(self.writes, [])

    def test_notes_mismatch(self):
        self.release['body'] += '\nHuman edit'
        with self.assertRaisesRegex(RuntimeError, 'body mismatch'):
            self.publish()
        self.assertEqual(self.writes, [])

    def test_unfilled_pins_fail_closed(self):
        with patch.object(p, 'SOURCE_SHA', 'FILL'), self.assertRaises(RuntimeError):
            p.check_pins()

    def artifact(self, bad_manifest=False):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as z:
            for name in (p.DEB, p.TAR):
                z.writestr(name, self.payloads[name])
            z.writestr('SHA256SUMS.txt', ''.join(
                f'{"0" * 64 if bad_manifest else p.sha(self.payloads[n])}  ./{n}\n' for n in (p.DEB, p.TAR)))
        return output.getvalue()

    def prepare(self, bad_manifest=False, bad_archive=False, bad_metadata=False):
        archive = self.artifact(bad_manifest)
        digest = 'sha256:' + p.sha(archive)
        artifact = {'id': 123, 'name': f'focubili-linux-{p.SOURCE_SHA}', 'digest': digest,
                    'expired': False, 'workflow_run': {'id': 456, 'head_sha': p.SOURCE_SHA}}
        if bad_metadata:
            artifact['workflow_run']['id'] = 789
        with patch.object(p, 'ARTIFACT_ID', 123), patch.object(p, 'LINUX_RUN', 456), \
             patch.object(p, 'ARTIFACT_DIGEST', digest), patch.object(p, 'api', return_value=artifact), \
             patch.object(p, 'gh', return_value=archive + b'bad' if bad_archive else archive), \
             patch.object(p, 'PACKAGE_SHA256', {n: p.sha(self.payloads[n]) for n in (p.DEB, p.TAR)}), \
             patch.object(p, 'validate_packages') as validate:
            result = p.prepare_payloads()
            validate.assert_called_once()
            return result

    def test_artifact_preparation(self):
        result = self.prepare()
        self.assertEqual(set(result), {p.DEB})
        self.assertNotIn('SHA256SUMS.txt', result)

    def test_package_checksum_mismatch(self):
        with self.assertRaisesRegex(RuntimeError, 'Package checksum mismatch'):
            self.prepare(bad_manifest=True)

    def test_archive_checksum_mismatch(self):
        with self.assertRaisesRegex(RuntimeError, 'archive checksum mismatch'):
            self.prepare(bad_archive=True)

    def test_artifact_metadata_mismatch(self):
        with self.assertRaisesRegex(RuntimeError, 'Artifact metadata mismatch'):
            self.prepare(bad_metadata=True)

    def package_fixture(self, version='1.7.0', uid=0, divergent=False, bad_pin=False):
        elf = b'\x7fELF\x02\x01' + b'\x00' * 12 + b'\x3e\x00' + b'normal-app'
        def archive(deb=False):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode='w') as t:
                for name in ('focubili', 'lib/libapp.so'):
                    content = elf + (b'bad' if divergent and deb else b'')
                    m = tarfile.TarInfo(('./opt/focubili/' if deb else './') + name)
                    m.uid = m.gid = uid
                    m.mode = 0o755
                    m.size = len(content)
                    t.addfile(m, io.BytesIO(content))
                if deb:
                    m = tarfile.TarInfo('./usr/bin/focubili')
                    m.type = tarfile.SYMTYPE
                    m.mode = 0o777
                    m.linkname = '/opt/focubili/focubili'
                    t.addfile(m)
            return output.getvalue()
        def command(args, text=False):
            if args[1] == '-f':
                return {'Package': 'focubili', 'Version': version, 'Architecture': 'amd64'}[args[-1]]
            return archive(deb=True)
        with patch.object(p.subprocess, 'check_output', side_effect=command), \
             patch.object(p, 'NORMAL_EXECUTABLE_SHA256', p.sha(elf)), \
             patch.object(p, 'NORMAL_LIBAPP_SHA256', 'wrong' if bad_pin else p.sha(elf)):
            p.validate_packages({p.DEB: b'mocked-deb', p.TAR: archive()})

    def test_deb_and_tar_structure(self):
        self.package_fixture()

    def test_deb_version_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Version mismatch'):
            self.package_fixture(version='1.7.1')

    def test_deb_non_root_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'ownership/permissions'):
            self.package_fixture(uid=1000)

    def test_deb_tar_difference_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'bundle mismatch'):
            self.package_fixture(divergent=True)

    def test_runtime_probe_libapp_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Normal application pin mismatch'):
            self.package_fixture(bad_pin=True)

    def source_fixture(self, missing_pr=False, changed_source=False, wrong_run=False):
        names = ['Build normal release application', 'Package installable application',
                 'Test normal application startup and single instance',
                 'Build standalone native runtime probe', 'Test real Linux desktop services and media']
        def api(path):
            if path == 'git/ref/heads/dev':
                return {'object': {'sha': 'head'}}
            if path.startswith('compare/'):
                return {'status': 'ahead', 'files': [{'filename': 'lib/main.dart'}] if changed_source else []}
            if path.startswith('pulls/'):
                return {'merged': not missing_pr, 'base': {'ref': 'dev'}, 'merge_commit_sha': 'merged'}
            if path.endswith('/jobs?per_page=100'):
                return {'total_count': 1, 'jobs': [{'conclusion': 'success', 'labels': ['ubuntu-24.04'],
                        'steps': [{'name': n, 'conclusion': 'success'} for n in names]}]}
            if path.startswith('actions/runs/'):
                return {'head_sha': 'wrong' if wrong_run else p.SOURCE_SHA, 'head_branch': 'dev',
                        'event': 'push', 'path': '.github/workflows/linux-build.yml',
                        'status': 'completed', 'conclusion': 'success'}
            self.fail(path)
        with patch.object(p, 'check_pins'), patch.object(p, 'api', side_effect=api), \
             patch.dict(p.os.environ, {'GITHUB_REPOSITORY': p.REPO, 'GITHUB_REF': 'refs/heads/dev',
                                      'GITHUB_EVENT_NAME': 'push', 'GITHUB_SHA': 'head'}):
            return p.check_source()

    def test_source_gate(self):
        self.assertEqual(self.source_fixture(), 'head')

    def test_unmerged_pr_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'not merged to dev'):
            self.source_fixture(missing_pr=True)

    def test_changed_application_source_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Application changed'):
            self.source_fixture(changed_source=True)

    def test_wrong_ci_source_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Linux run mismatch'):
            self.source_fixture(wrong_run=True)

    def test_unsafe_tar(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            m = tarfile.TarInfo('../outside')
            archive.addfile(m)
        with self.assertRaisesRegex(RuntimeError, 'Unsafe tar path'):
            p.tar_entries(data.getvalue())


if __name__ == '__main__':
    unittest.main()
