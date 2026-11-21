# Beta publication maintenance: draft lookup and six public packages

Base: current dev `2576b16a862312da0ceb6b3b29c9ff267da9e612` (PR #70). This is a feature-branch maintenance change for review into **dev**. It is not a dev-to-master merge or a release publication. Root owns any subsequent remote operation. No release/draft/tag, frozen build, published asset, signing key, user account, output delivery file, or other checkout was changed here.

## Frozen source and updater compatibility

The frozen Beta source is D3 `5cc5c770bf2465aa9a2ca5b6935a5c34d3449613`. Its updater files (`app_update_service.dart`, `app_update_release_manifest.dart`, and `app_update_transport.dart`) are byte-identical Git blobs to the base dev versions. Both versions find the newer prerelease from bounded release history, then require exactly one public `beta-release-manifest.json` before selecting a direct download. Android additionally checks preview package, installed certificate, increasing native counter, and manifest/asset identity, size, and hash metadata. Desktop Beta downloads also use the manifest gate.

With the six-package policy below, these consumers still discover and display a newer version; their action is **View Release**, with a trusted project Release page, rather than an unverified package shortcut. The missing-manifest regression remains a safety check. This change does not remove that gate, guess Android compatibility from filenames, or claim automatic upgrade compatibility. A future direct-download mechanism without a public manifest would need a separately reviewed consumer contract and new builds.

The workflow checks out `inputs.source_sha` and executes that source's `tool/beta_release.py`. Therefore this fix applies only when a future selected source actually contains it. D3's existing tag and built packages are not moved or rewritten, and this maintenance commit must not be described as included in D3. D3 does **not** contain the later Mac 412/session fixes from PR #70, even though this maintenance branch starts after that PR. A successful future maintenance CI run is not new evidence for the frozen D3 binaries.

The default branch's caller workflow must also receive the matching maintenance change before a future dispatch uses this contract. Updating only the caller cannot retrofit `public-files` or the numeric-ID verifier into an older selected source; updating only the selected source leaves an older caller able to upload its former nine-file glob. After the feature enters dev, any authorized master capability backport must transfer only these reviewed CI/tool maintenance hunks onto current master, preserving its current app and release state. It must not merge dev's 1.9 application history into master. This branch does not perform that backport, dispatch, or publication.

## Public assets and retained CI evidence

For `v1.9.x-beta.N`, public Release assets are exactly:

1. `FocuBili-v1.9.x-beta.N-android-preview.apk`
2. `FocuBili-v1.9.x-beta.N-windows-x64-setup.exe`
3. `FocuBili-v1.9.x-beta.N-windows-x64-portable.zip`
4. `FocuBili-v1.9.x-beta.N-macos.dmg`
5. `FocuBili-v1.9.x-beta.N-linux-amd64.deb`
6. `FocuBili-v1.9.x-beta.N-ios-unsigned.ipa`

The candidate CI artifact remains nine files: those six, the Linux `tar.gz`, `beta-release-manifest.json`, and `SHA256SUMS.txt`. Staging, all-platform verification, exact-source push-CI gates, APK signing/identity checks, and candidate checksums stay in place. `public-files` validates the six regular nonempty package files and emits their paths. The publish job reads that list into a quoted Bash array before tag creation; it does not expand `release/*` for public upload. The ordinary stable publisher is unchanged.

The release remains a draft prerelease during upload verification, then a public prerelease with `latest=false`. The stable publisher lock, token permissions, latest-ID/tag check, existing-release refusal, and existing-tag source check are unchanged. Failed partial drafts still require explicit owner inspection; this patch neither resumes nor replaces them automatically.

## Draft verification

The tag lookup endpoint can return 404 for a draft even when its authenticated list entry exists. `verify-upload` now paginates the authenticated release list, requires one exact tag and a positive numeric release ID, then reads `/releases/{id}` with GET. Missing, duplicate, malformed, or changed identities fail; no tag-endpoint fallback or remote mutation is performed by the helper.

The detail must retain that ID/tag, exact planned source SHA, expected draft state, and `prerelease=true`. Its assets must be exactly the six selected packages, with unique positive IDs, state `uploaded`, exact integer byte counts, and server SHA-256 digests matching local files. The same verification runs before and after publication. API errors propagate instead of being treated as absent releases. No credential discovery or secret output was added.

## Local verification

All release metadata, HTTP failures, and binaries used by Python tests are synthetic. The red draft fixture models a tag-endpoint 404 while the exact draft is present on a later list page and is readable by numeric ID. On the original helper this single test fails with `CalledProcessError`; after the fix it passes without calling the tag endpoint.

```text
python -X utf8 -B -m unittest discover -s tool -p test_beta_release.py -k test_draft_is_found -v
# Before production change: 1 test, 1 error (synthetic HTTP 404).
python -X utf8 -B -m unittest discover -s tool -p test_beta_release.py -v
# After: 43 tests passed. The original 33 cases remain; the original upload
# fixture now represents the intentional six-public-package contract.
```

Additional cases cover the unchanged nine-file candidate, six path-safe CLI outputs with spaces, missing/empty/non-file packages, later-page drafts, published releases, missing/duplicate/malformed list results, lookup/detail source and identity changes, draft/prerelease type checks, exact assets/IDs/state/size/hash, API failures, and quoted workflow arguments. These offline tests also run in ordinary CI quality, without network/signing, before a future Beta dispatch.

The companion validation JSON records the actual updater/workflow regression and syntax-check results. No signing, native build, macOS execution, workflow dispatch, release API mutation, actual draft inspection, or real-device upgrade test was performed for this change. Windows-host synthetic success is not macOS or device acceptance.
