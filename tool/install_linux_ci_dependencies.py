#!/usr/bin/env python3
"""Acquire CI dependencies with one bounded, official-Ubuntu fallback.

Run as root on ubuntu-24.04 amd64. Only update/download are timed out;
installation uses the fully acquired archives and is never timed out here.
No persistent APT sources/configuration are changed.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

PACKAGES = '''clang cmake ninja-build pkg-config dpkg-dev binutils python3
libgtk-3-dev libmpv-dev libsecret-1-dev libasound2-dev libwebkit2gtk-4.1-dev
xvfb dbus-x11 openbox dunst scrot gdb gnome-keyring xdg-desktop-portal-gtk
desktop-file-utils'''.split()
ACQUIRE = ['-o', 'Acquire::Retries=1', '-o', 'Acquire::http::Timeout=15',
           '-o', 'Acquire::https::Timeout=15']


def apt_options(folder, fallback):
    # Fresh lists also keep stale third-party indexes out of the fallback solver.
    folder.mkdir()
    folder.chmod(0o755)
    for relative in ('lists', 'lists/partial', 'archives', 'archives/partial'):
        (folder / relative).mkdir(mode=0o755)
    options = ACQUIRE + ['-o', f'Dir::State::lists={folder}/lists',
                         '-o', f'Dir::Cache::archives={folder}/archives']
    if fallback:
        source = folder / 'ubuntu.sources'
        source.write_text('''Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
''')
        options += ['-o', f'Dir::Etc::sourcelist={source}',
                    '-o', 'Dir::Etc::sourceparts=-']
    return options


def run(command):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(command, check=True)


def acquire(options):
    # GNU timeout controls the entire apt process group, not just a sudo parent.
    # Neither command invokes dpkg; interruption cannot leave package unpacking
    # half-finished. apt update warnings must not count as a complete index set.
    run(['timeout', '--kill-after=15s', '180s', 'apt-get', *options,
         '-o', 'APT::Update::Error-Mode=any', 'update'])
    run(['timeout', '--kill-after=15s', '600s', 'apt-get', *options,
         'install', '-y', '--download-only', *PACKAGES])


def install(root):
    selected = None
    for fallback in (False, True):
        options = apt_options(root / ('official' if fallback else 'normal'), fallback)
        try:
            acquire(options)
        except subprocess.CalledProcessError:
            if fallback:
                raise
            print('Initial acquisition failed; trying official Ubuntu mirrors once.', flush=True)
            continue
        selected = options
        break
    # No fallback on install failure. No network fetch during dpkg execution.
    run(['apt-get', *selected, 'install', '-y', '--no-download', *PACKAGES])
    audit = subprocess.run(['dpkg', '--audit'], check=True, text=True, capture_output=True)
    if audit.stdout.strip() or audit.stderr.strip():
        raise RuntimeError('dpkg audit was not clean: ' + audit.stdout + audit.stderr)


def main():
    release = platform.freedesktop_os_release()
    if (os.geteuid() != 0 or release.get('ID') != 'ubuntu'
            or release.get('VERSION_ID') != '24.04' or platform.machine() != 'x86_64'):
        raise SystemExit('Requires root on Ubuntu 24.04 amd64')
    with tempfile.TemporaryDirectory(prefix='focubili-apt-') as directory:
        root = Path(directory)
        root.chmod(0o755)
        install(root)


if __name__ == '__main__':
    main()
