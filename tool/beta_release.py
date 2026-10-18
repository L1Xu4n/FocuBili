"""Beta-only build/verification helpers. No keys, release writes or app data reads.

Publication is deliberately owned by the workflow's final, permission-scoped job.
All commands here either build locally or read metadata/release assets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

REPOSITORY = "L1Xu4n/FocuBili"
PACKAGE = "com.focubili.app.preview"
CERTIFICATE = "65ef1fb301fb1121c1803e752f5b1eb24e55846502d8b5478f0fc11f58e9a8a9"
# Archived preview APKs: beta3=2023, beta4=2024, beta5=2025.
# This remains a floor even if a historical release asset is later removed.
FLOOR = 2025
SHA = re.compile(r"[0-9a-f]{40}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*arguments):
    return subprocess.check_output(arguments)


def text(*arguments):
    return run(*arguments).decode("utf-8", errors="strict").strip()


def save(path, value):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def plan(beta, revision, pubspec=None):
    require(SHA.fullmatch(revision) is not None, "Expected a full lowercase source SHA")
    require(re.fullmatch(r"[1-9][0-9]*", str(beta)) is not None, "Invalid beta number")
    source = Path("pubspec.yaml").read_text(encoding="utf-8") if pubspec is None else pubspec
    matches = re.findall(r"^version: (1\.9\.(?:0|[1-9][0-9]*))\+([1-9][0-9]*)\s*$", source, re.M)
    require(len(matches) == 1, "Expected one committed numeric 1.9.x+build version")
    base, build = matches[0]
    build = int(build)
    require(FLOOR < build <= 65535, "Committed build number must be 2026..65535 (archived Android floor and Windows resource limit)")
    version = f"{base}-beta.{beta}"
    return {"format": "focubili.beta-release", "version": 1, "channel": "beta",
            "sourceSha": revision, "baseVersion": base, "betaNumber": int(beta),
            "buildNumber": build, "releaseVersion": version, "tag": "v" + version,
            "debVersion": f"{base}~beta.{beta}+{build}"}


def checkout_plan(beta, revision):
    require(text("git", "rev-parse", "HEAD") == revision, "Checkout differs from requested source SHA")
    return plan(beta, revision)


def load_plan(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    expected = plan(value["betaNumber"], value["sourceSha"],
                    f"version: {value['baseVersion']}+{value['buildNumber']}\n")
    require(value == expected, "Plan schema or values differ from validated source metadata")
    return value


def build_arguments(platform, value):
    kind = "ios" if platform == "ios-simulator" else platform
    arguments = ["flutter", "build", kind]
    arguments += ["--simulator", "--debug"] if platform == "ios-simulator" else ["--release"]
    if platform == "ios":
        arguments.append("--no-codesign")
    arguments += [f"--build-name={value['baseVersion']}", f"--build-number={value['buildNumber']}",
                  "--dart-define=FOCUBILI_RELEASE_CHANNEL=beta",
                  f"--dart-define=FOCUBILI_RELEASE_VERSION={value['releaseVersion']}"]
    if platform == "apk":
        arguments.append(f"--android-project-arg=focubili.betaNumber={value['betaNumber']}")
    return arguments


def run_flutter(arguments):
    # Windows Popen does not resolve PATHEXT, while Flutter is a .bat launcher.
    executable = shutil.which("flutter")
    require(executable is not None, "Flutter executable not found on PATH")
    return subprocess.run([executable, *arguments], check=True, shell=False)


def apk_metadata(raw):
    match = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", raw, re.M)
    require(match is not None, "APK package/version metadata missing")
    return {"package": match[1], "versionCode": int(match[2]), "versionName": match[3]}


def signer_certificate(raw):
    counts = re.findall(r"^Number of signers: ([0-9]+)$", raw, re.M)
    fingerprints = re.findall(r"^(?:Signer #[0-9]+|V[0-9.]+ Signer):? certificate SHA-256 digest: ([0-9a-fA-F]{64})$", raw, re.M)
    require(len(set(value.lower() for value in fingerprints)) == 1, "Expected one APK signing identity")
    if counts:
        require(counts == ["1"], "Expected exactly one APK signer")
    else:
        require(len(fingerprints) == 1, "APK signer count missing or ambiguous")
    return fingerprints[0].lower()


def file_record(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), "Expected a regular artifact file")
    require(path.stat().st_size > 0, "Artifact is empty")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def verify_android(value, apk, aapt, apksigner):
    badging = text(aapt, "dump", "badging", str(apk))
    require("application-debuggable" not in badging, "Publishable Beta must not be debuggable")
    metadata = apk_metadata(badging)
    certificate = signer_certificate(text(apksigner, "verify", "--verbose", "--print-certs", str(apk)))
    require(metadata == {"package": PACKAGE, "versionCode": value["buildNumber"],
                         "versionName": value["releaseVersion"]}, "Beta APK identity/version differs from plan")
    require(certificate == CERTIFICATE, "APK does not use the existing release signing identity")
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({name.split("/")[1] for name in archive.namelist()
                       if name.startswith("lib/") and name.endswith(".so")})
    require("arm64-v8a" in abis, "ARM64 libraries missing")
    return {**metadata, **file_record(apk), "certificateSha256": certificate,
            "sourceSha": value["sourceSha"], "abis": abis}


def inventory(value, aapt):
    # GH pagination/network failures are fatal, never treated as an empty release list.
    pages = json.loads(text("gh", "api", "--paginate", "--slurp",
                           f"repos/{REPOSITORY}/releases?per_page=100"))
    require(isinstance(pages, list) and all(isinstance(page, list) for page in pages),
            "Malformed release inventory")
    maximum = FLOOR
    records = []
    with tempfile.TemporaryDirectory(prefix="focubili-beta-inventory-") as directory:
        for release in [item for page in pages for item in page]:
            require(isinstance(release, dict) and isinstance(release.get("draft"), bool), "Malformed release")
            if release["draft"]:
                continue
            require(isinstance(release.get("assets"), list), "Release assets missing")
            for asset in release["assets"]:
                require(isinstance(asset, dict) and isinstance(asset.get("name"), str), "Malformed asset")
                if not asset["name"].lower().endswith(".apk"):
                    continue
                asset_id = asset.get("id")
                require(type(asset_id) is int and asset_id > 0, "Invalid APK asset identity")
                require(type(asset.get("size")) is int and asset["size"] > 0, "Invalid published APK size")
                target = Path(directory) / f"asset-{asset_id}.apk"
                target.write_bytes(run("gh", "api", "-H", "Accept: application/octet-stream",
                                       f"repos/{REPOSITORY}/releases/assets/{asset_id}"))
                require(target.stat().st_size == asset.get("size"), "Published APK download is truncated")
                metadata = apk_metadata(text(aapt, "dump", "badging", str(target)))
                require(metadata["package"] in {PACKAGE, "com.focubili.app"}, "Unexpected published APK package")
                maximum = max(maximum, metadata["versionCode"])
                records.append({"release": release.get("tag_name"), "assetId": asset_id, **metadata})
    require(value["buildNumber"] > maximum,
            f"Build number must exceed every published Android code (maximum {maximum})")
    return {"maximumKnownVersionCode": maximum, "archivedVersionCodeFloor": FLOOR,
            "sourceSha": value["sourceSha"], "apks": records}


def wait_ci(revision):
    import time
    deadline = time.monotonic() + 75 * 60
    while True:
        result = {}
        for workflow in ["ci.yml", "apple-build.yml", "linux-build.yml"]:
            runs = json.loads(text("gh", "run", "list", "--repo", REPOSITORY,
                                   "--workflow", workflow, "--commit", revision, "--event", "push",
                                   "--limit", "100", "--json", "databaseId,headSha,status,conclusion"))
            require(isinstance(runs, list), "Malformed CI runs")
            run_info = next((item for item in runs if item["headSha"] == revision), None)
            if run_info and run_info["status"] == "completed":
                require(run_info["conclusion"] == "success", f"Exact source failed {workflow}")
                result[workflow] = run_info["databaseId"]
        if len(result) == 3:
            return {"sourceSha": revision, "runs": result}
        require(time.monotonic() < deadline, "Timed out waiting for exact source CI")
        time.sleep(30)


def verify_windows(value, folder, executable, product_version, file_version):
    expected = value["baseVersion"] + "+" + str(value["buildNumber"])
    require(product_version == expected, "Windows ProductVersion differs from injected build")
    require(file_version == value["baseVersion"] + "." + str(value["buildNumber"]), "Windows FileVersion differs")
    raw = Path(executable).read_bytes()
    require(raw[:2] == b"MZ" and len(raw) >= 64, "Windows app is not a PE executable")
    offset = struct.unpack_from("<I", raw, 60)[0]
    require(raw[offset:offset + 4] == b"PE\0\0" and struct.unpack_from("<H", raw, offset + 4)[0] == 0x8664,
            "Expected Windows x64 executable")
    paths = [Path(folder) / f"FocuBili-v{value['baseVersion']}-windows-x64-{suffix}"
             for suffix in ["setup.exe", "portable.zip"]]
    with zipfile.ZipFile(paths[1]) as archive:
        require(archive.read("FocuBili.exe") == raw, "Portable archive differs from verified normal executable")
        require(all(name in archive.namelist() for name in ["flutter_windows.dll", "vcruntime140.dll",
                                                            "vcruntime140_1.dll", "msvcp140.dll"]), "Portable runtime missing")
    return {"sourceSha": value["sourceSha"], "version": value["baseVersion"],
            "build": str(value["buildNumber"]), "files": [file_record(path) for path in paths]}


def verify_ios(value, ipa):
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read("Payload/Runner.app/Info.plist"))
        require(info["CFBundleIdentifier"] == "com.focubili.app", "Unexpected iOS bundle identity")
        require(info["CFBundleShortVersionString"] == value["baseVersion"], "Unexpected iOS version")
        require(str(info["CFBundleVersion"]) == str(value["buildNumber"]), "Unexpected iOS build number")
        require("Payload/Runner.app/Runner" in archive.namelist(), "iOS executable missing")
    return {"sourceSha": value["sourceSha"], "version": value["baseVersion"],
            "build": str(value["buildNumber"]), "scope": "unsigned; not installable without provisioning",
            "files": [file_record(ipa)]}


def verify_linux(value, folder):
    paths = [Path(folder) / f"FocuBili-v{value['debVersion']}-linux-{suffix}"
             for suffix in ["amd64.deb", "x64.tar.gz"]]
    metadata = text("dpkg-deb", "-f", str(paths[0]), "Package", "Version", "Architecture")
    require(metadata.splitlines() == ["Package: focubili", "Version: " + value["debVersion"], "Architecture: amd64"],
            "Debian identity/version/architecture differs")
    return {"sourceSha": value["sourceSha"], "version": value["baseVersion"],
            "build": str(value["buildNumber"]), "debVersion": value["debVersion"],
            "files": [file_record(path) for path in paths]}


def checked_file(folder, record):
    require(isinstance(record, dict) and isinstance(record.get("file"), str), "Artifact record missing")
    require(Path(record["file"]).name == record["file"] and "/" not in record["file"] and "\\" not in record["file"],
            "Artifact filename must be a basename")
    require(type(record.get("bytes")) is int and record["bytes"] > 0 and
            isinstance(record.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", record["sha256"]),
            "Invalid artifact size/digest")
    path = folder / record["file"]
    require(file_record(path) == {key: record[key] for key in ["file", "bytes", "sha256"]}, "Artifact digest differs")
    return path


def stage(value, source, output):
    source, output = Path(source), Path(output)
    require(not output.exists(), "Release output must be new")
    ci = json.loads((source / "ci-verification.json").read_text(encoding="utf-8"))
    require(ci["sourceSha"] == value["sourceSha"] and
            set(ci["runs"]) == {"ci.yml", "apple-build.yml", "linux-build.yml"} and
            all(type(number) is int and number > 0 for number in ci["runs"].values()), "Exact-source CI evidence missing")
    artifacts = []
    prefix = "FocuBili-v" + value["releaseVersion"]
    android = json.loads((source / "android/android-beta-verification.json").read_text(encoding="utf-8"))
    require(android["sourceSha"] == value["sourceSha"] and android["package"] == PACKAGE and
            android["versionCode"] == value["buildNumber"] and android["versionName"] == value["releaseVersion"] and
            android["certificateSha256"] == CERTIFICATE, "Android evidence does not match Beta plan")
    artifacts.append(("android", checked_file(source / "android", android), prefix + "-android-preview.apk"))
    for platform, filename, endings in [
        ("windows", "windows-package-verification.json", ["windows-x64-setup.exe", "windows-x64-portable.zip"]),
        ("linux", "linux-beta-verification.json", ["linux-amd64.deb", "linux-x64.tar.gz"]),
        ("ios", "ios-beta-verification.json", ["ios-unsigned.ipa"]),
    ]:
        record = json.loads((source / platform / filename).read_text(encoding="utf-8"))
        require(record["sourceSha"] == value["sourceSha"] and record["version"] == value["baseVersion"] and
                record["build"] == str(value["buildNumber"]), "Cross-source or cross-version platform evidence")
        require(len(record["files"]) == len(endings), "Missing platform artifacts")
        if platform == "linux":
            require(record["debVersion"] == value["debVersion"], "Incorrect Debian Beta ordering")
        for item, ending in zip(record["files"], endings):
            path = checked_file(source / platform, item)
            require(path.name.endswith(ending.split("-", 1)[-1]), "Unexpected platform artifact type")
            artifacts.append((platform, path, prefix + "-" + ending))
    mac = json.loads((source / "macos/macos-package-verification.json").read_text(encoding="utf-8"))
    require(mac["source_sha"] == value["sourceSha"] and mac["version"] == value["baseVersion"] and
            mac["build"] == str(value["buildNumber"]) and mac["bundle_id"] == "com.focubili.app" and
            mac["normal_app_matches_dmg"] is True and mac["adhoc_signature_verified"] is True and
            mac["sandbox_and_network_entitlements_verified"] is True and mac["architectures"], "macOS verification missing")
    dmg = checked_file(source / "macos", {"file": mac["dmg_name"], "bytes": mac["dmg_size"], "sha256": mac["dmg_sha256"]})
    artifacts.append(("macos", dmg, prefix + "-macos.dmg"))
    # Verify every input before creating any releasable output.
    output.mkdir(parents=True)
    assets = []
    for platform, path, name in artifacts:
        destination = output / name
        shutil.copyfile(path, destination)
        assets.append({"platform": platform, **file_record(destination)})
    android = {**android, "file": prefix + "-android-preview.apk"}
    manifest = {**value, "android": android, "assets": assets, "verification": ci,
                "macosArchitectures": mac["architectures"],
                "limitations": ["Android preview cannot replace archived 5bd1 Beta4", "Desktop IDs and data paths are shared with stable",
                                "macOS ad-hoc signed, not notarized", "iOS unsigned; not TestFlight"]}
    save(output / "beta-release-manifest.json", manifest)
    checksums = [f"{file_record(path)['sha256']}  {path.name}" for path in sorted(output.iterdir())]
    (output / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")
    return manifest


def verify_upload(value, folder, draft):
    release = json.loads(text("gh", "api", f"repos/{REPOSITORY}/releases/tags/{value['tag']}"))
    require(release["tag_name"] == value["tag"] and release["draft"] is draft and
            release["prerelease"] is True, "Remote release is not the expected Beta state")
    files = {path.name: file_record(path) for path in Path(folder).iterdir() if path.is_file()}
    assets = release["assets"]
    require(len(assets) == len(files) and {asset["name"] for asset in assets} == set(files), "Uploaded asset set differs")
    for asset in assets:
        expected = files[asset["name"]]
        require(asset["size"] == expected["bytes"] and asset.get("digest") == "sha256:" + expected["sha256"],
                "GitHub-reported uploaded bytes/digest differ")
    return {"tag": value["tag"], "sourceSha": value["sourceSha"], "verifiedAssets": len(files), "draft": draft}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "build", "inventory", "wait-ci", "android", "windows", "ios", "linux", "stage", "verify-upload"])
    parser.add_argument("--beta-number")
    parser.add_argument("--source-sha")
    parser.add_argument("--plan")
    parser.add_argument("--output")
    parser.add_argument("--platform", choices=["apk", "windows", "macos", "linux", "ios", "ios-simulator"])
    parser.add_argument("--apk")
    parser.add_argument("--aapt")
    parser.add_argument("--apksigner")
    parser.add_argument("--folder")
    parser.add_argument("--executable")
    parser.add_argument("--product-version")
    parser.add_argument("--file-version")
    parser.add_argument("--ipa")
    parser.add_argument("--draft", action="store_true")
    arguments = parser.parse_args()
    if arguments.command == "wait-ci":
        require(SHA.fullmatch(arguments.source_sha or "") is not None, "Invalid source SHA")
        result = wait_ci(arguments.source_sha)
    else:
        value = load_plan(arguments.plan) if arguments.plan else checkout_plan(arguments.beta_number, arguments.source_sha)
        if arguments.command in {"build", "android", "windows", "ios", "linux"}:
            require(text("git", "rev-parse", "HEAD") == value["sourceSha"], "Build/verification checkout changed")
        if arguments.command == "plan":
            result = value
        elif arguments.command == "build":
            run_flutter(build_arguments(arguments.platform, value)[1:])
            return
        elif arguments.command == "inventory":
            result = inventory(value, arguments.aapt)
        elif arguments.command == "android":
            result = verify_android(value, arguments.apk, arguments.aapt, arguments.apksigner)
        elif arguments.command == "windows":
            result = verify_windows(value, arguments.folder, arguments.executable, arguments.product_version, arguments.file_version)
        elif arguments.command == "ios":
            result = verify_ios(value, arguments.ipa)
        elif arguments.command == "linux":
            result = verify_linux(value, arguments.folder)
        elif arguments.command == "verify-upload":
            result = verify_upload(value, arguments.folder, arguments.draft)
        else:
            result = stage(value, arguments.folder, arguments.output)
            print(json.dumps({"tag": result["tag"], "assetCount": len(result["assets"])}))
            return
    if arguments.output:
        save(arguments.output, result)
    else:
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
