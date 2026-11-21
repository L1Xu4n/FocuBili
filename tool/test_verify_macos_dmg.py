"""Regressions for metadata-driven DMG validation after Codex review."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_macos_dmg as validator


class MacOSPackageMetadataTest(unittest.TestCase):
    def test_version_bump_does_not_require_validator_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / 'pubspec.yaml'
            for version, build in [('1.7.0', '20'), ('1.8.0', '21'), ('2.0.0', '100')]:
                metadata.write_text(f'name: focubili\nversion: {version}+{build}\n')
                self.assertEqual(validator.project_version(metadata), (version, build))

    def test_beta_artifact_uses_preview_counter_and_stable_uses_app_counter(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / 'pubspec.yaml'
            metadata.write_text('version: 1.9.0+32\nfocubili_beta_build_number: 2038\n')
            with patch.object(validator, 'run', return_value=b'a' * 40):
                self.assertEqual(validator.project_version(metadata, beta_number='13'), ('1.9.0', '2038'))
            self.assertEqual(validator.project_version(metadata), ('1.9.0', '32'))

    def test_quoted_version_and_comment(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / 'pubspec.yaml'
            metadata.write_text('version: "1.8.0+21" # next release\n')
            self.assertEqual(validator.project_version(metadata), ('1.8.0', '21'))

    def test_mount_directory_exists_before_attach(self):
        class MountReached(Exception):
            pass

        def fake_run(*args):
            if args[:2] == ('hdiutil', 'attach'):
                mount = Path(args[args.index('-mountpoint') + 1])
                self.assertTrue(mount.is_dir())
                raise MountReached
            return b''

        with patch.object(validator, 'manifest', return_value={'normal': {}}), \
             patch.object(validator, 'run', side_effect=fake_run):
            with self.assertRaises(MountReached):
                validator.main()


if __name__ == '__main__':
    unittest.main()
