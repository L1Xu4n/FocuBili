"""One-time, exact-asset cleanup; all conflicts fail closed before the first write.

The canonical CI artifact retains the Linux tar and checksum inputs. Original
asset bytes were also backed up before authorizing cleanup. No tags are changed.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import publish_linux_v170 as p

SNAPSHOT = json.loads(Path(__file__).with_name('linux_v170_cleanup_snapshot.json').read_text())
TARGETS = {
    p.TAR: (608276990, 'sha256:53a6a917c6d9798f216d10ca414f17cafa36d9bdf1491b681a88561e5ca1faf3'),
    p.SUMS: (608277018, 'sha256:6c3ca7ae9be696425ff1dacd4bc30b5b4a0c77b28e963581d8f0637c733f103a'),
}
COMMIT_SUBJECT = 'release: keep Linux v1.7.0 installer only'
ASSET_FIELDS = ('id', 'size', 'digest', 'state', 'label', 'content_type')


def desired_body(payloads):
    old = SNAPSHOT['body']
    p.require(old.count(p.START) == old.count(p.END) == 1, 'Invalid Linux section boundaries')
    new = p.build_body(payloads)
    # Only the previously appended Linux section may change.
    p.require(old.split(p.START)[0] == new.split(p.START)[0]
              and old.split(p.END)[1] == new.split(p.END)[1], 'Non-Linux notes would change')
    return new


def check_release(release, body, head):
    p.require(all(release.get(k) == SNAPSHOT.get(k) for k in p.META), 'Release metadata mismatch')
    before, current = p.asset_map(SNAPSHOT), p.asset_map(release)
    original = p.asset_map(p.BASELINE)
    p.require(set(before) == set(original) | {p.DEB, p.TAR, p.SUMS}, 'Invalid cleanup snapshot asset set')
    for name, asset in original.items():
        p.require(all(before[name].get(k) == asset.get(k) for k in ASSET_FIELDS),
                  f'Original baseline asset differs from cleanup snapshot: {name}')
    p.require(set(TARGETS) == {p.TAR, p.SUMS}, 'Unexpected cleanup target set')
    p.require(set(current) <= set(before), 'Unexpected release asset')
    p.require(len({a['id'] for a in current.values()}) == len(current), 'Duplicate asset IDs')
    for name, original in before.items():
        if name in TARGETS:
            p.require((original['id'], original['digest']) == TARGETS[name], 'Cleanup target pin mismatch')
        else:
            p.require(name in current, f'Missing protected asset: {name}')
        if name in current:
            p.require(all(current[name].get(k) == original.get(k) for k in ASSET_FIELDS),
                      f'Asset changed: {name}')
    p.require(release['body'] in (SNAPSHOT['body'], body), 'Release notes changed concurrently')
    p.require(p.api(f'git/ref/tags/{p.TAG}')['object']['sha'] == p.TAG_OBJECT, 'Release tag moved')
    p.require(p.api('git/ref/heads/dev')['object']['sha'] == head, 'Dev moved during cleanup')
    return current


def cleanup(payloads, head):
    body = desired_body(payloads)
    current = p.api(f'releases/{p.RELEASE_ID}')
    assets = check_release(current, body, head)
    # Verify every still-present deletion target before changing notes or assets.
    # Missing pinned targets are accepted for a safe partial-run retry.
    for name, (ident, digest) in TARGETS.items():
        if name in assets:
            data = p.gh('api', f'repos/{p.REPO}/releases/assets/{ident}',
                        '-H', 'Accept: application/octet-stream', binary=True)
            p.require(len(data) == assets[name]['size'] and 'sha256:' + p.sha(data) == digest,
                      f'Deletion target bytes mismatch: {name}')
    # Ensure the kept DEB bytes match the canonical artifact, not just metadata.
    deb = p.gh('api', f'repos/{p.REPO}/releases/assets/{assets[p.DEB]["id"]}',
               '-H', 'Accept: application/octet-stream', binary=True)
    p.require(deb == payloads[p.DEB], 'Kept DEB bytes mismatch')
    current = p.api(f'releases/{p.RELEASE_ID}')
    check_release(current, body, head)
    if current['body'] != body:
        with tempfile.TemporaryDirectory() as work:
            patch = Path(work) / 'body.json'
            patch.write_text(json.dumps({'body': body}, ensure_ascii=False))
            p.gh('api', '--method', 'PATCH', f'repos/{p.REPO}/releases/{p.RELEASE_ID}', '--input', str(patch))
    for name, (ident, _) in TARGETS.items():
        current = p.api(f'releases/{p.RELEASE_ID}')
        assets = check_release(current, body, head)
        p.require(current['body'] == body, 'Linux notes update missing')
        if name in assets:
            p.gh('api', '--method', 'DELETE', f'repos/{p.REPO}/releases/assets/{ident}')
    final = p.api(f'releases/{p.RELEASE_ID}')
    assets = check_release(final, body, head)
    p.require(not set(TARGETS) & set(assets), 'Cleanup target remains')
    p.require(final['body'] == body, 'Final Linux notes mismatch')
    print('LINUX_INSTALLER_ONLY_CLEANUP_VERIFIED')


def main():
    p.require(subprocess.check_output(['git', 'log', '-1', '--format=%s'], text=True).strip()
              == COMMIT_SUBJECT, 'Wrong cleanup commit subject')
    head = p.check_source()
    cleanup(p.prepare_payloads(), head)


if __name__ == '__main__':
    main()
