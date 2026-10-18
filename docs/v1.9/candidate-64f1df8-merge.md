# Candidate continuation: custom image-cache capacity picker

After [the normal 35a65bf candidate merge](candidate-35a65bf-merge.md), the
parent authorized normal integration of the candidate's new child
`64f1df8d412559794769d16b119b85bfd3a2f231`. This remains a provisional baseline;
the actual v1.8 release/master SHA M is still pending.

First local merge commit:
`d132b648d559b6e7e1b61458cd14a6e7d0632a39`, with exact parents
`59f6906bd88032ae911315c00d312c96a8079278` and
`35a65bf6e5b130f91027308a473c590e36e1ff20`. Its production/configuration matches
59f exactly. The three restored onboarding cases and their real three-stop
touch adaptation are part of that merge, not a separate production fix:

```powershell
git diff 35a65bf6e5b130f91027308a473c590e36e1ff20 d132b648d559b6e7e1b61458cd14a6e7d0632a39 -- test/home_subscription_onboarding_backport_test.dart
```

Only the helper's two slow-drag/full-open assumptions and scenario labels
changed. The helper now performs two actual fast pointer gestures and asserts
half-open followed by full-open. All original onboarding disappearance,
editing-key replacement and narrow-screen height checks remain. The original
280/3 red result, 283/0 final result and complete 215-path/35-conflict matrix are
in the preceding report and its JSON.

## Second normal merge

Fetched the exact 64f1df8 commit from the local publication repository, then ran
`git merge --no-commit --no-ff 64f1df8d412559794769d16b119b85bfd3a2f231` in this
same independent branch. There were **no conflicts**. Its three upstream paths
are retained without modification:

| Path | Decision |
| --- | --- |
| `lib/features/profile/cache_management_page.dart` | Retain exact candidate fix. If the current capacity is not one of the four presets, add that exact value once as a custom item. No clamping, normalization or implicit write when rendering. |
| `test/cache_management_custom_capacity_test.dart` | Retain exact 11 cases: zero/1/128-byte/100MiB custom values, four presets without duplicate items, real temporary-cache selection/remount persistence, and 320px/200%-text menu selection. |
| `docs/settings-picker-presentation-audit.md` | Retain the upstream 32-key presentation audit and original red-to-green evidence. |

The production delta against original v1.9 59f is **only** the above cache page
(22 insertions, 8 deletions). Its resolved blob is
`af7bc15c769505ceff2647950c1e98c7c634af70`, exactly matching 64f1df8; the original
59f/candidate35 blob was `5a2f9d587850e269aa6d0ed0f72f72d42ab33dcc`.
All other production, platform, CI/helper, version/dependency, strict import,
notes and player/AB files remain identical to 59f. Image capacity's legal import
domain remains `0..512MiB`, including byte-sized/custom values.

## Actual final-tree checks

```powershell
flutter test --no-pub --reporter expanded test/cache_management_custom_capacity_test.dart test/home_subscription_onboarding_backport_test.dart test/settings_transfer_image_capacity_test.dart
flutter test --no-pub --reporter expanded test/cache_management_page_test.dart
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib/features/profile/cache_management_page.dart test/cache_management_custom_capacity_test.dart test/home_subscription_onboarding_backport_test.dart
git diff --check
git diff --cached --check
```

- First command: **40 passed / 0 failed / 0 skipped**, 4 seconds (11 custom UI,
  3 onboarding and 26 image-capacity import/runtime rollback/roundtrip cases).
- Existing cache page: **5 passed / 0 failed / 0 skipped**, 1 second; covers use,
  selection, clearing, active-playback restrictions and Windows buffer display.
- Final full static analysis: **no issues**, 8.9 seconds.
- Formatter: **3 files, 0 changes**. Whitespace checks pass.
- Both parents and source blob identities are checked before and after commit.
  Root v1.9 was still clean at exact 59f during the final read-only check.

All Flutter commands used the installed Windows Flutter BAT through authorized
normal SDK-cache/lock access. No environment/permission/SDK/license changes,
native builds, application execution, account access or remote writes were
performed. Temporary-cache fixtures create their own synthetic directory only.
The first merge's separate 283-test combination and 49 Python tests remain
recorded accurately; no full-suite result is claimed for this continuation.

The historical v1.9 graph must remain local because of previously rejected
image objects. Root can fast-forward this local branch, then merge actual M and
complete full verification; any later publication still requires a separately
audited safe snapshot with actual clean master as parent. Neither candidate35
nor candidate64 is represented as the final released baseline.
