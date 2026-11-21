"""Exercise the publisher's actual shell steps with synthetic CI artifacts."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.9.1"
BUILD = 33
SOURCE_SHA = "a" * 40
PREFIX = f"FocuBili-v{VERSION}"
ARTIFACTS = {
    ("101", "focubili-release-android"): {
        "app-release.apk": "android",
    },
    ("101", "focubili-release-windows"): {
        f"{PREFIX}-windows-x64-setup.exe": "windows installer",
        f"{PREFIX}-windows-x64-portable.zip": "windows portable",
        "windows-package-verification.json": "synthetic verification; not a public asset",
    },
    ("102", f"focubili-apple-macos-{SOURCE_SHA}"): {
        "FocuBili-macos-preview.dmg": "macOS",
    },
    ("102", f"focubili-apple-ios-{SOURCE_SHA}"): {
        "FocuBili-ios-unsigned.ipa": "unsigned device iOS",
        "INSTALL.txt": "Signing and provisioning are required",
        "SHA256SUMS.txt": "synthetic producer checksum; not a public asset",
    },
    ("103", f"focubili-linux-{SOURCE_SHA}"): {
        f"{PREFIX}-linux-amd64.deb": "Linux",
    },
}
EXPECTED = {
    f"{PREFIX}-android.apk": b"android",
    f"{PREFIX}-windows-x64-setup.exe": b"windows installer",
    f"{PREFIX}-windows-x64-portable.zip": b"windows portable",
    f"{PREFIX}-macos-universal.dmg": b"macOS",
    f"{PREFIX}-ios-unsigned.ipa": b"unsigned device iOS",
    f"{PREFIX}-linux-amd64.deb": b"Linux",
}


def workflow_step(name):
    lines = (ROOT / ".github/workflows/publish-release.yml").read_text(
        encoding="utf-8"
    ).splitlines()
    start = lines.index(f"      - name: {name}")
    run = next(i for i in range(start + 1, len(lines)) if lines[i] == "        run: |")
    end = run + 1
    while end < len(lines) and (not lines[end] or lines[end].startswith("          ")):
        end += 1
    return textwrap.dedent("\n".join(lines[run + 1:end]))


class PublicReleaseAssetsTest(unittest.TestCase):
    def run_publisher(self, missing=None, *, version=VERSION, build=BUILD,
                      existing_fixture=None):
        bash = (
            Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
            if os.name == "nt"
            else shutil.which("bash")
        )
        self.assertTrue(bash and Path(bash).is_file(), "Bash is required")
        with tempfile.TemporaryDirectory(prefix="focubili-release-fixture-") as temporary:
            root = Path(temporary)
            for (run, artifact), files in ARTIFACTS.items():
                directory = root / "artifacts" / run / artifact
                directory.mkdir(parents=True)
                for name, content in files.items():
                    if name != missing:
                        (directory / name.replace(VERSION, version)).write_bytes(content.encode("utf-8"))
            # Only GitHub transport is replaced. Download names, run IDs, moves,
            # new publisher's existing-release check, and checksums run from YAML.
            (root / "tool").mkdir()
            shutil.copyfile(ROOT / "tool/release_asset_names.py", root / "tool/release_asset_names.py")
            if existing_fixture is not None:
                (root / "existing.json").write_text(json.dumps(existing_fixture), encoding="utf-8")
            mock_gh = """
            gh() {
              if test "$1" = api; then
                cat existing.json
              elif test "$1" = release; then
                printf '%s\n' "$*" >> remote-writes
                test "$2" = create
              else
                test "$1" = run && test "$2" = download
                local run="$3"
                test "$4" = --name && test "$6" = --dir
                mkdir -p "$7"
                cp artifacts/"$run"/"$5"/* "$7"/
              fi
            }
            """
            script = "set -euo pipefail\n" + textwrap.dedent(mock_gh)
            script += workflow_step("Download verified build artifacts") + "\n"
            script += workflow_step("Prepare public release assets") + "\n"
            if existing_fixture is not None:
                script += workflow_step("Publish GitHub Release") + "\n"
            (root / "publisher.sh").write_text(script, encoding="utf-8", newline="\n")
            result = subprocess.run(
                [str(bash), "--noprofile", "--norc", "publisher.sh"],
                cwd=root,
                env={**os.environ, "VERSION": version, "FULL_VERSION": f"{version}+{build}",
                     "TAG": f"v{version}", "NOTES": "notes.md", "GITHUB_REPOSITORY": "L1Xu4n/FocuBili",
                     "GITHUB_SHA": SOURCE_SHA, "RUN_ID": "101", "APPLE_RUN": "102", "LINUX_RUN": "103"},
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=30,
            )
            files = {path.name: path.read_bytes() for path in (root / "release").glob("*")}
            writes = (root / "remote-writes").read_text() if (root / "remote-writes").exists() else ""
            return result, files, writes

    def test_exact_ci_runs_supply_all_six_public_assets_without_changing_bytes(self):
        result, files, _ = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {name.replace(PREFIX, PREFIX + f"-build{BUILD}"): data
                                 for name, data in EXPECTED.items()})
        self.assertEqual(len(result.stdout.strip().splitlines()), 6)

    def test_v190_build32_keeps_all_six_legacy_names(self):
        result, files, _ = self.run_publisher(version="1.9.0", build=32)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {name.replace(VERSION, "1.9.0"): data
                                 for name, data in EXPECTED.items()})

    def test_existing_legacy_names_are_never_modified(self):
        assets = [self.asset(name, data) for name, data in EXPECTED.items()]
        result, _, writes = self.run_publisher(existing_fixture=[[self.release(assets)]])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, "")
        self.assertIn("No changes made", result.stderr)

    def test_matching_retry_does_not_write_and_missing_release_only_creates(self):
        assets = [self.asset(name.replace(PREFIX, PREFIX + f"-build{BUILD}"), data)
                  for name, data in EXPECTED.items()]
        result, _, writes = self.run_publisher(existing_fixture=[[self.release(assets)]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(writes, "")
        result, _, writes = self.run_publisher(existing_fixture=[[]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(writes.startswith(f"release create v{VERSION} "))
        self.assertNotIn("--clobber", writes)

    def test_draft_or_bad_digest_cannot_be_modified(self):
        assets = [self.asset(name.replace(PREFIX, PREFIX + f"-build{BUILD}"), data)
                  for name, data in EXPECTED.items()]
        for release in (dict(self.release(assets), draft=True),
                        self.release([dict(assets[0], digest="mismatch"), *assets[1:]])):
            with self.subTest(release=release):
                result, _, writes = self.run_publisher(existing_fixture=[[release]])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(writes, "")

    @staticmethod
    def asset(name, data):
        return {"name": name, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                "state": "uploaded"}

    @staticmethod
    def release(assets):
        return {"tag_name": f"v{VERSION}", "draft": False, "prerelease": False, "assets": assets}

    def test_missing_device_ipa_blocks_publication(self):
        result, _, _ = self.run_publisher(missing="FocuBili-ios-unsigned.ipa")
        self.assertNotEqual(result.returncode, 0)

    def test_missing_windows_portable_blocks_publication(self):
        result, _, _ = self.run_publisher(missing=f"{PREFIX}-windows-x64-portable.zip")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
