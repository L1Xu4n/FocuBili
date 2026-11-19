#!/usr/bin/env python3
"""Offline behavior/command tests: never installs packages or invokes sudo."""
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import install_linux_ci_dependencies as subject


class InstallTests(unittest.TestCase):
    def exercise(self, failures=(), audit_output=''):
        commands = []
        snapshots = []

        def fake(command, **kwargs):
            commands.append(command)
            if 'apt-get' in command:
                source = next((a.split('=', 1)[1] for a in command
                               if a.startswith('Dir::Etc::sourcelist=')), None)
                if source:
                    snapshots.append(Path(source).read_text())
            if len(commands) in failures:
                raise subprocess.CalledProcessError(124, command)
            return subprocess.CompletedProcess(command, 0, audit_output, '')

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(subject.subprocess, 'run', side_effect=fake):
                with contextlib.redirect_stdout(io.StringIO()):
                    try:
                        subject.install(Path(directory))
                    except (subprocess.CalledProcessError, RuntimeError) as error:
                        return commands, snapshots, error
        return commands, snapshots, None

    def test_normal_success_never_falls_back(self):
        commands, sources, error = self.exercise()
        self.assertIsNone(error)
        self.assertEqual(len(commands), 4)
        self.assertFalse(sources)
        self.assertIn('--download-only', commands[1])
        self.assertIn('--no-download', commands[2])
        self.assertEqual(commands[3], ['dpkg', '--audit'])

    def test_update_failure_switches_to_official_source(self):
        commands, sources, error = self.exercise((1,))
        self.assertIsNone(error)
        self.assertEqual(len(commands), 5)
        self.assertTrue(sources)
        self.assertIn('https://archive.ubuntu.com/ubuntu', sources[0])
        self.assertIn('https://security.ubuntu.com/ubuntu', sources[0])
        self.assertIn('Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg', sources[0])
        self.assertIn('Dir::Etc::sourceparts=-', commands[1])
        normal_lists = next(a for a in commands[0] if a.startswith('Dir::State::lists='))
        fallback_lists = next(a for a in commands[1] if a.startswith('Dir::State::lists='))
        self.assertNotEqual(normal_lists, fallback_lists)

    def test_download_timeout_retries_once(self):
        commands, _, error = self.exercise((2,))
        self.assertIsNone(error)
        self.assertEqual(len(commands), 6)
        self.assertIn('--no-download', commands[-2])

    def test_both_update_failures_never_install(self):
        commands, _, error = self.exercise((1, 2))
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(len(commands), 2)
        self.assertFalse(any('--no-download' in c for c in commands))

    def test_fallback_download_failure_never_installs(self):
        commands, _, error = self.exercise((2, 4))
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(len(commands), 4)

    def test_install_failure_is_fatal_without_new_acquisition(self):
        commands, _, error = self.exercise((3,))
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(len(commands), 3)
        self.assertEqual(commands[-1][0], 'apt-get')

    def test_only_acquisition_is_timed_and_security_kept(self):
        commands, _, _ = self.exercise((2,))
        for command in commands:
            if command[0] == 'timeout':
                self.assertIn(command[2], ('180s', '600s'))
                self.assertTrue('update' in command or '--download-only' in command)
            if 'apt-get' in command:
                self.assertIn('Acquire::https::Timeout=15', command)
                self.assertNotIn('--allow-unauthenticated', command)
                self.assertNotIn('--no-install-recommends', command)
            if 'install' in command:
                self.assertEqual(command[-len(subject.PACKAGES):], subject.PACKAGES)
        self.assertIn('APT::Update::Error-Mode=any', commands[0])

    def test_audit_output_is_failure_even_with_zero_exit(self):
        _, _, error = self.exercise(audit_output='Unconfigured package')
        self.assertIsInstance(error, RuntimeError)

    def test_package_set_matches_existing_native_requirements(self):
        self.assertEqual(subject.PACKAGES, '''clang cmake ninja-build pkg-config dpkg-dev
binutils python3 libgtk-3-dev libmpv-dev libsecret-1-dev libasound2-dev
libwebkit2gtk-4.1-dev xvfb dbus-x11 openbox dunst scrot gdb gnome-keyring
xdg-desktop-portal-gtk desktop-file-utils'''.split())

    def test_wrong_platform_rejected_before_any_commands(self):
        with patch.object(subject.platform, 'freedesktop_os_release',
                          return_value={'ID': 'debian', 'VERSION_ID': '13'}):
            with patch.object(subject.subprocess, 'run') as call:
                with self.assertRaises(SystemExit):
                    subject.main()
                call.assert_not_called()


if __name__ == '__main__':
    unittest.main()
