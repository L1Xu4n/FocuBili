# Local v1.8 candidate merge into v1.9

This is a local integration of the reviewed **candidate**, not the final v1.8
release baseline. No release, remote update, build or real-device claim is made.

- First parent: `59f6906bd88032ae911315c00d312c96a8079278` (v1.9).
- Second parent: `35a65bf6e5b130f91027308a473c590e36e1ff20` (v1.8 candidate).
- Merge base: `da0946b98994fea9020a58c870b0ddddcde72a42`.
- Independent tree: `v19-v18-candidate-merge`, branch
  `codex/v19-v18-candidate-merge`.
- Method: local fetch from `v18-publication-resume`, then ordinary
  `git merge --no-commit --no-ff <candidate>`, resolving 35 conflicts individually.
  No `ours` merge strategy, squash, rebasing of the publication copy, or history
  replacement was used.

## Result and audit matrix

All production sources, platform code, workflows, helpers, dependencies and
version configuration are **blob-identical to the v1.9 first parent**. Its known
v1.8 fixes already include notification publication guards, macOS stdout probe,
Apple foreground delivery, iOS orientation, search maximum, image capacity
`0..512MiB`, the complete 32-key import schema/rollback, focus and expiry fixes.
There was no automatically merged production change requiring a further port.

The [machine-readable matrix](candidate-35a65bf-merge-matrix.json) records all
**215 paths** differing between the candidate and v1.9 before merging, with each
candidate/first-parent/resolved Git blob, purpose and decision. It also records
all 35 conflict decisions and the unchanged critical candidate file identities.
The matrix covers 4 workflows, 11 Android files, 47 documentation/evidence paths,
82 Dart production files, pubspec, 66 test paths, 3 helpers and work.md. It does
not treat the candidate as final or mark historical progress.json complete.

The normal merge adds these candidate files back to v1.9:

- `docs/notification-delivery-backport.md`.
- `docs/v1.8/apple-delivery-gates.md`.
- `docs/v1.8/home-onboarding-backport.md`.
- `docs/v1.8/publication-stage.md`.
- `test/home_subscription_onboarding_backport_test.dart`, retaining its three
  real onboarding/editing/narrow-screen scenarios with the touch helper adapted
  to the existing v1.9 three-stop drawer contract.

`docs/settings-import-threshold.md` already contains the entire candidate text
as a prefix followed by v1.9 strict-search evidence. `work.md` retains the entire
v1.9 log and the unique candidate publication continuation; every line of the
candidate log remains in order, followed by this merge's evidence.

## Production preservation checks

| Area | Candidate behavior retained together with v1.9 |
| --- | --- |
| CI and version | Current macOS fresh-stdout gate, Apple checks and quality Python steps; controlled Beta workflow_call inputs/existing four signing secrets, exact-SHA artifacts, dry-run default, final publisher lock/no-overwrite/latest=false; numeric 1.9.0+2026 and preview opt-in remain. Ordinary release defaults remain unchanged. |
| Android playback | Latest mainHandler `validateResponse`/`isCurrent` response/session publication guard remains; course purchase/session/DRM/preview protection, per-CID pure export and actual play intent remain. Original UGC HTTP/WBI/codec path remains. |
| Focus/home | Candidate onboarding stops old inertia, resets editing/drag state and replaces the card key. Independent focus and 0/half/full drawer physics remain. Injected test-controller cleanup from 59f remains. |
| Notes | Legacy contain preview and `.38 * viewportHeight`, clamped 108..280, remain with ordered multi-frame/time-point editing/viewing/export. Late save/delete/capture and AB internal-seek/route guards remain byte-identical. |
| Player/buffer | Original gesture/viewport/orientation/recovery/progress/range files match candidate blobs. AB interval state, drain and internal capture, pause/sleep/route fences, Windows latest-intent/account/source/backup-buffer guards remain. |
| Settings | All 32 types/domains and deep Map/List freeze remain. Zero and custom image capacity through 512MiB remain valid; larger values fail before writing. Danmaku finite/domain checks and search 2-billion maximum remain. v1.9 strict keyword parsing remains. |
| Export/storage | Pure capacity/flags/live-cue readers, shared existing-file lock, read-only existing SQLite snapshot, strict raw history/orphan validation and sanitized export remain. Normal writes/TTL/native generations remain. No account credentials, media URLs or request headers are added to export. |
| Profile/search/learning/course | Additive settings export/classroom/blocklist entries, literal filter rules, folder v3/forward fields and purchase/account guards remain; none were replaced by 1.8 lineage. |
| Updates | Reviewed package/channel/manifest-safe Beta consumer remains; candidate manual-check behavior after storage failure remains. |

Existing colleagues performed additional read-only exact-candidate-to-first-parent
comparisons for native/player/update and the nine settings/export/cache/
subscription services. They found no missing candidate fix in those areas and
did not modify or run tests in this tree. The actual combination verification
below was run here.

## Actual verification

The initial same 23-file combination returned **280 passed / 3 failed / 0
skipped**. All failures were the newly restored v1.8 helper expecting full-open
after a slow 120px drag (expected 772/644, actual 0). v1.8 had two stops; v1.9's
reviewed physics has three, and this movement does not cross the nearest-stop
threshold. The old tests' onboarding disappearance, editing-card key reset and
narrow-screen height assertions had already passed before that expectation.

With explicit parent approval, only that test helper and scenario labels were
adapted: two actual fast pointer gestures must stop at half-open and then fully
open. The original three scenarios and their assertions remain; no direct
state mutation, skipped case or production change was used. The original red
log and final green log hashes are recorded in the matrix.

| Check | Actual result |
| --- | --- |
| Offline dependency resolution | `flutter --no-version-check pub get --offline` succeeded. Seven generated plugin registrants were restored; no dependency changes retained. |
| Same 23-file combination after helper adaptation | **283 passed / 0 failed / 0 skipped**, 26 seconds. Exact file list is in matrix `validation.finalFocused.tests`. |
| Four home/onboarding/physics/gesture files | **14 passed / 0 failed / 0 skipped**, 3 seconds; overlaps the combination. |
| `flutter analyze --no-pub` | **No issues**, 16.5 seconds. |
| `dart format --output=none --set-exit-if-changed test/home_subscription_onboarding_backport_test.dart` | 1 file, 0 changed. |
| `python -X utf8 -B -m unittest discover -s tool -p test_beta_release.py -v` | **33 passed**. |
| `python -X utf8 -B -m unittest discover -s tool -p test_native_subscription_probe.py -v` | **16 passed**. |
| `python -X utf8 -B tool/check_apple_sources.py` | Passed. |
| Parsed workflow source, no execution | Four YAML documents; original candidate push/PR triggers preserved; **50 Bash and 4 PowerShell blocks** parsed without execution. |
| Merge/content checks | No unmerged index entries; both-parent normal merge; no production/config delta against first parent; `git diff --check` and staged equivalent clean. |

Flutter executable: `C:\Users\L1XU4N\flutter\bin\flutter.bat`, existing
Flutter 3.44.6/Dart 3.12.2. SDK cache/lock access used the normal authorized tool
execution. No SDK, permission, license or environment repair was made.

The actual focused command was `flutter test --no-pub --reporter expanded`
followed by the 23 paths recorded in the matrix. It covers the restored home
tests; continuous-focus/onboarding/physics; image/domain/strict-search/runtime/
native settings; note mixed-aspect preview and UI; AB capture and nested routes;
Windows buffer and latest-intent ordering; cache locks/course suppression;
Android Beta/CI contract; Beta consumer; and native per-CID export. The separate
home command uses `home_subscription_onboarding_backport_test.dart`,
`focus_home_onboarding_integration_test.dart`, `home_drawer_scroll_physics_test.dart`
and `home_drawer_gesture_test.dart`.

The parent had already run 1571/2skip/0fail on 59f; that is a separate result,
not a full-suite result for this merge. No full suite, native/platform build,
application, account or real-user-data access was run here.

## Remaining baseline and publication constraints

The final v1.8 master/tag SHA M remains pending. Subsequent v1.8 fixes, including
the separately assigned custom-image-capacity dropdown display fix, need their
own normal integration. Merge actual M and run final complete verification
before calling the baseline final.

This historical v1.9 Git graph contains 26 previously rejected image objects.
This local two-parent merge must **never be pushed**. Publication must use a
separately inspected safe snapshot rooted at the actual clean master parent.
No PR, dispatch, tag, push or other remote object was created by this work.
