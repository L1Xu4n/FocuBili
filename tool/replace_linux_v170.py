"""Pinned, resumable DEB-only replacement. No external writes in prepare mode.

Uses the existing publisher ONLY for archive/package validation; its baseline,
source checks and publication functions are never used. See README before pinning.
"""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
import publish_linux_v170 as p

SOURCE_SHA = '1af1de329a01150f6bc14be8df348376673b6965'
LINUX_RUN = 37171869392
ARTIFACT_ID = 11291863427
ARTIFACT_DIGEST = 'sha256:b889dab5fb3e81a22919d03fba07206e04e13fe542252b8b4feda4b11606a317'
PACKAGE_SHA256 = {p.DEB: '66d17241c13f02c913eb9846a4f1cd6f0b6185da82fa2960326ecbc2b5c8c24e', p.TAR: '9a752c375048bc5aa2a7e626f319e7aab4827a0aa39dc7f15e2ec5dcd1cb01d0'}
NORMAL_EXECUTABLE_SHA256 = '1ffa7c19d94dd6fbbe83bfb360a0c63dee6a34b85eaadc91f34eb53c694f9964'
NORMAL_LIBAPP_SHA256 = '0c86a2a6a02af4a97e03f4c1aa0e558625ed4381ae72dae8f34fe7d68a7cfe40'
# Pin log filename + exact success line emitted by the final CI's new assertions.
RUNTIME_MARKERS = {'linux-runtime.log': ['LINUX_PROBE: stress-expand-2 raster and screenshot passed', 'LINUX_PROBE: stress-expand-3 raster and screenshot passed', 'LINUX_PROBE: stress-expand-4 raster and screenshot passed', 'LINUX_PROBE: stress-expand-5 raster and screenshot passed', 'LINUX_PROBE: stress-expand-6 raster and screenshot passed', 'LINUX_PROBE: stress-expand-7 raster and screenshot passed', 'LINUX_WEBKIT: closed 0', 'LINUX_WEBKIT: closed 1', 'LINUX_WEBKIT: closed 2', 'LINUX_WEBKIT: closed 3', 'LINUX_WEBKIT: closed 4', 'LINUX_WEBKIT: closed 5', 'LINUX_WEBKIT: closed 6', 'LINUX_WEBKIT: closed 7']}
RUNTIME_RUNNER_BLOB = '84017e8d4391a8e86b9b5a537f1facbf05d19fe6'
SNAPSHOT_SHA256 = 'c6f060b9ecb1ab2a9249ee6232feb49d22e9a4541a9af4ed7bfe303a2cc409c0'
SNAPSHOT_PATH = Path(__file__).with_name('linux_v170_render_snapshot.json')
SNAPSHOT = json.loads(SNAPSHOT_PATH.read_text())
OLD_ID = 608276959
OLD_SHA = '0d66a3150ef9b9810778edb465b8ea003ff564137f057eda3f724342cb2d6c03'
OLD_ARTIFACT = 11280398025
OLD_ARCHIVE_SHA = '231a45638b9d470abbee7b137fac6e0fb16fbe5e66130e9e6a2cf8474e4358c8'
SUBJECT = 'release: replace Linux v1.7.0 renderer installer'
FIELDS = ('id', 'size', 'digest', 'state', 'label', 'content_type')
HELPERS = {'tool/replace_linux_v170.py', 'tool/test_replace_linux_v170.py',
           'tool/linux_v170_render_snapshot.json', '.github/workflows/replace-linux-v170.yml'}
STEPS = ['Build normal release application', 'Package installable application',
         'Test normal application startup and single instance',
         'Build standalone native runtime probe', 'Test real Linux desktop services and media']


def stage_name():
    return f'FocuBili-v1.7.0-linux-amd64-staged-{PACKAGE_SHA256[p.DEB][:16]}.deb'


def configure_validator():
    # These seven inputs alone are writable; no baseline/fixture or publication override.
    for name in ('SOURCE_SHA', 'LINUX_RUN', 'ARTIFACT_ID', 'ARTIFACT_DIGEST',
                 'PACKAGE_SHA256', 'NORMAL_EXECUTABLE_SHA256', 'NORMAL_LIBAPP_SHA256'):
        setattr(p, name, globals()[name])
    p.check_pins()
    p.require(PACKAGE_SHA256[p.DEB] != OLD_SHA, 'Replacement must differ')
    p.require(p.sha(SNAPSHOT_PATH.read_bytes()) == SNAPSHOT_SHA256, 'Snapshot not reviewed/pinned')
    p.require(RUNTIME_MARKERS and all('REQUIRED' not in s for k, v in RUNTIME_MARKERS.items()
                                   for s in [k, *v])
              and sum(map(len, RUNTIME_MARKERS.values())) >= 6, 'Pin all six resize evidence lines')


def check_source():
    configure_validator()
    p.require(os.environ.get('GITHUB_REPOSITORY') == p.REPO
              and os.environ.get('GITHUB_REF') == 'refs/heads/dev'
              and os.environ.get('GITHUB_EVENT_NAME') == 'push', 'Only repository dev push allowed')
    p.require(subprocess.check_output(['git', 'log', '-1', '--format=%s'], text=True).strip()
              == SUBJECT, 'Wrong publication commit subject')
    head = os.environ['GITHUB_SHA']
    p.require(p.api('git/ref/heads/dev')['object']['sha'] == head, 'Dev moved')
    compare = p.api(f'compare/{SOURCE_SHA}...{head}')
    p.require(compare['status'] in ('identical', 'ahead') and len(compare['files']) < 300
              and all(f['filename'] in HELPERS and f.get('previous_filename', f['filename']) in HELPERS
                      for f in compare['files']), 'Application differs from tested source')
    for number in (35, 36, 37):
        pr = p.api(f'pulls/{number}')
        p.require(pr['merged'] and pr['base']['ref'] == 'dev', f'PR {number} not merged to dev')
        p.require(p.api(f'compare/{pr["merge_commit_sha"]}...{SOURCE_SHA}')['status']
                  in ('ahead', 'identical'), f'Source excludes PR {number}')
    p.require(p.api(f'contents/tool/linux_runtime_runner.py?ref={SOURCE_SHA}')["sha"]
              == RUNTIME_RUNNER_BLOB, 'Runtime exit validator changed')
    run = p.api(f'actions/runs/{LINUX_RUN}')
    p.require((run['head_sha'], run['head_branch'], run['event'], run['path'], run['status'], run['conclusion'])
              == (SOURCE_SHA, 'dev', 'push', '.github/workflows/linux-build.yml', 'completed', 'success'),
              'Wrong Linux CI run')
    jobs = p.api(f'actions/runs/{LINUX_RUN}/jobs?per_page=100')
    p.require(jobs['total_count'] == 1 and len(jobs['jobs']) == 1, 'Unexpected job count')
    job = jobs['jobs'][0]
    p.require(job['conclusion'] == 'success' and 'ubuntu-24.04' in job['labels'], 'Native CI failed')
    indices = []
    for name in STEPS:
        hits = [(i, s) for i, s in enumerate(job['steps']) if s['name'] == name]
        p.require(len(hits) == 1 and hits[0][1]['conclusion'] == 'success', f'Missing step: {name}')
        indices.append(hits[0][0])
    p.require(indices == sorted(indices), 'Normal package not built before runtime probe')
    return head


def download_asset(asset):
    return p.gh('api', f'repos/{p.REPO}/releases/assets/{asset["id"]}',
                '-H', 'Accept: application/octet-stream', binary=True)


def desired_body(data):
    old = SNAPSHOT['body']
    p.require(old.count(p.START) == old.count(p.END) == 1, 'Bad Linux notes boundaries')
    generated = p.build_body({p.DEB: data})
    section = generated.split(p.START, 1)[1].split(p.END, 1)[0]
    section += '\n- Linux 渲染器更新；CI 已检查 X11 窗口缩放及正常退出。\n'
    return old.split(p.START)[0] + p.START + section + p.END + old.split(p.END)[1]


def check_release(release, body, head, data):
    p.require(all(release.get(k) == SNAPSHOT.get(k) for k in p.META), 'Release metadata changed')
    before, assets = p.asset_map(SNAPSHOT), p.asset_map(release)
    p.require(len(before) == 6 and before[p.DEB]['id'] == OLD_ID
              and before[p.DEB]['digest'] == 'sha256:' + OLD_SHA, 'Wrong original snapshot')
    p.require(set(assets) <= set(before) | {stage_name()}, 'Unexpected release asset')
    p.require(len({a['id'] for a in assets.values()}) == len(assets), 'Duplicate asset IDs')
    for name, original in before.items():
        if name != p.DEB:
            p.require(name in assets and all(assets[name].get(k) == original.get(k) for k in FIELDS),
                      f'Protected asset changed: {name}')
    for name in (p.DEB, stage_name()):
        if name not in assets:
            continue
        asset = assets[name]
        if asset['id'] == OLD_ID:
            p.require(name == p.DEB and all(asset.get(k) == before[p.DEB].get(k) for k in FIELDS),
                      'Original DEB metadata changed')
        else:
            p.require((asset['size'], asset['digest'], asset['state'])
                      == (len(data), 'sha256:' + p.sha(data), 'uploaded')
                      and asset.get('label') in (None, '')
                      and asset['content_type'] == before[p.DEB]['content_type'], 'Conflicting replacement asset')
    p.require(p.DEB in assets or stage_name() in assets, 'Both old and staged installers absent')
    p.require(not (p.DEB in assets and assets[p.DEB]['id'] != OLD_ID and stage_name() in assets),
              'Two replacement installers present')
    p.require(release['body'] in (SNAPSHOT['body'], body), 'Release notes changed concurrently')
    p.require(p.api(f'git/ref/tags/{p.TAG}')['object']['sha'] == p.TAG_OBJECT, 'Tag moved')
    p.require(p.api('git/ref/heads/dev')['object']['sha'] == head, 'Dev moved')
    return assets


def read_checked(body, head, data):
    release = p.api(f'releases/{p.RELEASE_ID}')
    return release, check_release(release, body, head, data)


def verify_bytes(asset, data):
    p.require(download_asset(asset) == data, 'Release asset bytes mismatch')


def old_backup():
    meta = p.api(f'actions/artifacts/{OLD_ARTIFACT}')
    p.require(meta['id'] == OLD_ARTIFACT and not meta['expired']
              and meta['digest'] == 'sha256:' + OLD_ARCHIVE_SHA, 'Old canonical artifact unavailable')
    raw = p.gh('api', f'repos/{p.REPO}/actions/artifacts/{OLD_ARTIFACT}/zip', binary=True)
    p.require(p.sha(raw) == OLD_ARCHIVE_SHA, 'Old artifact hash mismatch')
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        p.require(z.namelist().count(p.DEB) == 1, 'Bad old artifact')
        old = z.read(p.DEB)
    p.require(p.sha(old) == OLD_SHA, 'Wrong old bytes')
    return old


def verify_backup_artifact(old):
    ident = int(os.environ['BACKUP_ARTIFACT_ID'])
    meta = p.api(f'actions/artifacts/{ident}')
    p.require(meta['id'] == ident and not meta['expired']
              and meta['name'] == f'linux-v170-before-render-{os.environ["GITHUB_RUN_ID"]}-{os.environ["GITHUB_RUN_ATTEMPT"]}'
              and meta['workflow_run']['id'] == int(os.environ['GITHUB_RUN_ID'])
              and meta['workflow_run']['head_sha'] == os.environ['GITHUB_SHA'], 'Wrong durable backup')
    raw = p.gh('api', f'repos/{p.REPO}/actions/artifacts/{ident}/zip', binary=True)
    p.require('sha256:' + p.sha(raw) == meta['digest'], 'Backup archive hash mismatch')
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        p.require(z.namelist() == [p.DEB] and z.read(p.DEB) == old, 'Backup does not preserve old DEB')


def validate_runtime_evidence(raw):
    p.require('sha256:' + p.sha(raw) == ARTIFACT_DIGEST, 'Runtime evidence archive changed')
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        for name, markers in RUNTIME_MARKERS.items():
            p.require(z.namelist().count(name) == 1, 'Missing runtime evidence')
            lines = z.read(name).decode().splitlines()
            p.require(all(marker in lines for marker in markers), 'Resize assertion absent')
        p.require(z.namelist().count('linux-runtime.log') == 1, 'Missing GDB evidence')
        transcript = z.read('linux-runtime.log').decode()
        p.require('LINUX_RUNTIME_ALL_CHECKS_PASSED' in transcript
                  and re.search(r'^\[Inferior \d+ \(process \d+\) exited normally\]$', transcript, re.MULTILINE)
                  and not re.search(r'(?:received|terminated with) signal SIG\w+', transcript),
                  'Runtime probe did not exit normally')


def prepare():
    head = check_source()
    data = p.prepare_payloads()[p.DEB]
    # Archive digest is rechecked: logs are evidence from exactly the selected build.
    raw = p.gh('api', f'repos/{p.REPO}/actions/artifacts/{ARTIFACT_ID}/zip', binary=True)
    validate_runtime_evidence(raw)
    old = old_backup()
    body = desired_body(data)
    _, assets = read_checked(body, head, data)
    if p.DEB in assets and assets[p.DEB]['id'] == OLD_ID:
        verify_bytes(assets[p.DEB], old)
    return head, data, old


def patch(path, fields):
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / 'patch.json'
        f.write_text(json.dumps(fields, ensure_ascii=False))
        p.gh('api', '--method', 'PATCH', f'repos/{p.REPO}/{path}', '--input', str(f))


def replace(head, data, old):
    p.require(p.sha(old) == OLD_SHA and p.sha(data) == PACKAGE_SHA256[p.DEB], 'Wrong replacement inputs')
    verify_backup_artifact(old)  # Durable verified backup before any Release write.
    body = desired_body(data)
    _, assets = read_checked(body, head, data)
    if p.DEB in assets and assets[p.DEB]['id'] == OLD_ID:
        verify_bytes(assets[p.DEB], old)
    if stage_name() not in assets and assets.get(p.DEB, {}).get('id') == OLD_ID:
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / stage_name()
            f.write_bytes(data)
            read_checked(body, head, data)
            p.gh('release', 'upload', p.TAG, str(f), '--repo', p.REPO)  # Never --clobber.
    _, assets = read_checked(body, head, data)
    staged = assets.get(stage_name())
    if staged:
        verify_bytes(staged, data)
        _, assets = read_checked(body, head, data)
        p.require(assets[stage_name()]['id'] == staged['id'], 'Staged ID changed')
        if p.DEB in assets:
            p.require(assets[p.DEB]['id'] == OLD_ID, 'Refusing non-original deletion')
            verify_bytes(assets[p.DEB], old)
            _, assets = read_checked(body, head, data)
            p.require(assets[stage_name()]['id'] == staged['id'], 'Staged ID changed')
            p.gh('api', '--method', 'DELETE', f'repos/{p.REPO}/releases/assets/{OLD_ID}')
        _, assets = read_checked(body, head, data)
        p.require(p.DEB not in assets and assets[stage_name()]['id'] == staged['id'], 'Rename conflict')
        patch(f'releases/assets/{staged["id"]}', {'name': p.DEB})
    release, assets = read_checked(body, head, data)
    p.require(p.DEB in assets and assets[p.DEB]['id'] != OLD_ID and stage_name() not in assets,
              'Replacement not at final name')
    verify_bytes(assets[p.DEB], data)
    release, assets = read_checked(body, head, data)
    if release['body'] != body:
        patch(f'releases/{p.RELEASE_ID}', {'body': body})
    release, assets = read_checked(body, head, data)
    p.require(release['body'] == body and len(assets) == 6 and assets[p.DEB]['id'] != OLD_ID,
              'Final release mismatch')
    verify_bytes(assets[p.DEB], data)
    print('LINUX_RENDERER_INSTALLER_REPLACED_AND_VERIFIED')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'apply'])
    args = parser.parse_args()
    head, data, old = prepare()
    if args.mode == 'prepare':
        out = Path('linux-render-backup')
        out.mkdir(exist_ok=True)
        (out / p.DEB).write_bytes(old)
    else:
        replace(head, data, old)


if __name__ == '__main__':
    main()
