# Search threshold settings import validation

Base: `2ca0b6e38b722c88ff8611717ce1f58eb8f8c3ed`.
Isolated branch: `codex/v18-import-threshold`.

PR 63 review identified that settings import accepted `minimumPlayCount` above
`SearchContentFilter.maximumPlayCount` (2,000,000,000), while the search filter
loader rejected the saved value and returned the default filter. Import could
therefore report success while losing the requested filter on the next load.

The settings validator now uses the same model maximum as the existing filter
loader and saver. Both settings-file parsing and direct import use this validator
before writes. Values are rejected rather than clamped. The filter model,
load/save guards, runtime adapter and 1.8 settings schema are unchanged.

## Automated evidence

Executed on Windows with the existing Flutter SDK, synthetic SharedPreferences
and a synthetic runtime adapter. No real account, settings or device data was
read. Publication/integration worktrees and remote refs were not modified.

Before changing production code:

```powershell
flutter test --no-pub --reporter expanded test/settings_transfer_search_threshold_test.dart
```

Result: **12 passed, 2 failed; exit 1**. The two failures proved that parsing and
direct import incorrectly accepted 2,000,000,001.

After the minimal validator fix:

```powershell
flutter test --no-pub --reporter expanded test/settings_transfer_search_threshold_test.dart test/settings_transfer_test.dart test/search_content_filter_test.dart
```

Result: **25 passed; exit 0**, including all 14 new boundary cases. Zero and the
model maximum load back exactly with `learningOnly: false`, proving the loader
did not fall back to defaults. Maximum plus one, negative, double, string, bool
and null thresholds are rejected by both parse and direct import. Invalid input
also contains preceding valid ordinary and runtime updates; tests compare the
entire original synthetic preferences/runtime maps and require zero preferences
loader/runtime read/runtime write calls.

```powershell
flutter analyze --no-pub lib/services/settings_transfer_service.dart lib/models/search_content_filter.dart lib/services/search_content_filter_service.dart test/settings_transfer_search_threshold_test.dart test/settings_transfer_test.dart test/search_content_filter_test.dart
dart format --output=none --set-exit-if-changed lib/services/settings_transfer_service.dart test/settings_transfer_search_threshold_test.dart
git diff --check
```

Result: scoped analysis **no issues, exit 0**; formatting **2 files, 0 changes,
exit 0**; whitespace check **exit 0**.

This is a local 1.8 fix for the release owner to integrate. No full suite,
application build, real-device test, push, PR comment or publication was performed.
