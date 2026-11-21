"""Derive user-facing release filenames from verified version/build metadata."""
import argparse
import re


SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def asset_prefix(version, build, *, beta=False):
    pattern = SEMVER + (r"-beta\.[1-9][0-9]*" if beta else "")
    if not re.fullmatch(pattern, version):
        raise ValueError("Invalid release version")
    if type(build) is not int or not 1 <= build <= 65535:
        raise ValueError("Invalid package build number")
    prefix = f"FocuBili-v{version}"
    # Published v1.9.0 stable asset links and the one-time correction stay fixed.
    if not beta and (version, build) == ("1.9.0", 32):
        return prefix
    return f"{prefix}-build{build}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version_with_build")
    args = parser.parse_args()
    match = re.fullmatch(f"({SEMVER})\\+([1-9][0-9]*)", args.version_with_build)
    if not match:
        parser.error("Expected a committed numeric stable version+build")
    print(asset_prefix(match[1], int(match[2])))


if __name__ == "__main__":
    main()
