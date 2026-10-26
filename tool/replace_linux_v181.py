"""One-time, reversible v1.8.1 DEB metadata repair; never rebuild the app.

Run prepare, independently verify the public candidate, then run promote with
that SHA256. The original asset is renamed to a backup, never deleted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote

REPO = 'L1Xu4n/FocuBili'
SOURCE = '7e5e5091aa822fcc91ee2be41148e5f0765afe7a'
TAG_OBJECT = '59157907a94ea62172a978f1f047281dd57deed5'
NAME = 'FocuBili-v1.8.1-linux-amd64.deb'
SNAPSHOT = json.loads(Path(__file__).with_name('linux_v181_replacement_snapshot.json').read_text())
OLD = next(a for a in SNAPSHOT['assets'] if a['name'] == NAME)
BACKUP = NAME + '.backup-' + OLD['digest'].split(':')[1][:16]
HELPERS = {'.github/workflows/publish-release.yml', 'tool/replace_linux_v181.py',
           'tool/test_replace_linux_v181.py', 'tool/linux_v181_replacement_snapshot.json'}
META = ('id', 'tag_name', 'name', 'target_commitish', 'draft', 'prerelease',
        'immutable', 'created_at', 'published_at')
FIELDS = ('id', 'name', 'size', 'digest', 'state', 'label', 'content_type',
          'created_at', 'updated_at', 'browser_download_url')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def command(*args, binary=False, **kwargs):
    return subprocess.check_output(args, text=not binary, **kwargs)


def api(path):
    return json.loads(command('gh', 'api', f'repos/{REPO}/{path}'))


def assets(release):
    result = {a['name']: a for a in release['assets']}
    require(len(result) == len(release['assets']), 'Duplicate asset names')
    require(len({a['id'] for a in result.values()}) == len(result), 'Duplicate asset IDs')
    return result


def check_release(release, digest=None, size=None):
    require(all(release.get(k) == SNAPSHOT.get(k) for k in META), 'Release metadata changed')
    require(sha(release['body'].encode()) == SNAPSHOT['body_sha256'], 'Release notes changed')
    current = assets(release)
    protected = {a['name']: a for a in SNAPSHOT['assets'] if a['id'] != OLD['id']}
    for name, original in protected.items():
        require(name in current and all(current[name].get(k) == original.get(k) for k in FIELDS),
                f'Protected asset changed: {name}')
    old = next((a for a in current.values() if a['id'] == OLD['id']), None)
    require(old is not None and old['name'] in (NAME, BACKUP), 'Original asset missing/renamed')
    require(all(old.get(k) == OLD.get(k) for k in ('size', 'digest', 'state', 'label', 'content_type')),
            'Original asset bytes/metadata changed')
    extra = [a for a in current.values() if a['id'] not in {v['id'] for v in SNAPSHOT['assets']}]
    require(len(extra) <= 1, 'Unexpected release assets')
    if extra:
        new = extra[0]
        require(digest is not None and size is not None, 'Candidate identity required')
        require(new['name'] in (NAME + '.candidate-' + digest[:16], NAME)
                and new['digest'] == 'sha256:' + digest and new['size'] == size
                and new['state'] == 'uploaded' and new['content_type'] == OLD['content_type'],
                'Candidate identity mismatch')
        require(new['name'] != NAME or old['name'] == BACKUP, 'Canonical name conflict')
    else:
        require(old['name'] == NAME, 'Backup without candidate')
    require(set(current) == set(protected) | {old['name']} | {a['name'] for a in extra},
            'Unexpected asset set')
    return old, extra[0] if extra else None


def check_source():
    require(os.environ.get('GITHUB_REPOSITORY') == REPO, 'Wrong repository')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/master', 'Only master allowed')
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'Only manual dispatch allowed')
    require(os.environ.get('GITHUB_ACTOR') == 'L1Xu4n', 'Wrong dispatch actor')
    head = os.environ['GITHUB_SHA']
    require(api('git/ref/heads/master')['object']['sha'] == head, 'Master moved')
    command('git', 'merge-base', '--is-ancestor', SOURCE, head)
    changed = set(command('git', 'diff', '--name-only', SOURCE, head).splitlines())
    require(changed <= HELPERS, 'Application or packaging changed after verified source')
    require(api('git/ref/tags/v1.8.1')['object']['sha'] == TAG_OBJECT, 'Release tag moved')
    for workflow in ('ci.yml', 'linux-build.yml', 'apple-build.yml'):
        runs = json.loads(command('gh', 'run', 'list', '--repo', REPO, '--workflow', workflow,
                                 '--branch', 'master', '--commit', head, '--event', 'push',
                                 '--limit', '5', '--json', 'databaseId,headSha,status,conclusion'))
        require(runs and runs[0]['headSha'] == head and runs[0]['status'] == 'completed'
                and runs[0]['conclusion'] == 'success', f'Exact master CI not green: {workflow}')
    return head


def download(asset, path):
    # Public download, with no credential forwarding to the release CDN.
    command('curl', '--fail', '--location', '--retry', '2', '--output', str(path),
            asset['browser_download_url'])
    require(path.stat().st_size == asset['size'] and 'sha256:' + sha(path.read_bytes()) == asset['digest'],
            'Public asset bytes mismatch')


def member(deb, name):
    return command('ar', 'p', str(deb), name, binary=True)


def validate_candidate(old, new):
    require(sha(old.read_bytes()) == OLD['digest'].split(':')[1], 'Wrong original package')
    # The entire compressed payload, not just extracted files, must be identical.
    require(command('ar', 't', str(old)).splitlines() == ['debian-binary', 'control.tar.zst', 'data.tar.zst'],
            'Unexpected original DEB members')
    require(command('ar', 't', str(new)).splitlines() == ['debian-binary', 'control.tar.xz', 'data.tar.zst'],
            'Unexpected repaired DEB members')
    for name in ('debian-binary', 'data.tar.zst'):
        require(member(old, name) == member(new, name), f'Original payload changed: {name}')
    old_control = command('dpkg-deb', '-f', str(old))
    new_control = command('dpkg-deb', '-f', str(new))
    replacement = re.sub(r'^Depends: .*$', 'Depends: ' + SNAPSHOT['depends'], old_control, flags=re.M)
    require(new_control == replacement and new_control != old_control, 'Unexpected control changes')
    require(command('dpkg-deb', '-f', str(new), 'Package', 'Version', 'Architecture').splitlines()
            == ['Package: focubili', 'Version: 1.8.1', 'Architecture: amd64'], 'Wrong package version/architecture')
    return {'data_tar_zst_sha256': sha(member(new, 'data.tar.zst')),
            'old_sha256': sha(old.read_bytes()), 'new_sha256': sha(new.read_bytes()),
            'size': new.stat().st_size, 'depends': SNAPSHOT['depends']}


def build_candidate(old, output):
    require(sha(old.read_bytes()) == OLD['digest'].split(':')[1], 'Wrong original package')
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'root'
        command('dpkg-deb', '-x', str(old), str(root))
        command('dpkg-deb', '-e', str(old), str(root / 'DEBIAN'))
        require(sorted(p.name for p in (root / 'DEBIAN').iterdir()) == ['control'],
                'Unexpected original maintainer scripts')
        deps = command('python3', 'tool/linux_package_dependencies.py', str(root / 'opt/focubili')).strip()
        require(deps + ', xdg-desktop-portal' == SNAPSHOT['depends'], 'Ubuntu 24.04 dependency scan changed')
        control = root / 'DEBIAN/control'
        control.write_text(re.sub(r'^Depends: .*$', 'Depends: ' + SNAPSHOT['depends'],
                                 control.read_text(), flags=re.M))
        generated = Path(tmp) / 'metadata.deb'
        command('dpkg-deb', '-Zxz', '--root-owner-group', '--build', str(root), str(generated),
                env={**os.environ, 'SOURCE_DATE_EPOCH': '1792516447'})
        for name, source in [('debian-binary', old), ('control.tar.xz', generated), ('data.tar.zst', old)]:
            (Path(tmp) / name).write_bytes(member(source, name))
        command('ar', 'crD', str(output.resolve()), 'debian-binary', 'control.tar.xz', 'data.tar.zst', cwd=tmp)
    return validate_candidate(old, output)


def rename(asset_id, name):
    # PATCH only. Never delete or overwrite a release asset.
    return json.loads(command('gh', 'api', '--method', 'PATCH',
                             f'repos/{REPO}/releases/assets/{asset_id}', '-f', f'name={name}'))


def publish(phase, old_path, new_path, expected_sha):
    proof = validate_candidate(old_path, new_path)
    digest, size = proof['new_sha256'], proof['size']
    require(phase == 'prepare' or expected_sha == digest, 'Independently verified candidate SHA required')
    old, new = check_release(api(f'releases/{SNAPSHOT["id"]}'), digest, size)
    stage = NAME + '.candidate-' + digest[:16]
    if phase == 'prepare' and new is None:
        upload = f'https://uploads.github.com/repos/{REPO}/releases/{SNAPSHOT["id"]}/assets?name={quote(stage)}'
        new = json.loads(command('gh', 'api', '--method', 'POST', upload,
                                '-H', 'Content-Type: ' + OLD['content_type'],
                                '-H', f'Content-Length: {size}', '--input', str(new_path)))
        old, new = check_release(api(f'releases/{SNAPSHOT["id"]}'), digest, size)
    require(new is not None, 'Run prepare before promotion')
    public_candidate = new_path.parent / 'public-candidate.deb'
    download(new, public_candidate)
    require(public_candidate.read_bytes() == new_path.read_bytes(), 'Public candidate differs')
    if phase == 'promote':
        if old['name'] == NAME:
            rename(OLD['id'], BACKUP)
            old, new = check_release(api(f'releases/{SNAPSHOT["id"]}'), digest, size)
        if new['name'] != NAME:
            rename(new['id'], NAME)
        old, new = check_release(api(f'releases/{SNAPSHOT["id"]}'), digest, size)
        require(old['name'] == BACKUP and new['name'] == NAME, 'Promotion incomplete')
        download(new, public_candidate)
        validate_candidate(old_path, public_candidate)
        download(old, new_path.parent / 'public-backup.deb')
    proof.update(phase=phase, asset_id=new['id'], url=new['browser_download_url'],
                 backup_name=BACKUP, source=SOURCE, workflow_sha=os.environ['GITHUB_SHA'])
    (new_path.parent / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
    print('LINUX_V181_VERIFIED ' + json.dumps(proof), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'promote'))
    parser.add_argument('--expected-sha', default='')
    args = parser.parse_args()
    check_source()
    out = Path('build/linux-v181-replacement')
    out.mkdir(parents=True, exist_ok=True)
    release = api(f'releases/{SNAPSHOT["id"]}')
    old = next(a for a in release['assets'] if a['id'] == OLD['id'])
    original = out / 'original.deb'
    download(old, original)
    require('sha256:' + sha(original.read_bytes()) == OLD['digest'], 'Wrong original asset')
    candidate = out / NAME
    build_candidate(original, candidate)
    publish(args.phase, original, candidate, args.expected_sha)


if __name__ == '__main__':
    main()
