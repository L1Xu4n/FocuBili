"""Upload pinned, already-built v1.7.1 packages; never publish or replace assets."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

CONFIG = json.loads(Path(__file__).with_name('v171_upload_manifest.json').read_text())
EXPECTED = {item['name']: item for item in CONFIG['assets']}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def gh(*args, **kwargs):
    return subprocess.check_output(['gh', *args], **kwargs)


def api(path):
    return json.loads(gh('api', f'repos/{CONFIG["repo"]}/{path}'))


def validate_asset(asset, expected):
    require(asset['name'] == expected['name'], 'Unexpected asset name')
    require(asset['state'] == 'uploaded', 'Asset upload incomplete')
    require(asset['size'] == expected['size'], 'Asset size mismatch')
    require(asset.get('digest') == 'sha256:' + expected['sha256'], 'Asset digest mismatch')


def validate_release(release):
    require(release['id'] == CONFIG['release_id'], 'Release ID changed')
    require(release['tag_name'] == CONFIG['tag'], 'Release tag changed')
    require(release['draft'] is True and release['prerelease'] is False, 'Release must remain a stable draft')
    assets = {item['name']: item for item in release['assets']}
    require(len(assets) == len(release['assets']), 'Duplicate release asset')
    require(set(assets).issubset(EXPECTED), 'Unexpected release asset')
    for name, asset in assets.items():
        validate_asset(asset, EXPECTED[name])
    return assets


def read_release():
    return validate_release(api(f'releases/{CONFIG["release_id"]}'))


def main():
    require(os.environ.get('GITHUB_REPOSITORY') == CONFIG['repo'], 'Wrong repository')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/codex/deliver-v1.7.1-assets', 'Wrong delivery branch')
    require(len(EXPECTED) == 6, 'Expected exactly six package files')
    tag = api('git/ref/tags/' + CONFIG['tag'])['object']
    if tag['type'] == 'tag':
        tag = api('git/tags/' + tag['sha'])['object']
    require(tag['type'] == 'commit' and tag['sha'] == CONFIG['tag_commit'], 'Tag moved')
    for sha in (CONFIG['source_commit'], CONFIG['tag_commit']):
        require(api('git/commits/' + sha)['tree']['sha'] == CONFIG['source_tree'], 'Source tree mismatch')
    read_release()
    for run_id in sorted({item['run_id'] for item in CONFIG['assets']}):
        run = api(f'actions/runs/{run_id}')
        require(run['head_sha'] == CONFIG['source_commit'], 'Build source mismatch')
        require(run['status'] == 'completed' and run['conclusion'] == 'success', 'Build did not pass')
    with tempfile.TemporaryDirectory(prefix='focubili-v171-') as directory:
        root = Path(directory)
        archives = {}
        staged = {}
        for expected in CONFIG['assets']:
            artifact_id = expected['artifact_id']
            if artifact_id not in archives:
                artifact = api(f'actions/artifacts/{artifact_id}')
                require(not artifact['expired'], 'Artifact expired')
                require(artifact['workflow_run']['id'] == expected['run_id'], 'Artifact run mismatch')
                archive = root / f'{artifact_id}.zip'
                with archive.open('wb') as stream:
                    subprocess.run(['gh', 'api', f'repos/{CONFIG["repo"]}/actions/artifacts/{artifact_id}/zip'], stdout=stream, check=True)
                archives[artifact_id] = archive
            with zipfile.ZipFile(archives[artifact_id]) as archive:
                matches = [name for name in archive.namelist() if Path(name).name == expected['source_name']]
                require(len(matches) == 1, 'Artifact package missing or ambiguous')
                data = archive.read(matches[0])
            require(len(data) == expected['size'], 'Downloaded package size mismatch')
            require(hashlib.sha256(data).hexdigest() == expected['sha256'], 'Downloaded package hash mismatch')
            target = root / expected['name']
            target.write_bytes(data)
            staged[expected['name']] = target
        # Verify all six files before the first upload. Existing exact matches are
        # left untouched so a failed upload job can safely resume.
        for expected in CONFIG['assets']:
            if expected['name'] not in read_release():
                gh('release', 'upload', CONFIG['tag'], str(staged[expected['name']]), '--repo', CONFIG['repo'])
            require(expected['name'] in read_release(), 'Uploaded asset missing')
        require(set(read_release()) == set(EXPECTED), 'Final asset set incomplete')
    print('All six pinned packages uploaded and verified. Release remains a draft.')


class GuardTests(unittest.TestCase):
    def release(self):
        return {'id': CONFIG['release_id'], 'tag_name': CONFIG['tag'], 'draft': True, 'prerelease': False, 'assets': []}

    def asset(self):
        expected = CONFIG['assets'][0]
        return {**expected, 'state': 'uploaded', 'digest': 'sha256:' + expected['sha256']}

    def test_empty_and_exact_existing_assets_are_allowed(self):
        release = self.release()
        self.assertEqual(validate_release(release), {})
        release['assets'] = [self.asset()]
        self.assertEqual(set(validate_release(release)), {self.asset()['name']})

    def test_wrong_release_or_published_release_is_rejected(self):
        for key, value in [('id', 0), ('tag_name', 'v1.7.0'), ('draft', False), ('prerelease', True)]:
            release = self.release()
            release[key] = value
            with self.assertRaises(ValueError):
                validate_release(release)

    def test_extra_duplicate_and_wrong_hash_assets_are_rejected(self):
        for change in [{'name': 'SHA256SUMS.txt'}, {'size': 1}, {'digest': 'sha256:bad'}, {'state': 'starter'}]:
            release = self.release()
            release['assets'] = [{**self.asset(), **change}]
            with self.assertRaises(ValueError):
                validate_release(release)
        release = self.release()
        release['assets'] = [self.asset(), copy.deepcopy(self.asset())]
        with self.assertRaises(ValueError):
            validate_release(release)


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit('Unsupported arguments')
