"""Exercise repeatable packaging using a tiny isolated synthetic bundle."""
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class LinuxPackagingTest(unittest.TestCase):
    def test_rebuild_replaces_staging_and_excludes_removed_files(self):
        with tempfile.TemporaryDirectory(prefix='focubili-package-test-') as directory:
            root = Path(directory)
            bundle = root / 'build/linux/x64/release/bundle'
            (bundle / 'lib').mkdir(parents=True)
            binary = bundle / 'focubili'
            binary.write_text('#!/bin/sh\necho first\n')
            binary.chmod(0o755)
            (bundle / 'lib/removed.so').write_bytes(b'old library fixture')
            (root / 'pubspec.yaml').write_text('version: 1.7.0+20\n')
            for relative in ['linux/packaging/com.focubili.app.desktop', 'assets/icon/focubili_icon.png']:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / relative, target)

            def package():
                subprocess.run(['bash', str(REPO / 'tool/package_linux.sh')], cwd=root,
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(list((root / 'build/linux-packages').glob('.deb-staging.*')), [])

            package()
            (bundle / 'lib/removed.so').unlink()
            (bundle / 'lib/current.so').write_bytes(b'new library fixture')
            binary.write_text('#!/bin/sh\necho rebuilt\n')
            package()
            package()  # An unchanged third invocation is safe too.
            out = root / 'build/linux-packages'
            deb = out / 'FocuBili-v1.7.0-linux-amd64.deb'
            data = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(deb)])
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                self.assertEqual(archive.getmember('.').mode, 0o755)
                names = {name.removeprefix('./') for name in archive.getnames()}
                self.assertNotIn('opt/focubili/lib/removed.so', names)
                self.assertIn('opt/focubili/lib/current.so', names)
                link = archive.getmember('./usr/bin/focubili')
                self.assertTrue(link.issym())
                self.assertEqual(link.linkname, '/opt/focubili/focubili')
                self.assertEqual(archive.extractfile('./opt/focubili/focubili').read(), binary.read_bytes())
            with tarfile.open(out / 'FocuBili-v1.7.0-linux-x64.tar.gz') as archive:
                names = {name.removeprefix('./') for name in archive.getnames()}
                self.assertNotIn('lib/removed.so', names)
                self.assertIn('lib/current.so', names)
                self.assertEqual(archive.extractfile('./focubili').read(), binary.read_bytes())
            for line in (out / 'SHA256SUMS.txt').read_text().splitlines():
                expected, name = line.split()
                self.assertEqual(hashlib.sha256((out / name).read_bytes()).hexdigest(), expected)


if __name__ == '__main__':
    unittest.main()
