# Update channels for 1.9 candidates

This change is based on `6c2ea28efb2ce24bbca766166fb9c7ecc1d8be80` in the isolated `codex/v19-update-channel` branch. It is a local candidate implementation, not a published release or an assertion that a final 1.8 base has been approved. No integration/1.8 tree, version, workflow or signing material was changed.

| Area | Status | Evidence / limit |
| --- | --- | --- |
| Stable update channel | Implemented; automated checks pass | Builds without new defines retain PackageInfo display and `/releases/latest`; draft/prerelease responses are rejected. |
| Beta discovery | Implemented; automated checks pass | Beta version, exact Android preview package, or compiled beta channel selects bounded prerelease history. |
| Android package separation | Implemented; automated checks pass | Direct stable APK requires `com.focubili.app`; direct beta APK requires `com.focubili.app.preview` and matching release metadata. Unknown identity offers the Release page. |
| Public manifest / HTTP boundaries | Implemented; automated checks pass | Same repository/tag/name; bounded JSON and redirects; no account service or authentication header. |
| Real network, OS installation metadata and device upgrade | Not run | All new HTTP/package-info inputs were synthetic on a Windows host. No App was started or account read. |

## Channel and version rules

Stable builds retain their existing version string and latest endpoint. Beta builds can use `FOCUBILI_RELEASE_CHANNEL=beta` and `FOCUBILI_RELEASE_VERSION=1.9.0-beta.N` as compile-time Dart defines. The version override is accepted only for a valid beta SemVer and the beta channel. A nonempty native PackageInfo build number replaces any build metadata already present in that override, producing one `+` suffix; an empty native counter preserves the valid override metadata. The separately loaded native build number still controls Android upgrade compatibility. This supports desktop packagers that require a numeric native version. Android also checks its own public PackageInfo package name. Package, build number and public signing-certificate digest come through an optional installation-provider interface; existing version-only providers need no interface migration.

Beta discovery requests at most three pages of 30 entries from this repository's public releases API. Page URLs are computed locally; API Link/redirect destinations are not followed. It skips drafts, non-prereleases and invalid SemVer tags, then chooses the highest SemVer strictly above the installed version in those **at most 90 recent entries**. Build metadata does not establish precedence. A full page is not proof that all release history was searched; both no-update and available messages explicitly state the bounded history. A later page error fails discovery instead of promoting a partial earlier candidate. Beta never falls back to the stable latest endpoint or its APK.

## Beta asset contract

The producer and consumer agree on `beta-release-manifest.json` with required fields:

```text
format: focubili.beta-release, version: 1, channel: beta
tag: v<baseVersion>-beta.<betaNumber>, sourceSha: 40 hex characters
baseVersion, betaNumber: positive integer, buildNumber: positive Android-safe integer
android: {package, versionName, versionCode, certificateSha256, file, bytes, sha256}
assets: [{platform, file, bytes, sha256}]
```

The Android package is `com.focubili.app.preview`; its canonical filename is `FocuBili-v<releaseVersion>-android-preview.apk`. There must be exactly one Android asset, with identical file/size/hash in the Android and assets records. Version name, beta number and build number must agree. Direct Beta APK selection requires an installed 64-hex certificate digest matching the manifest and a canonical nonnegative decimal native versionCode strictly below the candidate code. A missing, malformed, unreadable or mismatched certificate/code offers only the Release page. A higher candidate code does not establish compatibility with an older Beta signed by a different key.

Extra producer fields such as verification scope, architectures and limitations are retained as producer documentation, not treated as proof of extra capabilities. When supplied, `releaseVersion` must agree with the tag and `android.sourceSha` must agree with top-level sourceSha. A GitHub `target_commitish` that is a full SHA must match sourceSha; branch names are not resolved with additional requests. The consumer does not independently verify a branch tip, download the APK, hash its bytes or verify its APK signature. Producer verification of the actual artifact remains necessary.

Every selectable entry must match a same-tag GitHub API asset's exact name and integer byte size; a supplied API SHA256 digest must agree. Asset URLs must use this repository's HTTPS download path, exact tag/name, no credentials/query/fragment and no nonstandard port. Stable Android selection excludes preview/beta/debug filenames. Metadata failure, absence or mismatch keeps a valid discovered release available through its safe repository Release page, with no direct package fallback.

JSON reads are capped at 1 MiB for release API responses and 64 KiB for the manifest. The manifest may follow at most three HTTPS redirects to GitHub's release-assets/objects CDN. No Authorization or Cookie is attached, response bodies are not logged, and failures expose a static message. No user credential, session or private repository access is used.

## Android metadata failure audit

The initial consumer conditionally compared certificate/code only when present. Source inspection of the installed `package_info_plus 8.3.1` Android `PackageInfoPlugin.kt` confirmed that `getBuildSignature()` can return null for absent signing information/signatures or caught signature-read exceptions, while `getAll` still returns package/version/code. The platform-interface `MethodChannelPackageInfo.getAll` maps the omitted signature to `''`. This is an actual native error-return path, not an assumption that a real user's certificate was read. Before this fix, the synthetic real MethodChannel path (package/version/code present, signature omitted) returned a direct preview APK: the regression failed at the expected-null download URL assertion.

This was a P2 package-selection correctness gap: the about page opens an external download URL and does not install an APK or bypass Android signing. Unknown certificate data nevertheless cannot establish that a preview artifact is a compatible update. The strict gate now falls back without hiding valid release discovery. A whole PackageInfo method failure already prevents version loading; it does not fabricate package identity. Successful current Android code reads use `getLongVersionCode(info).toString()`, so no unparsable counter is produced by that normal native path. Invalid/omitted counters are covered defensively at the consumer boundary, not claimed as an observed device failure.

Archived public `docs/beta4/apk-verification.json` and `docs/beta5/apk-verification.json` record preview codes 2024/2025 with certificate `5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0`. Synthetic fixtures prove that a higher code 2026 with the agreed CI certificate `65ef1fb301fb1121c1803e752f5b1eb24e55846502d8b5478f0fc11f58e9a8a9` remains a Release-page choice for either old certificate, while an installation with the matching CI certificate and lower code still gets the direct APK. These public summaries and synthetic fixtures do not establish a user's installed signature or verify a published 2026 artifact.

## Automated evidence

Executed on the Windows host with the already installed Flutter/Dart toolchain, using mocked HTTP, PackageInfo and SharedPreferences. No SDK/tool installation, new license, signing key or actual application/network session was involved.

```powershell
flutter test --no-pub --reporter compact test/app_update_beta_channel_test.dart test/app_update_service_test.dart test/app_update_ignore_test.dart test/update_ignore_ui_test.dart
```

Final result after the metadata and strict Android gate reviews: **90 passed, 0 failed** (the original 77, three build-metadata/native-counter regressions and ten strict-gate regressions; 69 new channel/HTTP/metadata cases and 21 existing stable/ignore/widget cases). Cases include no higher prerelease, later-page selection and cap, drafts and stable exclusion, numeric SemVer ordering, HTTP 401/403/429/500, API/manifest redirect rejection and cap, malformed/oversized bodies, source/tag/package/version/type/asset/digest disagreement, unknown installation identity, certificate/code mismatch, producer extension compatibility and stable latest/download/ignore UI behavior. The ten strict-gate cases cover the real MethodChannel's omitted-signature mapping, six invalid/omitted native-code forms, two archived public old-certificate/code combinations, and a matching-CI-certificate positive case.

The review regression was reproduced before the production fix: a valid override `1.9.0-beta.1+local` with native build `2031` or `2033` produced an invalid double-`+` version (two failing cases), while the empty native counter case passed. The three cases now verify valid displayed SemVer, higher-beta discovery, empty-counter metadata preservation and independent rejection of an APK whose native code `2032` is below the actual installed code `2033`. The usual producer override without metadata and builds without defines remain covered by the original tests.

```powershell
flutter analyze --no-pub lib/services/app_update_service.dart lib/services/app_update_release_manifest.dart lib/services/app_update_transport.dart test/app_update_beta_channel_test.dart test/app_update_ignore_test.dart test/update_ignore_ui_test.dart
dart format --output=none --set-exit-if-changed lib/services/app_update_service.dart lib/services/app_update_release_manifest.dart lib/services/app_update_transport.dart test/app_update_beta_channel_test.dart test/app_update_ignore_test.dart test/update_ignore_ui_test.dart
git diff --check
```

Final analyze: **no issues**. Six changed Dart files formatted with **0 further changes**; diff whitespace check passes. Initial test-fixture compile and lint diagnostics were corrected before this final run. No full-suite run or APK rebuild was performed for this change. The previously delivered local APK from `7c6dbe6` does not contain this fix.

## Pending manual verification

1. With a separately authorized build and existing public release fixtures, verify a stable install retains its native version display and checks latest. Confirm it offers only a stable Android APK for the stable package.
2. Verify a beta build's compile defines display the beta version on desktop and Android. Confirm preview discovery uses release pages rather than latest, selects a higher prerelease and explains the 90-entry boundary.
3. With matching producer-verified preview metadata, confirm the direct download points to the same-tag preview APK. Test missing metadata, mismatched package/certificate or non-increasing code: the button must open the Release page instead.
4. Verify offline/rate-limit behavior is a retryable static failure and existing ignore-update/manual-check behavior remains intact. Actual OS upgrade compatibility requires the actual installed and downloaded artifact signatures; manifest selection alone does not establish it.

These are pending checks, not device or publication evidence. They do not require a Bilibili login.
