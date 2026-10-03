"""One-time additive Linux publication. Never update tags or replace assets.

Fill reviewed constants only after both PRs merge and exact dev push CI passes.
All package/source/release validations complete before any external write.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile
import zipfile

REPO = 'L1Xu4n/FocuBili'
RELEASE_ID = 402088227
TAG = 'v1.7.0'
TAG_OBJECT = '051200185455c217a90cf52634c6139d46ce085d'
# REQUIRED: intentionally unusable until final combined dev source is selected.
SOURCE_SHA = 'd46cd909b34d98f8a4b878b53f5b6ff20577aef5'
LINUX_RUN = 37141398020
ARTIFACT_ID = 11280398025
ARTIFACT_DIGEST = 'sha256:231a45638b9d470abbee7b137fac6e0fb16fbe5e66130e9e6a2cf8474e4358c8'
DEB = 'FocuBili-v1.7.0-linux-amd64.deb'
TAR = 'FocuBili-v1.7.0-linux-x64.tar.gz'
SUMS = 'FocuBili-v1.7.0-linux-SHA256SUMS.txt'
PACKAGE_SHA256 = {DEB: '0d66a3150ef9b9810778edb465b8ea003ff564137f057eda3f724342cb2d6c03', TAR: '53a6a917c6d9798f216d10ca414f17cafa36d9bdf1491b681a88561e5ca1faf3'}
NORMAL_EXECUTABLE_SHA256 = 'a68337ad53cbc3a221266cb476e6ff710b92377270c27f57ad09bb2bb9987dd7'
NORMAL_LIBAPP_SHA256 = '0767f047c09e74c690bb63837879bab281abe3c1db7dd22d400ca9ecdf9b8040'
BASELINE = json.loads(Path(__file__).with_name('linux_v170_baseline.json').read_text())
START = '<!-- focubili-linux-v170:start -->'
END = '<!-- focubili-linux-v170:end -->'
META = ('id', 'tag_name', 'name', 'target_commitish', 'draft', 'prerelease', 'immutable')
HELPERS = {'.github/workflows/publish-linux-v170.yml', 'tool/publish_linux_v170.py',
           'tool/linux_v170_baseline.json', 'tool/test_publish_linux_v170.py'}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def gh(*args, binary=False):
    return subprocess.check_output(['gh', *args], text=not binary)


def api(path):
    return json.loads(gh('api', f'repos/{REPO}/{path}'))


def asset_map(release):
    assets = release['assets']
    result = {a['name']: a for a in assets}
    require(len(result) == len(assets), 'Duplicate release asset names')
    return result


def check_release(release, body=None):
    require(all(release.get(k) == BASELINE.get(k) for k in META), 'Release metadata mismatch')
    assets = asset_map(release)
    old = asset_map(BASELINE)
    require(set(assets) <= set(old) | {DEB, TAR, SUMS}, 'Unexpected release assets')
    for name, original in old.items():
        require(name in assets, f'Missing original asset: {name}')
        require(all(assets[name].get(k) == original.get(k)
                    for k in ('id', 'size', 'digest', 'state', 'label', 'content_type')),
                f'Original asset changed: {name}')
    require(api(f'git/ref/tags/{TAG}')['object']['sha'] == TAG_OBJECT, 'Release tag moved')
    if body is not None:
        require(release['body'] == body, 'Release notes changed concurrently')


def check_pins():
    require(re.fullmatch('[0-9a-f]{40}', SOURCE_SHA), 'Fill final source pin')
    require(LINUX_RUN > 0 and ARTIFACT_ID > 0, 'Fill run and artifact pins')
    for digest in [ARTIFACT_DIGEST.removeprefix('sha256:'),
                   *PACKAGE_SHA256.values(), NORMAL_EXECUTABLE_SHA256, NORMAL_LIBAPP_SHA256]:
        require(re.fullmatch('[0-9a-f]{64}', digest), 'Fill all SHA256 pins')
    require(ARTIFACT_DIGEST.startswith('sha256:'), 'Malformed artifact digest')


def check_source():
    check_pins()
    require(os.environ.get('GITHUB_REPOSITORY') == REPO, 'Wrong repository')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/dev', 'Only dev push allowed')
    require(os.environ.get('GITHUB_EVENT_NAME') == 'push', 'Only push allowed')
    head = os.environ['GITHUB_SHA']
    require(api('git/ref/heads/dev')['object']['sha'] == head, 'Dev moved')
    comparison = api(f'compare/{SOURCE_SHA}...{head}')
    require(comparison['status'] in ('ahead', 'identical'), 'Source is not merged into dev')
    require(all(f['filename'] in HELPERS for f in comparison['files']), 'Application changed after build')
    for number in (35, 36):
        pr = api(f'pulls/{number}')
        require(pr['merged'] and pr['base']['ref'] == 'dev', f'PR {number} not merged to dev')
        merged = api(f'compare/{pr["merge_commit_sha"]}...{SOURCE_SHA}')
        require(merged['status'] in ('ahead', 'identical'), f'Source excludes PR {number}')
    run = api(f'actions/runs/{LINUX_RUN}')
    require(run['head_sha'] == SOURCE_SHA and run['head_branch'] == 'dev'
            and run['event'] == 'push' and run['path'] == '.github/workflows/linux-build.yml'
            and run['status'] == 'completed' and run['conclusion'] == 'success', 'Linux run mismatch')
    jobs = api(f'actions/runs/{LINUX_RUN}/jobs?per_page=100')
    require(jobs['total_count'] == 1, 'Unexpected Linux job count')
    job = jobs['jobs'][0]
    require(job['conclusion'] == 'success' and 'ubuntu-24.04' in job['labels'], 'Wrong native runner')
    names = ['Build normal release application', 'Package installable application',
             'Test normal application startup and single instance',
             'Build standalone native runtime probe', 'Test real Linux desktop services and media']
    steps = job['steps']
    indices = []
    for name in names:
        found = [(i, s) for i, s in enumerate(steps) if s['name'] == name]
        require(len(found) == 1 and found[0][1]['conclusion'] == 'success', f'Failed/missing step: {name}')
        indices.append(found[0][0])
    require(indices == sorted(indices), 'Packages not built before runtime probe')
    return head


def tar_entries(data):
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        for member in archive.getmembers():
            name = member.name.removeprefix('./').rstrip('/')
            if name in ('', '.'):
                require(member.isdir(), 'Invalid tar root')
                continue
            require(not name.startswith('/') and '..' not in PurePosixPath(name).parts, 'Unsafe tar path')
            require(name not in entries, 'Duplicate tar path')
            require(member.isfile() or member.isdir() or member.issym(), 'Unsupported tar member')
            require(not member.mode & (0o6000 if member.issym() else 0o6022), 'Unsafe package permissions')
            if member.issym():
                require(not member.linkname.startswith('/') and '..' not in PurePosixPath(member.linkname).parts,
                        'Unsafe bundle symlink')
            entries[name] = (member, archive.extractfile(member).read() if member.isfile() else None)
    return entries


def validate_packages(payloads):
    # dpkg-deb is read-only: never install or run untrusted package contents.
    with tempfile.TemporaryDirectory() as work:
        deb = Path(work) / DEB
        deb.write_bytes(payloads[DEB])
        for field, expected in [('Package', 'focubili'), ('Version', '1.7.0'), ('Architecture', 'amd64')]:
            actual = subprocess.check_output(['dpkg-deb', '-f', str(deb), field], text=True).strip()
            require(actual == expected, f'DEB {field} mismatch')
        data = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(deb)])
        # DEB contains the intentional absolute /usr/bin launcher symlink.
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as t:
            seen = set()
            bundle = {}
            for m in t.getmembers():
                n = m.name.removeprefix('./').rstrip('/')
                require(n not in seen, 'Duplicate DEB path')
                seen.add(n)
                require(not n.startswith('/') and '..' not in PurePosixPath(n).parts, 'Unsafe DEB path')
                require(m.uid == 0 and m.gid == 0 and not m.mode & (0o6000 if m.issym() else 0o6022), 'DEB root ownership/permissions mismatch')
                require(m.isfile() or m.isdir() or m.issym(), 'Unsupported DEB member')
                if m.issym():
                    require((n == 'usr/bin/focubili' and m.linkname == '/opt/focubili/focubili') or
                            (not m.linkname.startswith('/') and '..' not in PurePosixPath(m.linkname).parts),
                            'Unsafe DEB symlink')
                if n.startswith('opt/focubili/'):
                    bundle[n[len('opt/focubili/'):]] = (m, t.extractfile(m).read() if m.isfile() else None)
            require('usr/bin/focubili' in seen, 'Missing launcher')
        normal = tar_entries(payloads[TAR])
        require(set(normal) == set(bundle), 'DEB/tar bundle paths differ')
        for name, (m, content) in normal.items():
            d, deb_content = bundle[name]
            require((m.type, m.mode, m.linkname, content) == (d.type, d.mode, d.linkname, deb_content),
                    f'DEB/tar bundle mismatch: {name}')
        for name, digest in [('focubili', NORMAL_EXECUTABLE_SHA256), ('lib/libapp.so', NORMAL_LIBAPP_SHA256)]:
            require(name in normal and normal[name][0].isfile() and sha(normal[name][1]) == digest,
                    f'Normal application pin mismatch: {name}')
        require(normal['focubili'][0].mode & 0o111, 'Application is not executable')
        for name in ('focubili', 'lib/libapp.so'):
            elf = normal[name][1]
            require(elf[:6] == b'\x7fELF\x02\x01' and elf[18:20] == b'\x3e\x00', 'Not x86-64 ELF')


def prepare_payloads():
    artifact = api(f'actions/artifacts/{ARTIFACT_ID}')
    require(artifact['id'] == ARTIFACT_ID and artifact['name'] == f'focubili-linux-{SOURCE_SHA}'
            and artifact['digest'] == ARTIFACT_DIGEST and not artifact['expired']
            and artifact['workflow_run']['id'] == LINUX_RUN
            and artifact['workflow_run']['head_sha'] == SOURCE_SHA, 'Artifact metadata mismatch')
    archive = gh('api', f'repos/{REPO}/actions/artifacts/{ARTIFACT_ID}/zip', binary=True)
    require('sha256:' + sha(archive) == ARTIFACT_DIGEST, 'Artifact archive checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        for name in (DEB, TAR, 'SHA256SUMS.txt'):
            require(z.namelist().count(name) == 1, f'Missing/duplicate artifact file: {name}')
        payloads = {name: z.read(name) for name in (DEB, TAR)}
        sums = {}
        for line in z.read('SHA256SUMS.txt').decode().splitlines():
            digest, name = line.split(maxsplit=1)
            name = name.strip().removeprefix('*').removeprefix('./')
            require(name not in sums, 'Duplicate checksum')
            sums[name] = digest
        require(set(sums) == {DEB, TAR}, 'Unexpected checksum manifest')
        for name, data in payloads.items():
            require(sha(data) == sums[name] == PACKAGE_SHA256[name], f'Package checksum mismatch: {name}')
    validate_packages(payloads)
    payloads[SUMS] = ''.join(f'{sha(payloads[n])}  {n}\n' for n in (DEB, TAR)).encode()
    return payloads


def build_body(payloads):
    section = f'''{START}
## Linux 1.7.0 补充

- 提供 Ubuntu 24.04 amd64 / x86-64 的 DEB 和 tar.gz；不承诺旧版 Ubuntu、其他发行版或 ARM 兼容。
- 推荐使用 `sudo apt install ./FocuBili-v1.7.0-linux-amd64.deb` 安装，以便解析系统依赖。tar.gz 不是静态免依赖包；需要 GTK 3、mpv、libsecret、JsonCpp、ALSA、WebKitGTK 4.1 和桌面 portal；建议安装 GNOME Keyring 与 GTK portal 后端。
- 构建 CI 已执行正常应用启动/单实例检查，以及独立运行探针的桌面服务和媒体检查；探针不是发布安装包。
- CI 使用 Ubuntu 24.04 虚拟桌面。真实账号登录、真实桌面/显卡与 Wayland 环境、长时间播放及跨版本数据迁移仍需实机验证；本次不宣称上述场景已全面验收。更新前请备份重要本地数据。

Linux 构建源码：[`{SOURCE_SHA}`](https://github.com/{REPO}/commit/{SOURCE_SHA})，已合入 dev；[Linux CI {LINUX_RUN}](https://github.com/{REPO}/actions/runs/{LINUX_RUN})。
原 v1.7.0 标签、原有 Android / Windows / iOS / macOS 安装包保持不变；标签自动生成的源码压缩包不包含之后新增的 Linux 适配，请使用上述提交。

| 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
'''
    for name, data in payloads.items():
        section += f'| `{name}` | {len(data)} | `{sha(data)}` |\n'
    return BASELINE['body'] + '\n\n' + section + END + '\n'


def check_existing(release, payloads):
    assets = asset_map(release)
    for name, data in payloads.items():
        if name in assets:
            a = assets[name]
            require((a['size'], a['digest'], a['state']) == (len(data), 'sha256:' + sha(data), 'uploaded'),
                    f'Different existing Linux asset; refusing all writes: {name}')
    return assets


def publish(payloads, head):
    body = build_body(payloads)
    current = api(f'releases/{RELEASE_ID}')
    check_release(current)
    require(current['body'] in (BASELINE['body'], body), 'Release body mismatch; do not overwrite edits')
    check_existing(current, payloads)
    require(api('git/ref/heads/dev')['object']['sha'] == head, 'Dev moved during preparation')
    with tempfile.TemporaryDirectory() as work:
        out = Path(work)
        if current['body'] != body:
            patch = out / 'release-body.json'
            patch.write_text(json.dumps({'body': body}, ensure_ascii=False))
            gh('api', '--method', 'PATCH', f'repos/{REPO}/releases/{RELEASE_ID}', '--input', str(patch))
        for name, data in payloads.items():
            # Re-read before every upload; any conflicting asset stops without clobber.
            current = api(f'releases/{RELEASE_ID}')
            check_release(current, body)
            existing = check_existing(current, payloads)
            if name not in existing:
                path = out / name
                path.write_bytes(data)
                gh('release', 'upload', TAG, str(path), '--repo', REPO)
        final = api(f'releases/{RELEASE_ID}')
        check_release(final, body)
        assets = check_existing(final, payloads)
        for name, data in payloads.items():
            require(name in assets, f'Upload missing: {name}')
            downloaded = gh('api', f'repos/{REPO}/releases/assets/{assets[name]["id"]}',
                            '-H', 'Accept: application/octet-stream', binary=True)
            require(sha(downloaded) == sha(data), f'Published bytes mismatch: {name}')
    print('LINUX_RELEASE_PUBLISHED_AND_VERIFIED')


def main():
    head = check_source()
    publish(prepare_payloads(), head)


if __name__ == '__main__':
    main()
