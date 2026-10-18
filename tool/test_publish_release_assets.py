"""Exercise the publisher's actual shell steps with synthetic CI artifacts."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.8.0"
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
    def run_publisher(self, missing=None):
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
                        (directory / name).write_bytes(content.encode("utf-8"))
            # Only GitHub transport is replaced. Download names, run IDs, moves,
            # asset-count assertion and checksums execute straight from YAML.
            mock_gh = """
            gh() {
              test "$1" = run && test "$2" = download
              local run="$3"
              test "$4" = --name && test "$6" = --dir
              mkdir -p "$7"
              cp artifacts/"$run"/"$5"/* "$7"/
            }
            """
            script = "set -euo pipefail\n" + textwrap.dedent(mock_gh)
            script += workflow_step("Download verified build artifacts") + "\n"
            script += workflow_step("Prepare public release assets") + "\n"
            (root / "publisher.sh").write_text(script, encoding="utf-8", newline="\n")
            result = subprocess.run(
                [str(bash), "--noprofile", "--norc", "publisher.sh"],
                cwd=root,
                env={**os.environ, "VERSION": VERSION, "GITHUB_SHA": SOURCE_SHA,
                     "RUN_ID": "101", "APPLE_RUN": "102", "LINUX_RUN": "103"},
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=30,
            )
            files = {path.name: path.read_bytes() for path in (root / "release").glob("*")}
            return result, files

    def test_exact_ci_runs_supply_all_six_public_assets_without_changing_bytes(self):
        result, files = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, EXPECTED)
        self.assertEqual(len(result.stdout.strip().splitlines()), 6)

    def test_missing_device_ipa_blocks_publication(self):
        result, _ = self.run_publisher(missing="FocuBili-ios-unsigned.ipa")
        self.assertNotEqual(result.returncode, 0)

    def test_missing_windows_portable_blocks_publication(self):
        result, _ = self.run_publisher(missing=f"{PREFIX}-windows-x64-portable.zip")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
