"""One-time, additive v1.7.0 Apple publication; never moves the release tag."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import zipfile

REPO = 'L1Xu4n/FocuBili'
RELEASE_ID = 402088227
TAG = 'v1.7.0'
TAG_OBJECT = '051200185455c217a90cf52634c6139d46ce085d'
SOURCE_SHA = 'c5e00cf15476baa1425b38a0be5b02ac5bb029d1'
APPLE_RUN = 37117739928
BASELINE_RUN = 37117739960
ARTIFACT_PINS = {
    'ios': (11273297976, 'sha256:32ad458c6b8f0dd065353c3ba5f61292222fc69e493a96cdb5ea701f67e2cf2c'),
    'macos': (11272625337, 'sha256:1f209547e3cade3526a4fc77065847653a4ca708bcb16e4b0b8c23604deb5661'),
}
OLD_ASSETS = {
    'FocuBili-v1.7.0-android.apk': (606302402, 33393099, 'adc453f286e61d8c89650ddaba73c904ded53eb3e6f71c125304cc33e6abccbf'),
    'FocuBili-v1.7.0-windows-x64-portable.zip': (606302405, 38239068, 'c6b48738945dbc67d63e513875a6f23da974cc4681124037270d078fb646de61'),
    'FocuBili-v1.7.0-windows-x64-setup.exe': (606302403, 28064794, 'bbb198de57effc6a5d10f031e448abfb8f4ff07395cc9b9ad52a6ec63653437b'),
}

def gh(*args, binary=False):
    return subprocess.check_output(['gh', *args], text=not binary)

def api(path):
    return json.loads(gh('api', f'repos/{REPO}/{path}'))

def check_originals(release):
    assert release['id'] == RELEASE_ID and release['tag_name'] == TAG
    assert not release['draft'] and not release['prerelease']
    assert not release.get('immutable', False)
    assets = {a['name']: a for a in release['assets']}
    for name, (ident, size, digest) in OLD_ASSETS.items():
        asset = assets[name]
        assert (asset['id'], asset['size'], asset['digest']) == (ident, size, f'sha256:{digest}')
    assert api(f'git/ref/tags/{TAG}')['object']['sha'] == TAG_OBJECT


def main():
    assert os.environ['GITHUB_REPOSITORY'] == REPO
    assert os.environ['GITHUB_REF'] == 'refs/heads/master'
    master = api('git/ref/heads/master')['object']['sha']
    assert master == os.environ['GITHUB_SHA'], 'Master moved; inspect before retrying'
    subprocess.run(['git', 'merge-base', '--is-ancestor', SOURCE_SHA, 'HEAD'], check=True)
    changed = gh('api', f'repos/{REPO}/compare/{SOURCE_SHA}...{master}')
    comparison = json.loads(changed)
    allowed = {'.github/workflows/publish-apple-v170.yml', 'tool/publish_apple_v170.py', '.github/workflows/release-build.yml'}
    assert all(f['filename'] in allowed for f in comparison['files']), 'Application source changed'
    for run_id, workflow in [(APPLE_RUN, '.github/workflows/apple-build.yml'), (BASELINE_RUN, '.github/workflows/ci.yml')]:
        run = api(f'actions/runs/{run_id}')
        assert run['head_sha'] == SOURCE_SHA and run['head_branch'] == 'dev'
        assert run['event'] == 'push' and run['path'] == workflow
        assert run['status'] == 'completed' and run['conclusion'] == 'success'
    release = api(f'releases/{RELEASE_ID}')
    check_originals(release)
    original_body = release['body'] or ''
    original_metadata = {k: release[k] for k in ('name', 'target_commitish', 'draft', 'prerelease')}
    out = Path('apple-release-staging')
    out.mkdir(exist_ok=True)
    artifacts = api(f'actions/runs/{APPLE_RUN}/artifacts')['artifacts']
    files = []
    for platform, internal, public in [
        ('ios', 'FocuBili-ios-unsigned.ipa', 'FocuBili-v1.7.0-ios.ipa'),
        ('macos', 'FocuBili-macos-preview.dmg', 'FocuBili-v1.7.0-macos.dmg'),
    ]:
        matching = [a for a in artifacts if a['name'] == f'focubili-apple-{platform}-{SOURCE_SHA}']
        assert len(matching) == 1
        artifact = matching[0]
        assert (artifact['id'], artifact['digest']) == ARTIFACT_PINS[platform]
        assert not artifact['expired'] and artifact['workflow_run']['head_sha'] == SOURCE_SHA
        archive = gh('api', f'repos/{REPO}/actions/artifacts/{artifact["id"]}/zip', binary=True)
        assert 'sha256:' + hashlib.sha256(archive).hexdigest() == artifact['digest']
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            assert z.namelist().count(internal) == 1 and z.namelist().count('SHA256SUMS.txt') == 1
            payload = z.read(internal)
            sums = z.read('SHA256SUMS.txt').decode().splitlines()
            matching_sums = [s.split()[0].lower() for s in sums if s.split() and s.split()[-1].lstrip('*').split('/')[-1] == internal]
            digest = hashlib.sha256(payload).hexdigest()
            assert matching_sums == [digest], 'Artifact package checksum mismatch'
        if platform == 'ios':
            with zipfile.ZipFile(io.BytesIO(payload)) as ipa:
                infos = [n for n in ipa.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
                assert len(infos) == 1
                info = plistlib.loads(ipa.read(infos[0]))
                assert info['CFBundleIdentifier'] == 'com.focubili.app'
                assert info['CFBundleShortVersionString'] == '1.7.0' and str(info['CFBundleVersion']) == '20'
        target = out / public
        target.write_bytes(payload)
        files.append((target, len(payload), digest))
    # All payload checks finish before the first external write.
    current = api(f'releases/{RELEASE_ID}')
    check_originals(current)
    assert current['body'] == original_body, 'Release notes changed concurrently'
    existing = {a['name']: a for a in current['assets']}
    for path, size, digest in files:
        if path.name in existing:
            a = existing[path.name]
            assert a['size'] == size and a['digest'] == f'sha256:{digest}' and a['state'] == 'uploaded', 'Different existing Apple asset; do not overwrite'
    assert {k: current[k] for k in original_metadata} == original_metadata
    start, end = '<!-- focubili-apple-v170:start -->', '<!-- focubili-apple-v170:end -->'
    section = f'''{start}
## iOS / macOS 正式版补充（2026-10-03）

本次补充 FocuBili 1.7.0 的 iOS 与 macOS 安装包，包含圆角与深色图标。

- iOS：下载 IPA 后需自行签名安装；免费个人签名通常需要每七天刷新。这不是 App Store 或 TestFlight 分发。
- macOS：DMG 内的 App 使用 ad-hoc 签名，未进行 Apple 公证；首次安装可能被系统限制。
- 已通过 Apple 编译、模拟器/原生播放检查、iOS 系统画中画、Mac 原生视频小窗及同身份覆盖升级数据保留检查。
- 尚无 Apple 真机验收；真实账号登录、长时间后台播放、功耗及跨签名身份迁移仍需实测。
- 更新时沿用原有签名身份与应用标识，覆盖安装前先备份重要笔记。画中画/视频小窗不包含 Flutter 字幕和弹幕叠加。

Apple 构建源码：[`{SOURCE_SHA}`](https://github.com/{REPO}/commit/{SOURCE_SHA})，已合入主分支；[Apple CI {APPLE_RUN}](https://github.com/{REPO}/actions/runs/{APPLE_RUN})。
原 v1.7.0 标签及 Android/Windows 安装包保持不变。Apple 适配为之后新增，原标签的源码压缩包不包含这些新增代码，请使用上述提交。

| 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
'''
    for path, size, digest in files:
        section += f'| `{path.name}` | {size} | `{digest}` |\n'
    section += end
    body = original_body
    if start in body:
        assert body.count(start) == 1 and body.count(end) == 1
        a, rest = body.split(start)
        _, b = rest.split(end)
        body = a + section + b
    else:
        body = body.rstrip() + '\n\n' + section + '\n'
    body = body.replace('后续将进行 iOS、macOS 系统适配；下个大版本将对学习清单进行体验升级。', 'iOS、macOS 安装包已补充，见下方安装说明；下个大版本将对学习清单进行体验升级。')
    body = body.replace('本次仍发布 Android 与 Windows 版本。', '本版本提供 Android、Windows、iOS 与 macOS 安装包，各平台签名和安装要求见下方说明。')
    patch = out / 'release-body.json'
    patch.write_text(json.dumps({'body': body}, ensure_ascii=False))
    assert api('git/ref/heads/master')['object']['sha'] == master, 'Master moved during preparation'
    gh('api', '--method', 'PATCH', f'repos/{REPO}/releases/{RELEASE_ID}', '--input', str(patch))
    # Publish installation caveats before exposing new installable assets.
    refreshed = api(f'releases/{RELEASE_ID}')
    check_originals(refreshed)
    assert refreshed['body'] == body
    assert {k: refreshed[k] for k in original_metadata} == original_metadata
    for path, size, digest in files:
        if path.name not in existing:
            gh('release', 'upload', TAG, str(path), '--repo', REPO)
    final = api(f'releases/{RELEASE_ID}')
    check_originals(final)
    assert final['body'] == body
    assert {k: final[k] for k in original_metadata} == original_metadata
    for path, size, digest in files:
        a = next(a for a in final['assets'] if a['name'] == path.name)
        assert a['size'] == size and a['digest'] == f'sha256:{digest}' and a['state'] == 'uploaded'
        downloaded = gh('api', f'repos/{REPO}/releases/assets/{a["id"]}', '-H', 'Accept: application/octet-stream', binary=True)
        assert hashlib.sha256(downloaded).hexdigest() == digest
    print('APPLE_RELEASE_PUBLISHED_AND_VERIFIED')
    # User-requested cleanup, only after release verification. Preserve moved branches.
    feature_sha = '8841ec17750d2b168760ce9d2bf97d048d5c27e4'
    pr = api('pulls/33')
    assert pr['merged'] and pr['head']['sha'] == feature_sha
    subprocess.run(['git', 'merge-base', '--is-ancestor', feature_sha, 'HEAD'], check=True)
    refs = api('git/matching-refs/heads/feat/platform-dark-icons')
    exact = [r for r in refs if r['ref'] == 'refs/heads/feat/platform-dark-icons']
    if exact:
        assert len(exact) == 1 and exact[0]['object']['sha'] == feature_sha
        gh('api', '--method', 'DELETE', f'repos/{REPO}/git/refs/heads/feat/platform-dark-icons')
    assert not [r for r in api('git/matching-refs/heads/feat/platform-dark-icons') if r['ref'] == 'refs/heads/feat/platform-dark-icons']
    print('MERGED_ICON_FEATURE_BRANCH_REMOVED')

if __name__ == '__main__':
    main()
