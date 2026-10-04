"""Verify the packaged normal app before the standalone runtime probe is built."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(app):
    # Include every regular file and symlink; signatures and executable bytes
    # must match the normal release build, not the later test-probe application.
    return {
        str(path.relative_to(app)): (
            {"symlink": str(path.readlink())} if path.is_symlink()
            else {"sha256": digest(path), "size": path.stat().st_size}
        )
        for path in sorted(app.rglob("*"))
        if path.is_symlink() or path.is_file()
    }


def main():
    dmg = Path("build/apple/FocuBili-macos-preview.dmg")
    normal = Path("build/macos/Build/Products/Release/FocuBili.app")
    expected = manifest(normal)
    assert expected, "Normal application missing"
    run("hdiutil", "verify", str(dmg))
    with tempfile.TemporaryDirectory() as directory:
        mount = Path(directory) / "volume"
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
            str(mount), str(dmg))
        try:
            app = mount / "FocuBili.app"
            assert {p.name for p in mount.iterdir()} == {
                "FocuBili.app", "Applications", "README.txt"
            }, "Unexpected DMG contents"
            assert (mount / "Applications").is_symlink()
            assert str((mount / "Applications").readlink()) == "/Applications"
            assert "ad-hoc signed, not notarized" in (mount / "README.txt").read_text()
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            assert info["CFBundleIdentifier"] == "com.focubili.app"
            assert info["CFBundleShortVersionString"] == "1.7.0"
            assert str(info["CFBundleVersion"]) == "20"
            assert info["CFBundleExecutable"] == "FocuBili"
            assert manifest(app) == expected, "DMG differs from normal application"
            run("codesign", "--verify", "--deep", "--strict", str(app))
            signature = subprocess.run(
                ["codesign", "-dvv", str(app)], check=True,
                capture_output=True, text=True,
            ).stderr
            assert "Signature=adhoc" in signature
            entitlements = plistlib.loads(run(
                "codesign", "-d", "--entitlements", ":-", str(app)
            ))
            assert entitlements.get("com.apple.security.app-sandbox") is True
            assert entitlements.get("com.apple.security.network.client") is True
            architectures = run(
                "lipo", "-archs", str(app / "Contents/MacOS/FocuBili")
            ).decode().strip().split()
            assert "arm64" in architectures, "Apple Silicon build missing"
        finally:
            run("hdiutil", "detach", str(mount))
    evidence = {
        "source_sha": run("git", "rev-parse", "HEAD").decode().strip(),
        "dmg_name": dmg.name,
        "dmg_sha256": digest(dmg),
        "dmg_size": dmg.stat().st_size,
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": str(info["CFBundleVersion"]),
        "architectures": architectures,
        "normal_app_manifest": expected,
        "normal_app_matches_dmg": True,
        "adhoc_signature_verified": True,
        "sandbox_and_network_entitlements_verified": True,
    }
    Path("build/apple/macos-package-verification.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"
    )
    print("MACOS_NORMAL_DMG_CONTENTS_VERIFIED")


if __name__ == "__main__":
    main()
