"""Verify stable platform build artifacts against the checked-out source.

The validators inspect local build output only. They do not publish or sign.
"""
import argparse
from pathlib import Path
import re

from beta_release import require, save, text, verify_ios, verify_linux, verify_windows


def stable_identity(pubspec, revision):
    matches = re.findall(
        r"^version: (\d+\.\d+\.\d+)\+([1-9][0-9]*)\s*$", pubspec, re.M
    )
    require(len(matches) == 1, "Expected one numeric stable app version and build")
    require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None, "Invalid source SHA")
    version, build = matches[0]
    require(int(build) <= 65535, "Windows resource build number would overflow")
    return {
        "sourceSha": revision,
        "baseVersion": version,
        "buildNumber": int(build),
        "debVersion": version,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    commands = parser.add_subparsers(dest="platform", required=True)
    ios = commands.add_parser("ios")
    ios.add_argument("--ipa", required=True, type=Path)
    linux = commands.add_parser("linux")
    linux.add_argument("--folder", required=True, type=Path)
    windows = commands.add_parser("windows")
    windows.add_argument("--folder", required=True, type=Path)
    windows.add_argument("--executable", required=True, type=Path)
    windows.add_argument("--product-version", required=True)
    windows.add_argument("--file-version", required=True)
    args = parser.parse_args()
    identity = stable_identity(
        Path("pubspec.yaml").read_text(encoding="utf-8"),
        text("git", "rev-parse", "HEAD"),
    )
    if args.platform == "ios":
        record = verify_ios(identity, args.ipa)
    elif args.platform == "linux":
        record = verify_linux(identity, args.folder)
    else:
        record = verify_windows(
            identity, args.folder, args.executable, args.product_version, args.file_version
        )
    save(args.output, record)


if __name__ == "__main__":
    main()
