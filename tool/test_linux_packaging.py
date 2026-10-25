"""Exercise repeatable packaging using a tiny isolated synthetic bundle."""
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class LinuxPackagingTest(unittest.TestCase):
    def project(self):
        directory = tempfile.TemporaryDirectory(prefix='focubili-package-test-')
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / 'build/linux/x64/release/bundle/lib').mkdir(parents=True)
        (root / 'pubspec.yaml').write_text('version: 1.7.0+20\n')
        for relative in ['linux/packaging/com.focubili.app.desktop', 'assets/icon/focubili_icon.png']:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        return root

    def package(self, root, **environment):
        return subprocess.run(
            ['bash', '-c', 'umask 077; exec bash "$1"', 'packaging-test',
             str(REPO / 'tool/package_linux.sh')], cwd=root,
            env={**os.environ, 'FOCUBILI_PACKAGE_VERSION': '', **environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def linked_fixture(self, root, soname='libfixture.so'):
        bundle = root / 'build/linux/x64/release/bundle'
        (root / 'parse.c').write_text(
            '#include <stdlib.h>\n'
            'long long parse(const char *s) { return strtoll(s, 0, 10); }\n')
        (root / 'fixture.cc').write_text(
            '#include <iostream>\n'
            'extern "C" long long parse(const char *);\n'
            'extern "C" long long fixture(const char *s) {\n'
            '  std::cout << s; return parse(s);\n}\n')
        (root / 'main.c').write_text(
            'extern long long fixture(const char *);\n'
            'int main(int argc, char **argv) { return fixture(argv[argc-1]) < 0; }\n')
        subprocess.run(['cc', '-std=c2x', '-fPIC', '-c', str(root / 'parse.c'),
                        '-o', str(root / 'parse.o')], check=True)
        library = bundle / 'lib' / soname
        subprocess.run(['c++', '-shared', '-fPIC', str(root / 'fixture.cc'),
                        str(root / 'parse.o'), '-Wl,-soname,' + soname,
                        '-o', str(library)], check=True)
        subprocess.run(['cc', str(root / 'main.c'), '-L' + str(bundle / 'lib'),
                        '-l:' + soname, '-Wl,-rpath,$ORIGIN/lib',
                        '-o', str(bundle / 'focubili')], check=True)
        return bundle, library

    def test_rebuild_replaces_staging_and_excludes_removed_files(self):
        with tempfile.TemporaryDirectory(prefix='focubili-package-test-') as directory:
            root = Path(directory)
            bundle = root / 'build/linux/x64/release/bundle'
            (bundle / 'lib').mkdir(parents=True)
            binary = bundle / 'focubili'
            shutil.copyfile('/bin/true', binary)
            binary.chmod(0o755)
            (bundle / 'lib/removed.so').write_bytes(b'old library fixture')
            (root / 'pubspec.yaml').write_text('version: 1.7.0+20\n')
            for relative in ['linux/packaging/com.focubili.app.desktop', 'assets/icon/focubili_icon.png']:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / relative, target)

            def package():
                result = self.package(root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(list((root / 'build/linux-packages').glob('.deb-staging.*')), [])

            package()
            (bundle / 'lib/removed.so').unlink()
            (bundle / 'lib/current.so').write_bytes(b'new library fixture')
            shutil.copyfile('/bin/false', binary)
            package()
            package()  # An unchanged third invocation is safe too.
            out = root / 'build/linux-packages'
            deb = out / 'FocuBili-v1.7.0-linux-amd64.deb'
            data = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(deb)])
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                self.assertEqual(archive.getmember('.').mode, 0o755)
                self.assertEqual(archive.getmember('./usr/share/applications/com.focubili.app.desktop').mode, 0o644)
                self.assertEqual(archive.getmember('./usr/share/icons/hicolor/512x512/apps/com.focubili.app.png').mode, 0o644)
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

    def test_control_tracks_private_library_abi_without_stale_dependencies(self):
        root = self.project()
        bundle, library = self.linked_fixture(root)
        symbols = subprocess.check_output(['readelf', '--version-info', str(library)], text=True)
        self.assertIn('GLIBC_2.38', symbols)
        self.assertIn('GLIBCXX_', symbols)
        result = self.package(root)
        self.assertEqual(result.returncode, 0, result.stderr)
        deb = root / 'build/linux-packages/FocuBili-v1.7.0-linux-amd64.deb'
        field = subprocess.check_output(['dpkg-deb', '-f', str(deb), 'Depends'], text=True)
        self.assertNotIn('jsoncpp', field)
        self.assertNotIn('libfixture', field)
        self.assertIn('xdg-desktop-portal', field)
        self.assertIn('libstdc++6 (>= ', field)
        minimum = re.search(r'libc6 \(>= ([^)]+)\)', field).group(1)
        self.assertEqual(subprocess.call(['dpkg', '--compare-versions', minimum, 'ge', '2.38']), 0)
        # The runner alone needs an older libc; the private library must raise it.
        runner_symbols = subprocess.check_output(
            ['readelf', '--version-info', str(bundle / 'focubili')], text=True)
        self.assertNotIn('GLIBC_2.38', runner_symbols)

    def test_beta_version_is_preserved(self):
        root = self.project()
        binary = root / 'build/linux/x64/release/bundle/focubili'
        shutil.copy('/bin/true', binary)
        version = '1.9.0~beta.1+32'
        result = self.package(root, FOCUBILI_PACKAGE_VERSION=version)
        self.assertEqual(result.returncode, 0, result.stderr)
        deb = root / f'build/linux-packages/FocuBili-v{version}-linux-amd64.deb'
        self.assertEqual(subprocess.check_output(
            ['dpkg-deb', '-f', str(deb), 'Version'], text=True).strip(), version)

    def test_missing_private_library_stops_packaging(self):
        root = self.project()
        _, library = self.linked_fixture(root)
        library.unlink()
        result = self.package(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing private library', result.stderr)
        self.assertEqual(list((root / 'build/linux-packages').glob('*.deb')), [])
        self.assertEqual(list((root / 'build/linux-packages').glob('.deb-staging.*')), [])

    def test_missing_system_library_stops_packaging(self):
        root = self.project()
        _, library = self.linked_fixture(root, 'libfixture.so.99')
        library.unlink()
        result = self.package(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot find library libfixture.so.99', result.stderr)
        self.assertEqual(list((root / 'build/linux-packages').glob('*.deb')), [])
        self.assertEqual(list((root / 'build/linux-packages').glob('.deb-staging.*')), [])

    def test_wrong_architecture_stops_packaging(self):
        root = self.project()
        binary = root / 'build/linux/x64/release/bundle/focubili'
        data = bytearray(Path('/bin/true').read_bytes())
        data[18:20] = b'\xb7\x00'  # AArch64 e_machine, not amd64.
        binary.write_bytes(data)
        binary.chmod(0o755)
        result = self.package(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected an amd64 ELF object', result.stderr)


if __name__ == '__main__':
    unittest.main()
