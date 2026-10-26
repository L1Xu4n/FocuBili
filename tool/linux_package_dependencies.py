"""Derive DEB dependencies from the application's linked ELF objects."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def linked_objects(bundle):
    """Follow private DT_NEEDED links; unused native assets are not startup deps."""
    bundle = Path(bundle).resolve()
    pending = [bundle / 'focubili']
    objects = set()
    while pending:
        path = pending.pop().resolve()
        if path in objects:
            continue
        if not path.is_relative_to(bundle):
            raise ValueError(f'Private library escapes bundle: {path}')
        with path.open('rb') as source:
            header = source.read(20)
        if header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00':
            raise ValueError(f'Expected an amd64 ELF object: {path}')
        objects.add(path)
        dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
        for name in re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic):
            private = bundle / 'lib' / name
            if private.is_file():
                pending.append(private)
            elif name.endswith('.so'):
                # Flutter's private libraries are unversioned. dpkg-shlibdeps
                # only warns about these when absent, so fail explicitly.
                raise ValueError(f'Missing private library: {name} (needed by {path.name})')
    return sorted(objects)


def dependencies(bundle):
    objects = linked_objects(bundle)
    with tempfile.TemporaryDirectory(prefix='focubili-shlibdeps-') as directory:
        root = Path(directory)
        (root / 'debian').mkdir()
        (root / 'debian/control').write_text(
            'Source: focubili\nSection: video\nPriority: optional\n'
            'Maintainer: FocuBili Project\n\n'
            'Package: focubili\nArchitecture: amd64\n'
            'Description: Focused Bilibili viewing and timestamp notes\n')
        result = subprocess.run(
            ['dpkg-shlibdeps', '-O', '-xfocubili',
             '-l' + str(Path(bundle).resolve() / 'lib'),
             *['-e' + str(path) for path in objects]],
            cwd=root, env={**os.environ, 'LC_ALL': 'C'}, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sys.stderr.write(result.stderr)
        result.check_returncode()
    prefix = 'shlibs:Depends='
    fields = [line.removeprefix(prefix) for line in result.stdout.splitlines()
              if line.startswith(prefix)]
    if len(fields) != 1 or not fields[0]:
        raise ValueError('dpkg-shlibdeps did not produce runtime dependencies')
    return fields[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle')
    args = parser.parse_args()
    try:
        print(dependencies(args.bundle))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Linux dependency scan failed: {error}\n')
