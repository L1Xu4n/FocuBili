# 1.9 Beta CI audit and candidate patch

Audit base: `6c2ea28efb2ce24bbca766166fb9c7ecc1d8be80`. Work is isolated on `codex/v19-beta-ci`; this patch does not modify the 1.8 publication checkout, `publish-release.yml`, app update consumers, or `pubspec.yaml`. No workflow was dispatched, tag/release pushed, signing key opened/generated, or real account data read during this work.

## Existing identity and version evidence

| Source | Observed identity |
| --- | --- |
| `android/app/build.gradle` | Ordinary release `com.focubili.app`; existing debug `.preview` and `-beta.1`; release refuses absent signing configuration and never falls back to debug signing. |
| `.github/workflows/release-build.yml` | Existing four `ANDROID_RELEASE_*` secrets restore the temporary release key; APK certificate is pinned to `65EF1FB301FB1121C1803E752F5B1EB24E55846502D8B5478F0FC11F58E9A8A9`. Secret availability and private key contents were not inspected. |
| `docs/beta3/apk-verification.json` | Preview code **2023**, certificate `5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0`. |
| `docs/beta4/apk-verification.json` | Preview code **2024**, same archived certificate; explicitly local ARM64 debug scope. |
| `docs/beta5/apk-verification.json`, `localArm64.versionCode` | Preview code **2025**, same archived certificate; installed-user certificate is explicitly unknown. |
| Current audited `pubspec.yaml` | Numeric desktop-compatible `1.9.0+27`; unsuitable for the new publishable preview build. |

The known floor is therefore **2025**, including the archive even if an old GitHub asset disappears. A candidate such as committed `1.9.0+2026` is the first permissible source counter, subject to the live inventory being lower. CI injects that exact committed value with `--build-number` for every main platform build. It does not derive identity from `run_number`, which is scoped to a workflow. The upper limit is 65535 for the existing Windows fixed version-resource field. Every later release must commit a larger counter. Android uses increasing version codes to prevent downgrades. [Android versioning](https://developer.android.com/studio/publish/versioning)

New signed Beta APKs retain `.preview` but use the existing **65EF** release identity. They can update only a preview installation accepting that signing identity and a lower version code. They cannot replace the archived **5BD1** Beta3/4/5 identity merely by increasing the code, and they do not replace stable `com.focubili.app`. No uninstall or automatic migration is proposed. The installed-user signing identity remains unverified. [Android app signing](https://developer.android.com/studio/publish/app-signing)

Windows installer AppId and data paths, macOS bundle ID, Linux package name, and iOS bundle ID remain shared with stable. Desktop Beta builds do not provide an isolated user-data sandbox. Windows/macOS/iOS native version fields remain numeric (`1.9.0`, build 2026 in the example); the application receives the Beta display version through the two defines below. Linux DEB metadata uses `1.9.0~beta.1+2026`, so a Beta sorts before final `1.9.0`.

## Implemented flow

`beta-release.yml` is manual-only, with `source_sha`, `beta_number`, and `publish` (default **false**). A full lowercase reviewed SHA must be reachable from the fetched repository's dev/master. The invocation must originate in the expected repository on dev/master. The signing reusable workflow repeats the ref/SHA/ancestry check before its existing secret-restoration step. PR events cannot reach signing through this entry point.

1. Validate source metadata and the offline release-tool fault suite. Read all GitHub release pages and download every non-draft APK by numeric asset ID. Inspect actual package/versionCode with `aapt`; stable and preview codes both contribute to the global maximum. Truncated downloads, unknown APK packages, API failures, and malformed metadata fail the run. A chosen source code must exceed both the archive floor and every observed actual APK code.
2. Wait for successful **push** runs of `ci.yml`, `apple-build.yml`, and `linux-build.yml` at exactly the requested source SHA. Another SHA, failed/cancelled latest matching run, or timeout cannot satisfy this gate.
3. Reuse existing release, Apple, and Linux workflows through additive `workflow_call` inputs. Existing push/PR triggers and their ordinary non-Beta build commands remain unchanged. Beta calls receive a separate concurrency identity to avoid cancelling normal Apple/Linux runs. Only the four existing Android release secrets are forwarded; no new credential is introduced.
4. Main Android/Windows/macOS/Linux/iOS and iOS simulator builds receive the same source counter and `FOCUBILI_RELEASE_CHANNEL=beta`, `FOCUBILI_RELEASE_VERSION=1.9.0-beta.N`. Android alone receives controlled `focubili.betaNumber`; its **release build type** adds `.preview` and `-beta.N`, while its signing configuration remains the existing release configuration. No global release appId change is made.
5. Require all candidate platform jobs to succeed. Download their artifacts from this same caller run, re-run actual APK metadata/signature verification, compare every selected file's size and SHA-256 with its platform evidence, and assemble the candidate plus manifest. Missing platforms, cross-SHA evidence, or altered bytes fail before any release directory is created. With `publish=false`, only the candidate CI artifact is produced.
6. With explicit `publish=true`, take the existing master publisher's concurrency lock and repeat actual published-APK inventory. Require committed `docs/RELEASE_NOTES_v1.9.0-beta.N.md`. Reject any existing release/draft, refuse moving an existing tag, and create a new annotated tag only at the verified SHA. Create a draft prerelease with `--latest=false`, verify uploaded names/bytes/server SHA-256 digests, then publish it still as prerelease and `latest=false`. Recheck uploaded assets and assert the stable latest release ID/tag is unchanged. A failed partial draft requires inspection; retries never overwrite it. [GitHub release CLI](https://cli.github.com/manual/gh_release_create), [editing drafts](https://cli.github.com/manual/gh_release_edit), [release-asset digest API](https://docs.github.com/en/rest/releases/assets)

The helper contains no remote mutations. The only future remote writes are confined to the explicit final workflow job with `contents: write`; all earlier jobs use read permissions. The final publication job shares `focubili-publish-refs/heads/master` with the existing stable publisher. GitHub's prerelease and `make_latest=false` behavior is also explicit in the API. [GitHub releases API](https://docs.github.com/en/rest/releases/releases)

## Asset and update-consumer contract

Tag: `v1.9.0-beta.N`. Source remains numeric `1.9.0+COUNTER`. The producer and the separate update-channel change agree on:

| Asset suffix after `FocuBili-v1.9.0-beta.N-` | Scope checked by candidate CI |
| --- | --- |
| `android-preview.apk` | Actual aapt package/version/code, no debuggable flag, apksigner success and one pinned release identity, ARM64 library presence, exact bytes/hash; checked again after artifact download. |
| `windows-x64-setup.exe` | Existing Inno build, resulting package bytes/hash. Windows signing is not asserted. |
| `windows-x64-portable.zip` | Actual normal executable ProductVersion/fixed FileVersion and PE x64 machine; archive executable must match it byte-for-byte and include required runtime DLLs. |
| `macos.dmg` | Existing read-only mount/normal-app comparison, actual Info.plist/version/build, codesign/entitlements, architecture list and DMG digest; normal launch, native video/window, and subscription probes remain required. Filename does not claim universal architecture. |
| `linux-amd64.deb`, `linux-x64.tar.gz` | Actual dpkg-deb package/version/architecture and package hashes; existing native build, dependency, normal launch, media/desktop-service and subscription probes remain required. |
| `ios-unsigned.ipa` | Actual archive Info.plist/bundle/version/build and executable presence; existing simulator runtime probes remain required. This is unsigned and requires external provisioning, not an installable TestFlight release. |

The nine-file **CI candidate** retains all seven binaries, `beta-release-manifest.json`, and `SHA256SUMS.txt`. The later [publication-maintenance policy](beta-publication-maintenance.md) limits public Release assets to six packages: APK, Windows setup/portable ZIP, macOS DMG, Linux DEB, and unsigned iOS IPA. The Linux tarball, manifest, and checksum file remain CI evidence and are not uploaded publicly.

Manifest format/version are `focubili.beta-release` / `1`; top-level channel/tag/sourceSha/baseVersion/betaNumber/buildNumber/releaseVersion match the validated plan. `android` includes package, versionName, versionCode, certificateSha256, file, bytes, sha256, sourceSha and ABIs. `assets` contains exactly the seven candidate binaries, including one APK, with platform/file/bytes/sha256. Existing native-verification evidence and platform limitations are included separately. The release target is the exact source SHA. The existing consumer requires the same-tag manifest before selecting a direct Beta download; when only six packages are public it retains version discovery and offers the safe Release page. Its package/certificate/code checks are not bypassed. This maintenance policy does not change already-built D3 packages.

## Local validation and remaining gates

Status: **implemented and local automation passed; no CI-native candidate or real-device release validation performed here**.

Commands run in the isolated worktree:

```text
python -X utf8 -B -m unittest discover -s tool -p test_beta_release.py -v
# 33 passed after launcher follow-up (initial candidate: 30).
# All HTTP/CLI metadata and binaries in these unit tests are synthetic.
python -m py_compile tool/beta_release.py tool/test_beta_release.py
# passed
flutter test --no-pub test/android_beta_version_test.dart test/release_workflow_config_test.dart test/app_update_service_test.dart --reporter expanded
# 11 passed on the audited baseline; the separate new update-channel suite is not counted here.
flutter analyze --no-pub
# No issues found (10.5 seconds).
python tool/beta_release.py plan --beta-number 1 --source-sha (git rev-parse HEAD)
# Expected exit 1 on audited source: committed build 27 is below 2026..65535.
```

The four affected workflow files were parsed with the existing Dart YAML library. Their existing push/PR triggers were compared structurally with `6c2ea28`; all matched. All 49 Bash and 4 PowerShell run blocks passed native syntax parsing without execution. This checks YAML and shell syntax, not GitHub server expression/schema acceptance or actual native execution. No full application build was run for this patch.

Windows launcher follow-up: `Popen(['flutter', ...])` does not resolve the SDK's `.BAT` through PATHEXT. The build command now resolves `shutil.which('flutter')`, refuses a missing tool, and passes the actual executable plus an argument list to `subprocess.run(..., check=True, shell=False)`. Three added tests cover a Windows `.BAT` path containing spaces, preservation of a spaced argument, a POSIX executable, and failure before launch when Flutter is absent. No shell command is constructed. This exact helper was also exercised against the installed SDK without building:

```powershell
python -X utf8 -B -c 'import sys; sys.path.insert(0, "tool"); import beta_release as beta; print("Resolved Flutter:", beta.shutil.which("flutter"), flush=True); beta.run_flutter(["--version"])'
# Resolved Flutter: C:\Users\L1XU4N\flutter\bin\flutter.BAT
# Exit 0: Flutter 3.44.6, Framework ee80f08bbf, Dart 3.12.2.
```

Before dispatch, integrate the reviewed producer and consumer patches (consumer candidate `6cc7a119a67df68a3b3a043f39ce4866e3ea9310`), commit the chosen global build counter **at least 2026**, and commit the exact-tag release notes. Current counter 27 is intentionally rejected. The producer-only audited tree does not yet read the two Beta defines at runtime; runtime channel/version assertions require the combined consumer change. Ensure the new manual workflow exists on the repository's default branch as required by GitHub; choosing a source SHA cannot bypass that availability rule. [Manual workflow dispatch](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

First run with `publish=false`; require all exact-SHA CI and candidate-native jobs to pass and inspect the actual artifacts/manifest. Existing release-secret availability, GitHub digest availability, native preview packaging, installation on a release-signed preview device, and upgrade/user-data behavior remain **unverified** until that CI/device evidence exists. A later authorized `publish=true` run still rechecks the live global counter. This patch is reviewable preparation, not evidence that any 1.9 Beta has been signed, uploaded, or published.

## Default-branch bootstrap boundary

The repository default branch is **master**, so a dev-only Beta workflow cannot yet be manually dispatched. After the separate 1.8 publication succeeds, the parent will prepare a controlled master bootstrap PR containing only the producer's CI capability: new `beta-release.yml`; additive reusable/Beta portions of `release-build.yml`, `apple-build.yml`, and `linux-build.yml`; `tool/beta_release.py`, its offline tests, and the optional Linux package-version handling; controlled Gradle Beta-property/build-type hunks; and this audit document. Transfer those scoped hunks onto current master, preserving its current 1.8 workflows, probes, debug suffix, and signing checks; do not copy whole 1.9 files over newer master content or merge the 1.9 branch history.

That bootstrap must not carry any 1.9 user-facing Dart feature/update-consumer code, pubspec version change, release notes, tag, or release publication. Ordinary release defaults remain stable `com.focubili.app`, with no Beta suffix unless the explicit property is supplied. Producer and consumer changes still need to be present together in the separately reviewed **1.9 source SHA** selected for a future Beta run; hosting CI capability on master does not make the 1.8 app a Beta build. No bootstrap PR or remote object was created during this task.
