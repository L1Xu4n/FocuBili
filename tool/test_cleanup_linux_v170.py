import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import cleanup_linux_v170 as c
import publish_linux_v170 as p


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = copy.deepcopy(c.SNAPSHOT)
        self.baseline = copy.deepcopy(p.BASELINE)
        self.data = {a['name']: a['name'].encode() for a in self.snapshot['assets']}
        for a in self.snapshot['assets']:
            a['size'] = len(self.data[a['name']])
            a['digest'] = 'sha256:' + p.sha(self.data[a['name']])
        self.baseline['assets'] = [copy.deepcopy(a) for a in self.snapshot['assets']
                                   if a['name'] in p.asset_map(p.BASELINE)]
        assets = p.asset_map(self.snapshot)
        self.targets = {name: (assets[name]['id'], assets[name]['digest']) for name in c.TARGETS}
        self.release = copy.deepcopy(self.snapshot)
        self.writes = []
        self.tag = p.TAG_OBJECT
        self.head = 'head'
        self.fail_delete = None

    def api(self, path):
        if path == f'releases/{p.RELEASE_ID}':
            return copy.deepcopy(self.release)
        if path == f'git/ref/tags/{p.TAG}':
            return {'object': {'sha': self.tag}}
        if path == 'git/ref/heads/dev':
            return {'object': {'sha': self.head}}
        self.fail(path)

    def gh(self, *args, binary=False):
        if args[:3] == ('api', '--method', 'PATCH'):
            self.writes.append(('patch',))
            self.release['body'] = json.loads(Path(args[-1]).read_text())['body']
            return '{}'
        if args[:3] == ('api', '--method', 'DELETE'):
            ident = int(args[-1].split('/')[-1])
            if ident == self.fail_delete:
                raise RuntimeError('Simulated interrupted delete')
            self.writes.append(('delete', ident))
            self.release['assets'] = [a for a in self.release['assets'] if a['id'] != ident]
            return ''
        if args[0] == 'api' and '/releases/assets/' in args[1]:
            ident = int(args[1].split('/')[-1])
            return next(self.data[a['name']] for a in self.release['assets'] if a['id'] == ident)
        self.fail(args)

    def cleanup(self):
        with patch.object(c, 'SNAPSHOT', self.snapshot), patch.object(c, 'TARGETS', self.targets), \
             patch.object(p, 'BASELINE', self.baseline), \
             patch.object(p, 'api', self.api), patch.object(p, 'gh', self.gh):
            c.cleanup({p.DEB: self.data[p.DEB]}, 'head')

    def reject(self, message):
        with self.assertRaisesRegex(RuntimeError, message):
            self.cleanup()
        self.assertEqual(self.writes, [])

    def test_exact_deletes_preserve_six_and_idempotence(self):
        kept = [a for a in self.release['assets'] if a['name'] not in self.targets]
        self.cleanup()
        self.assertEqual(self.release['assets'], kept)
        self.assertEqual(len(kept), 6)
        self.assertEqual(self.writes, [('patch',), ('delete', 608276990), ('delete', 608277018)])
        self.assertEqual(self.release['body'].split(p.START)[0], self.snapshot['body'].split(p.START)[0])
        self.assertNotIn('tar.gz', self.release['body'].split(p.START)[1])
        self.assertNotIn(p.SUMS, self.release['body'])
        self.writes.clear()
        self.cleanup()
        self.assertEqual(self.writes, [])

    def test_partial_failure_retries_only_remaining_asset(self):
        self.fail_delete = 608277018
        with self.assertRaisesRegex(RuntimeError, 'interrupted'):
            self.cleanup()
        self.fail_delete = None
        self.writes.clear()
        self.cleanup()
        self.assertEqual(self.writes, [('delete', 608277018)])

    def test_missing_targets_with_old_notes_is_safe(self):
        self.release['assets'] = [a for a in self.release['assets'] if a['name'] not in self.targets]
        self.cleanup()
        self.assertEqual(self.writes, [('patch',)])

    def test_changed_target_id(self):
        next(a for a in self.release['assets'] if a['name'] == p.TAR)['id'] += 1
        self.reject('Asset changed')

    def test_changed_last_target_digest_prevents_all_writes(self):
        next(a for a in self.release['assets'] if a['name'] == p.SUMS)['digest'] = 'wrong'
        self.reject('Asset changed')

    def test_target_download_corruption_prevents_all_writes(self):
        self.data[p.SUMS] += b'bad'
        self.reject('bytes mismatch')

    def test_protected_zip_missing(self):
        self.release['assets'] = [a for a in self.release['assets'] if not a['name'].endswith('portable.zip')]
        self.reject('Missing protected asset')

    def test_protected_deb_changed(self):
        next(a for a in self.release['assets'] if a['name'] == p.DEB)['digest'] = 'bad'
        self.reject('Asset changed')

    def test_unknown_asset(self):
        self.release['assets'].append({'name': 'unexpected', 'id': 999})
        self.reject('Unexpected release asset')

    def test_duplicate_asset(self):
        self.release['assets'].append(copy.deepcopy(self.release['assets'][0]))
        self.reject('Duplicate release asset names')

    def test_metadata_conflict(self):
        self.release['name'] = 'Changed release'
        self.reject('metadata mismatch')

    def test_tag_conflict(self):
        self.tag = 'moved'
        self.reject('tag moved')

    def test_dev_conflict(self):
        self.head = 'moved'
        self.reject('Dev moved')

    def test_notes_conflict(self):
        self.release['body'] += 'Human edit'
        self.reject('notes changed')

    def test_original_snapshot_and_targets_are_exact(self):
        self.assertEqual(len(p.BASELINE['assets']), 5)
        self.assertEqual(len(c.SNAPSHOT['assets']), 8)
        self.assertEqual(set(c.TARGETS), {p.TAR, p.SUMS})
        for a in c.SNAPSHOT['assets']:
            if a['name'] in c.TARGETS:
                self.assertEqual((a['id'], a['digest']), c.TARGETS[a['name']])
        p.require(c.SNAPSHOT['body'].startswith(p.BASELINE['body']), 'Baseline mismatch')


if __name__ == '__main__':
    unittest.main()
