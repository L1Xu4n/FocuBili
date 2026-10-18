# Native subscription probe report transport

PR #63 macOS job `117571210903` reached the native subscription timer probe,
then failed to write `build/apple/native-subscription.json`. Its diagnostic log
contains an unhandled `PathAccessException` with `Operation not permitted` in the
probe's final report write. The process consequently did not reach its result
marker and exit, and the host's 30-second limit expired. This failure does not
establish that the preceding timer assertions passed.

The macOS probe now retains the application's sandbox and emits its structured
result only on stdout. The host runner truncates the current log, removes any
old result, and supplies a random per-launch request ID. It requires a clean
process exit, exactly one JSON result, the matching request ID and platform,
`success: true`, and all three existing timer checks before writing the CI JSON.
Missing, malformed, duplicate, stale, failed or timed-out results fail the step.
The log remains available on failure. Windows and Linux retain their file
transport, with the same per-launch identity check. iOS's document-container
report and compile-time run ID are unchanged.

The timer callback, generation replacement and cancellation checks are unchanged.
No product entitlements, native scheduling implementation, release package,
workflow dependencies or time limits are changed. Apple quality runs the new
driver regressions on every workflow event.

Validation on a Windows host:

```text
python -X utf8 -B -m unittest discover -s tool -p test_native_subscription_probe.py -v
python -X utf8 -B -m unittest discover -s tool -p test_verify_macos_dmg.py -v
python tool/check_apple_sources.py
python tool/check_platform_icons.py
dart format --output=none --set-exit-if-changed tool/native_subscription_probe.dart
dart analyze tool/native_subscription_probe.dart
git diff --check
```

The 16 new driver tests and 3 existing packaging driver tests pass; source/icon
checks, Dart formatting, analysis and whitespace checks also pass. UTF-8 mode is
explicit above because the existing packaging validator reads the UTF-8 pubspec
using the Windows process's default encoding; Ubuntu/macOS CI already use UTF-8.

The new driver tests use real synthetic Python child processes and temporary
directories. They do not execute a macOS application or its native timer. A new
macOS CI run must still verify the sandboxed Flutter probe, all timer assertions,
normal exit, and the generated `native-subscription.json`.
