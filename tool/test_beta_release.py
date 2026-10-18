"""Offline fault tests: all binaries/HTTP/CLI output below are synthetic."""
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import beta_release as beta


class BetaReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="focubili-beta-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.value = beta.plan("1", "a" * 40, "version: 1.9.0+2026\n")

    def apk(self, name="test.apk", arm64=True):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("lib/" + ("arm64-v8a" if arm64 else "x86_64") + "/libmain.so", b"synthetic")
        return path

    def badging(self, **updates):
        metadata = {"package": beta.PACKAGE, "versionCode": 2026, "versionName": "1.9.0-beta.1", **updates}
        return (f"package: name='{metadata['package']}' versionCode='{metadata['versionCode']}' "
                f"versionName='{metadata['versionName']}' platformBuildVersionName='16'\n")

    def android(self, raw=None, certificate=None, arm64=True):
        path = self.apk(arm64=arm64)
        with patch.object(beta, "text", side_effect=[raw or self.badging(), certificate or
              "Number of signers: 1\nSigner #1 certificate SHA-256 digest: " + beta.CERTIFICATE]):
            return beta.verify_android(self.value, path, "aapt", "apksigner")

    def inventory(self, codes=(2024,), packages=None, truncate=False, pages=False):
        assets = [{"id": index + 1, "name": f"release-{index}.apk", "size": 3} for index in range(len(codes))]
        releases = [{"draft": False, "tag_name": "old", "assets": assets}]
        document = [[releases[0]]] if not pages else [[{**releases[0], "assets": assets[:1]}], [{**releases[0], "assets": assets[1:]}]]
        outputs = [json.dumps(document)]
        for index, code in enumerate(codes):
            outputs.append(self.badging(versionCode=code, package=(packages or [beta.PACKAGE] * len(codes))[index]) + "application-debuggable\n")
        with patch.object(beta, "text", side_effect=outputs), patch.object(beta, "run", return_value=b"ap" if truncate else b"apk") as command:
            result = beta.inventory(self.value, "aapt")
            for invocation in command.call_args_list:
                self.assertNotIn("POST", invocation.args)
                self.assertNotIn("--method", invocation.args)
            return result

    def test_plan_refuses_archived_equal_lower_and_local_27(self):
        for code in [1, 27, 2023, 2024, 2025, 65536]:
            with self.subTest(code=code), self.assertRaises(ValueError):
                beta.plan("1", "a" * 40, f"version: 1.9.0+{code}\n")

    def test_archived_preview_floor_tracks_all_known_apk_verification_records(self):
        repository = Path(__file__).resolve().parents[1]

        def codes(value):
            if isinstance(value, dict):
                if value.get("package") == beta.PACKAGE:
                    yield value["versionCode"]
                for child in value.values():
                    yield from codes(child)
            elif isinstance(value, list):
                for child in value:
                    yield from codes(child)

        known = []
        for name in ["beta3", "beta4", "beta5"]:
            known.extend(codes(json.loads((repository / "docs" / name / "apk-verification.json").read_text(encoding="utf-8"))))
        self.assertEqual(max(known), beta.FLOOR)

    def test_preview_identity_is_scoped_to_build_type_not_signing_configuration(self):
        gradle = (Path(__file__).resolve().parents[1] / "android/app/build.gradle").read_text(encoding="utf-8")
        signing, types = gradle.split("    signingConfigs {", 1)[1].split("    buildTypes {", 1)
        self.assertNotIn("applicationIdSuffix", signing)
        release = types.split("        release {", 1)[1]
        self.assertIn('if (betaNumber != null) {\n                applicationIdSuffix ".preview"', release)
        self.assertIn('versionNameSuffix "-beta.${betaNumber}"', release)
        self.assertIn("signingConfig signingConfigs.release", release)
        self.assertIn(f"flutterVersionCode.toInteger() <= {beta.FLOOR}", gradle)

    def test_plan_rejects_noncanonical_versions_and_identifiers(self):
        for source in ["version: 1.8.0+2026", "version: 1.9.00+2026", "version: 1.9.0-beta.1+2026",
                       "version: 1.9.0+2026\nversion: 1.9.0+2026"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                beta.plan("1", "a" * 40, source)
        for number in ["0", "01", "1;echo", "-1"]:
            with self.subTest(number=number), self.assertRaises(ValueError):
                beta.plan(number, "a" * 40, "version: 1.9.0+2026")
        with self.assertRaises(ValueError):
            beta.plan("1", "abc", "version: 1.9.0+2026")

    def test_build_injects_one_committed_counter_and_channel_on_every_platform(self):
        for platform in ["apk", "windows", "macos", "linux", "ios", "ios-simulator"]:
            with self.subTest(platform=platform):
                command = beta.build_arguments(platform, self.value)
                self.assertEqual(command.count("--build-number=2026"), 1)
                self.assertIn("--build-name=1.9.0", command)
                self.assertIn("--dart-define=FOCUBILI_RELEASE_CHANNEL=beta", command)
                self.assertIn("--dart-define=FOCUBILI_RELEASE_VERSION=1.9.0-beta.1", command)
                if platform == "apk":
                    self.assertIn("--android-project-arg=focubili.betaNumber=1", command)
                    self.assertNotIn("--no-pub", command)

    def test_flutter_resolves_windows_bat_and_preserves_paths_and_spaced_arguments(self):
        executable = r"C:\Program Files\Flutter SDK\bin\flutter.BAT"
        arguments = ["build", "windows", "--dart-define=DISPLAY_NAME=Beta candidate"]
        with patch.object(beta.shutil, "which", return_value=executable) as lookup, patch.object(beta.subprocess, "run") as launch:
            beta.run_flutter(arguments)
        lookup.assert_called_once_with("flutter")
        launch.assert_called_once_with([executable, *arguments], check=True, shell=False)
        self.assertEqual(arguments, ["build", "windows", "--dart-define=DISPLAY_NAME=Beta candidate"])

    def test_flutter_resolves_posix_launcher_without_a_shell(self):
        with patch.object(beta.shutil, "which", return_value="/opt/flutter/bin/flutter"), patch.object(beta.subprocess, "run") as launch:
            beta.run_flutter(["--version"])
        launch.assert_called_once_with(["/opt/flutter/bin/flutter", "--version"], check=True, shell=False)

    def test_missing_flutter_fails_before_launch(self):
        with patch.object(beta.shutil, "which", return_value=None), patch.object(beta.subprocess, "run") as launch:
            with self.assertRaisesRegex(ValueError, "Flutter executable not found on PATH"):
                beta.run_flutter(["--version"])
        launch.assert_not_called()

    def test_checkout_sha_must_match_before_reading_plan(self):
        with patch.object(beta, "text", return_value="b" * 40), self.assertRaises(ValueError):
            beta.checkout_plan("1", "a" * 40)

    def test_plan_round_trip_refuses_unknown_or_modified_fields(self):
        path = self.root / "plan.json"
        beta.save(path, self.value)
        self.assertEqual(beta.load_plan(path), self.value)
        beta.save(path, {**self.value, "buildNumber": 2027})
        with self.assertRaises(ValueError):
            beta.load_plan(path)

    def test_inventory_counts_historical_debug_apks_without_requiring_new_certificate(self):
        result = self.inventory()
        self.assertEqual(result["maximumKnownVersionCode"], 2025)

    def test_inventory_refuses_equal_published_build(self):
        with self.assertRaises(ValueError):
            self.inventory((2026,))

    def test_inventory_counts_other_workflows_and_stable_package_codes(self):
        with self.assertRaises(ValueError):
            self.inventory((3000,), ["com.focubili.app"])

    def test_inventory_reads_all_pages_before_accepting_counter(self):
        with self.assertRaises(ValueError):
            self.inventory((2024, 2026), pages=True)

    def test_inventory_refuses_unknown_package_and_truncated_download(self):
        with self.assertRaises(ValueError):
            self.inventory(packages=["example.other.app"])
        with self.assertRaises(ValueError):
            self.inventory(truncate=True)

    def test_inventory_network_or_malformed_pages_never_mean_empty(self):
        with patch.object(beta, "text", side_effect=subprocess.CalledProcessError(1, "gh")), self.assertRaises(subprocess.CalledProcessError):
            beta.inventory(self.value, "aapt")
        with patch.object(beta, "text", return_value='{"error":"unavailable"}'), self.assertRaises(ValueError):
            beta.inventory(self.value, "aapt")

    def test_android_tool_output_controls_metadata_and_digest(self):
        record = self.android()
        self.assertEqual(record["certificateSha256"], beta.CERTIFICATE)
        self.assertEqual(record["sourceSha"], "a" * 40)
        self.assertEqual(record["abis"], ["arm64-v8a"])

    def test_android_rejects_stable_package_wrong_name_or_wrong_code(self):
        for update in [{"package": "com.focubili.app"}, {"versionCode": 27}, {"versionName": "1.9.0"}]:
            with self.subTest(update=update), self.assertRaises(ValueError):
                self.android(raw=self.badging(**update))

    def test_android_rejects_debuggable_artifact(self):
        with self.assertRaises(ValueError):
            self.android(raw=self.badging() + "application-debuggable\n")

    def test_android_rejects_archived_or_ambiguous_signer(self):
        for raw in ["Number of signers: 1\nSigner #1 certificate SHA-256 digest: " + "5b" * 32,
                    "Number of signers: 2\nSigner #1 certificate SHA-256 digest: " + beta.CERTIFICATE,
                    "Signer #1 certificate SHA-256 digest: " + beta.CERTIFICATE + "\nSigner #2 certificate SHA-256 digest: " + "bb" * 32]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                self.android(certificate=raw)

    def test_android_rejects_missing_arm64(self):
        with self.assertRaises(ValueError):
            self.android(arm64=False)

    def test_apksigner_command_failure_is_fatal(self):
        with patch.object(beta, "text", side_effect=[self.badging(), subprocess.CalledProcessError(1, "apksigner")]), self.assertRaises(subprocess.CalledProcessError):
            beta.verify_android(self.value, self.apk(), "aapt", "apksigner")

    def ios(self, **updates):
        path = self.root / "FocuBili-ios-unsigned.ipa"
        info = {"CFBundleIdentifier": "com.focubili.app", "CFBundleShortVersionString": "1.9.0", "CFBundleVersion": "2026", **updates}
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Runner.app/Runner", b"synthetic executable")
        return beta.verify_ios(self.value, path)

    def test_unsigned_ios_metadata_is_checked_without_claiming_signing(self):
        self.assertIn("unsigned", self.ios()["scope"])
        for fields in [{"CFBundleIdentifier": "wrong"}, {"CFBundleVersion": "27"}, {"CFBundleShortVersionString": "1.8.0"}]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.ios(**fields)

    def test_linux_reads_real_package_metadata_and_refuses_stable_ordering(self):
        folder = self.root / "linux"
        folder.mkdir()
        for ending in ["amd64.deb", "x64.tar.gz"]:
            (folder / f"FocuBili-v{self.value['debVersion']}-linux-{ending}").write_bytes(b"synthetic")
        raw = f"Package: focubili\nVersion: {self.value['debVersion']}\nArchitecture: amd64"
        with patch.object(beta, "text", return_value=raw):
            self.assertEqual(beta.verify_linux(self.value, folder)["debVersion"], "1.9.0~beta.1+2026")
        with patch.object(beta, "text", return_value=raw.replace(self.value["debVersion"], "1.9.0")), self.assertRaises(ValueError):
            beta.verify_linux(self.value, folder)

    def test_windows_checks_fixed_version_and_portable_executable_bytes(self):
        raw = bytearray(128)
        raw[:2] = b"MZ"
        struct.pack_into("<I", raw, 60, 80)
        raw[80:84] = b"PE\0\0"
        struct.pack_into("<H", raw, 84, 0x8664)
        executable = self.root / "FocuBili.exe"
        executable.write_bytes(raw)
        (self.root / "FocuBili-v1.9.0-windows-x64-setup.exe").write_bytes(raw)
        archive = self.root / "FocuBili-v1.9.0-windows-x64-portable.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("FocuBili.exe", raw)
            for name in ["flutter_windows.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"]:
                output.writestr(name, b"synthetic runtime")
        self.assertEqual(len(beta.verify_windows(self.value, self.root, executable, "1.9.0+2026", "1.9.0.2026")["files"]), 2)
        with self.assertRaises(ValueError):
            beta.verify_windows(self.value, self.root, executable, "1.9.0+27", "1.9.0.2026")
        executable.write_bytes(raw + b"changed")
        with self.assertRaises(ValueError):
            beta.verify_windows(self.value, self.root, executable, "1.9.0+2026", "1.9.0.2026")

    def staged_inputs(self):
        source = self.root / "inputs"
        source.mkdir()
        beta.save(source / "ci-verification.json", {"sourceSha": "a" * 40,
                  "runs": {"ci.yml": 1, "apple-build.yml": 2, "linux-build.yml": 3}})
        for platform, filename, files in [
            ("windows", "windows-package-verification.json", ["FocuBili-v1.9.0-windows-x64-setup.exe", "FocuBili-v1.9.0-windows-x64-portable.zip"]),
            ("linux", "linux-beta-verification.json", ["FocuBili-v1.9.0~beta.1+2026-linux-amd64.deb", "FocuBili-v1.9.0~beta.1+2026-linux-x64.tar.gz"]),
            ("ios", "ios-beta-verification.json", ["FocuBili-ios-unsigned.ipa"]),
        ]:
            folder = source / platform
            folder.mkdir()
            for name in files:
                (folder / name).write_bytes(b"synthetic " + name.encode())
            beta.save(folder / filename, {"sourceSha": "a" * 40, "version": "1.9.0", "build": "2026",
                      "debVersion": self.value["debVersion"], "files": [beta.file_record(folder / name) for name in files]})
        android = source / "android"
        android.mkdir()
        (android / "app-release.apk").write_bytes(b"synthetic apk")
        beta.save(android / "android-beta-verification.json", {**beta.file_record(android / "app-release.apk"),
                  "sourceSha": "a" * 40, "package": beta.PACKAGE, "versionName": "1.9.0-beta.1", "versionCode": 2026,
                  "certificateSha256": beta.CERTIFICATE})
        mac = source / "macos"
        mac.mkdir()
        (mac / "preview.dmg").write_bytes(b"synthetic dmg")
        record = beta.file_record(mac / "preview.dmg")
        beta.save(mac / "macos-package-verification.json", {"source_sha": "a" * 40, "version": "1.9.0", "build": "2026",
                  "dmg_name": record["file"], "dmg_size": record["bytes"], "dmg_sha256": record["sha256"],
                  "bundle_id": "com.focubili.app", "normal_app_matches_dmg": True, "adhoc_signature_verified": True,
                  "sandbox_and_network_entitlements_verified": True, "architectures": ["arm64"]})
        return source

    def test_staging_keeps_identity_hashes_and_marks_platform_limitations(self):
        result = beta.stage(self.value, self.staged_inputs(), self.root / "release")
        self.assertEqual(len(result["assets"]), 7)
        self.assertEqual(result["android"]["file"], "FocuBili-v1.9.0-beta.1-android-preview.apk")
        self.assertEqual(len(list((self.root / "release").iterdir())), 9)
        self.assertIn("macOS ad-hoc signed, not notarized", result["limitations"])
        self.assertTrue((self.root / "release/SHA256SUMS.txt").is_file())

    def test_staging_is_all_or_fail_on_missing_platform(self):
        source = self.staged_inputs()
        (source / "ios/ios-beta-verification.json").unlink()
        with self.assertRaises(FileNotFoundError):
            beta.stage(self.value, source, self.root / "release")
        self.assertFalse((self.root / "release").exists())

    def test_staging_rejects_wrong_source_before_creating_release(self):
        source = self.staged_inputs()
        path = source / "windows/windows-package-verification.json"
        record = json.loads(path.read_text())
        beta.save(path, {**record, "sourceSha": "b" * 40})
        with self.assertRaises(ValueError):
            beta.stage(self.value, source, self.root / "release")
        self.assertFalse((self.root / "release").exists())

    def test_staging_rejects_tampered_bytes_and_filename_traversal(self):
        source = self.staged_inputs()
        path = source / "android/android-beta-verification.json"
        record = json.loads(path.read_text())
        beta.save(path, {**record, "file": "../escape.apk"})
        with self.assertRaises(ValueError):
            beta.stage(self.value, source, self.root / "release")
        beta.save(path, record)
        (source / "android/app-release.apk").write_bytes(b"different")
        with self.assertRaises(ValueError):
            beta.stage(self.value, source, self.root / "release")

    def test_staging_requires_exact_ci_identity_and_all_workflows(self):
        source = self.staged_inputs()
        beta.save(source / "ci-verification.json", {"sourceSha": "b" * 40, "runs": {"ci.yml": 1}})
        with self.assertRaises(ValueError):
            beta.stage(self.value, source, self.root / "release")

    def test_uploaded_assets_must_match_server_hash_size_set_and_prerelease_state(self):
        folder, remote = self.publication_inputs()
        record = remote["assets"][0]
        with patch.object(beta, "text", side_effect=self.release_responses(remote)):
            self.assertEqual(beta.verify_upload(self.value, folder, True)["verifiedAssets"], 6)
        for mutation in [{"prerelease": False}, {"draft": False}, {"assets": []},
                         {"assets": [{**record, "digest": "sha256:" + "0" * 64}, *remote["assets"][1:]]}]:
            with self.subTest(mutation=mutation), patch.object(beta, "text", side_effect=self.release_responses({**remote, **mutation})), self.assertRaises(ValueError):
                beta.verify_upload(self.value, folder, True)

    def publication_inputs(self):
        folder = self.root / "publication"
        folder.mkdir()
        prefix = "FocuBili-v1.9.0-beta.1-"
        endings = ["android-preview.apk", "windows-x64-setup.exe", "windows-x64-portable.zip",
                   "macos.dmg", "linux-amd64.deb", "ios-unsigned.ipa"]
        assets = []
        for number, ending in enumerate(endings, 1):
            path = folder / (prefix + ending)
            path.write_bytes(b"synthetic " + ending.encode())
            record = beta.file_record(path)
            assets.append({"id": number, "name": record["file"], "size": record["bytes"],
                           "digest": "sha256:" + record["sha256"], "state": "uploaded"})
        for name in [prefix + "linux-x64.tar.gz", "SHA256SUMS.txt", "beta-release-manifest.json"]:
            (folder / name).write_bytes(b"CI-only evidence")
        return folder, {"id": 123, "tag_name": self.value["tag"], "target_commitish": "a" * 40,
                        "draft": True, "prerelease": True, "assets": assets}

    def release_responses(self, detail, listing=None):
        return [json.dumps([[{"id": 123, "tag_name": self.value["tag"]}]] if listing is None else listing),
                json.dumps(detail)]

    def test_public_files_select_exactly_six_binaries_and_preserve_all_nine_ci_files(self):
        folder, remote = self.publication_inputs()
        before = {path.name: path.read_bytes() for path in folder.iterdir()}
        paths = beta.public_files(self.value, folder)
        self.assertEqual([path.name for path in paths], [asset["name"] for asset in remote["assets"]])
        self.assertEqual(before, {path.name: path.read_bytes() for path in folder.iterdir()})
        self.assertEqual(len(before), 9)

    def test_public_files_refuse_missing_empty_or_directory_binary(self):
        folder, remote = self.publication_inputs()
        path = folder / remote["assets"][0]["name"]
        path.unlink()
        with self.assertRaises(ValueError):
            beta.public_files(self.value, folder)
        path.write_bytes(b"")
        with self.assertRaises(ValueError):
            beta.public_files(self.value, folder)
        path.unlink()
        path.mkdir()
        with self.assertRaises(ValueError):
            beta.public_files(self.value, folder)

    def test_public_files_cli_emits_six_argument_safe_paths_and_nothing_else(self):
        folder, remote = self.publication_inputs()
        spaced = folder.with_name("candidate with spaces")
        folder.rename(spaced)
        plan = self.root / "plan.json"
        beta.save(plan, self.value)
        result = subprocess.run([sys.executable, "-X", "utf8", "-B", str(Path(beta.__file__)),
                                 "public-files", "--plan", str(plan), "--folder", str(spaced)],
                                check=True, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.stdout.splitlines(), [(spaced / asset["name"]).as_posix() for asset in remote["assets"]])
        self.assertEqual(result.stderr, "")

    def test_draft_is_found_on_later_list_page_and_read_by_numeric_id_without_tag_endpoint(self):
        folder, remote = self.publication_inputs()
        pages = [[{"id": 1, "tag_name": "v1.8.0"}], [{"id": 123, "tag_name": self.value["tag"]}]]

        def response(*arguments):
            if arguments[-1] == f"repos/{beta.REPOSITORY}/releases?per_page=100":
                return json.dumps(pages)
            if arguments[-1] == f"repos/{beta.REPOSITORY}/releases/123":
                return json.dumps(remote)
            raise subprocess.CalledProcessError(1, arguments, stderr="HTTP 404 (draft tag lookup)")

        with patch.object(beta, "text", side_effect=response) as command:
            result = beta.verify_upload(self.value, folder, True)
        self.assertEqual(result["releaseId"], 123)
        self.assertEqual(result["verifiedAssets"], 6)
        self.assertEqual(command.call_args_list[0].args,
                         ("gh", "api", "--method", "GET", "--paginate", "--slurp",
                          f"repos/{beta.REPOSITORY}/releases?per_page=100"))
        self.assertEqual(command.call_args_list[1].args,
                         ("gh", "api", "--method", "GET", f"repos/{beta.REPOSITORY}/releases/123"))

    def test_published_release_uses_the_same_unique_numeric_id_path(self):
        folder, remote = self.publication_inputs()
        remote["draft"] = False
        with patch.object(beta, "text", side_effect=self.release_responses(remote)):
            self.assertIs(beta.verify_upload(self.value, folder, False)["draft"], False)

    def test_release_list_missing_duplicate_or_malformed_never_falls_back_to_tag_lookup(self):
        folder, _ = self.publication_inputs()
        match = {"id": 123, "tag_name": self.value["tag"]}
        for pages in [[], [[]], [[match, match]], {"error": "unavailable"}, [match], [[None]],
                      [[{"id": True, "tag_name": self.value["tag"]}]],
                      [[{"id": "123", "tag_name": self.value["tag"]}]],
                      [[{"id": 0, "tag_name": self.value["tag"]}]]]:
            with self.subTest(pages=pages), patch.object(beta, "text", return_value=json.dumps(pages)) as command:
                with self.assertRaises(ValueError):
                    beta.verify_upload(self.value, folder, True)
                self.assertEqual(command.call_count, 1)

    def test_release_detail_identity_source_and_state_must_still_match_after_lookup(self):
        folder, remote = self.publication_inputs()
        for mutation in [{"id": 124}, {"id": True}, {"tag_name": "v1.9.0-beta.2"},
                         {"target_commitish": "dev"}, {"target_commitish": "b" * 40},
                         {"draft": False}, {"draft": 1}, {"prerelease": False}, {"prerelease": 1}]:
            with self.subTest(mutation=mutation), patch.object(beta, "text", side_effect=self.release_responses({**remote, **mutation})):
                with self.assertRaises(ValueError):
                    beta.verify_upload(self.value, folder, True)

    def test_uploaded_six_asset_set_rejects_duplicates_metadata_tar_and_unuploaded_records(self):
        folder, remote = self.publication_inputs()
        first = remote["assets"][0]
        for asset in [{**first, "id": 0}, {**first, "id": True}, {**first, "state": "starter"},
                      {**first, "size": str(first["size"])}, {**first, "size": first["size"] + 1},
                      {**first, "digest": None}, {**first, "digest": "sha256:" + "0" * 64},
                      {**first, "name": "beta-release-manifest.json"}, {**first, "name": "SHA256SUMS.txt"},
                      {**first, "name": "FocuBili-v1.9.0-beta.1-linux-x64.tar.gz"},
                      remote["assets"][1], {**first, "id": remote["assets"][1]["id"]}]:
            detail = {**remote, "assets": [asset, *remote["assets"][1:]]}
            with self.subTest(asset=asset), patch.object(beta, "text", side_effect=self.release_responses(detail)):
                with self.assertRaises(ValueError):
                    beta.verify_upload(self.value, folder, True)

    def test_release_api_errors_are_fatal_without_fallback_or_remote_writes(self):
        folder, remote = self.publication_inputs()
        for responses in [[subprocess.CalledProcessError(1, "gh")],
                          [self.release_responses(remote)[0], subprocess.CalledProcessError(1, "gh")]]:
            with self.subTest(responses=responses), patch.object(beta, "text", side_effect=responses) as command:
                with self.assertRaises(subprocess.CalledProcessError):
                    beta.verify_upload(self.value, folder, True)
                for call in command.call_args_list:
                    self.assertNotIn("POST", call.args)
                    self.assertNotIn("PATCH", call.args)
                    self.assertNotIn("DELETE", call.args)

    def test_workflow_publishes_explicit_public_file_array_and_checks_it_before_and_after(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/beta-release.yml").read_text(encoding="utf-8")
        self.assertIn('python3 tool/beta_release.py public-files --plan metadata/beta-plan.json --folder release > public-files.txt', workflow)
        self.assertIn('mapfile -t public_files < public-files.txt', workflow)
        self.assertIn('gh release create "$tag" "${public_files[@]}"', workflow)
        self.assertNotIn('gh release create "$tag" release/*', workflow)
        self.assertEqual(workflow.count('python3 tool/beta_release.py verify-upload --plan metadata/beta-plan.json --folder release'), 2)
        self.assertIn('path: release/*', workflow)
        self.assertLess(workflow.index('public-files --plan'), workflow.index('git tag -a'))
        quality = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('python3 -m unittest discover -s tool -p test_beta_release.py -v', quality)

    def test_ci_requires_success_for_every_exact_sha_run(self):
        run = {"headSha": "a" * 40, "databaseId": 1, "status": "completed", "conclusion": "success"}
        with patch.object(beta, "text", return_value=json.dumps([run])):
            self.assertEqual(len(beta.wait_ci("a" * 40)["runs"]), 3)
        with patch.object(beta, "text", return_value=json.dumps([{**run, "conclusion": "cancelled"}])), self.assertRaises(ValueError):
            beta.wait_ci("a" * 40)

    def test_ci_older_success_does_not_satisfy_requested_sha(self):
        run = {"headSha": "b" * 40, "databaseId": 1, "status": "completed", "conclusion": "success"}
        with patch.object(beta, "text", return_value=json.dumps([run])), patch("time.monotonic", side_effect=[0, 10000]), self.assertRaises(ValueError):
            beta.wait_ci("a" * 40)


if __name__ == "__main__":
    unittest.main()
