"""Run synthetic WK persistence with a stable bundle identity, never a user app."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    if os.environ.get('CI') != 'true':
        raise SystemExit('Persistent cookie probe runs only in a clean CI host')
    with tempfile.TemporaryDirectory(prefix='focubili-cookie-probe-') as temporary:
        bundle = Path(temporary) / 'FocuBiliSessionProbe.app'
        binary = bundle / 'Contents/MacOS/FocuBiliSessionProbe'
        binary.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.focubili.sessionprobe',
            'CFBundleExecutable': binary.name,
            'CFBundlePackageType': 'APPL',
            'CFBundleName': 'FocuBiliSessionProbe',
            'CFBundleVersion': '1',
            'LSUIElement': True,
        }))
        subprocess.run(['swiftc', 'packages/focubili_apple/macos/Classes/BilibiliPlaybackSession.swift',
                        'tool/bilibili_session_probe.swift', '-o', str(binary)], check=True)
        for phase in [[], ['persistent-write'], ['persistent-read']]:
            subprocess.run([str(binary), *phase], check=True, timeout=60)


if __name__ == '__main__':
    main()
