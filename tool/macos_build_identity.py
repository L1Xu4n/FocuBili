"""Bind the signed macOS bundle to the same identity displayed by Dart."""
from datetime import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess


def read_identity(metadata, source_sha, version):
    def value(name):
        match = re.search(r'const String ' + name + r' = ("[^"\n]*");', metadata)
        assert match, f'Missing generated {name}'
        return json.loads(match[1])

    revision = value('appSourceRevision')
    timestamp = value('appBuildTime')
    assert re.fullmatch(r'[0-9a-f]{40}', source_sha)
    assert revision == source_sha, 'Dart build source differs from checkout'
    assert value('appFallbackVersion') == version, 'Dart build version differs from pubspec'
    assert timestamp.endswith('Z'), 'Build time must be UTC'
    parsed = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    assert parsed.year >= 2026, 'Invalid generated build time'
    return {'FocuBiliSourceRevision': revision, 'FocuBiliBuildTime': timestamp}


def verify_bundle_identity(info, identity):
    for key, expected in identity.items():
        assert info.get(key) == expected, f'Bundle {key} differs from Dart build identity'


def main():
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$',
                      Path('pubspec.yaml').read_text(), re.M)
    assert match, 'Project version missing'
    identity = read_identity(Path('lib/core/build_metadata.g.dart').read_text(), source_sha, match[1])
    target = Path('macos/Runner/Info.plist')
    info = plistlib.loads(target.read_bytes())
    info.update(identity)
    target.write_bytes(plistlib.dumps(info, sort_keys=False))
    print('MACOS_BUILD_IDENTITY_BOUND_TO_DART')


if __name__ == '__main__':
    main()
