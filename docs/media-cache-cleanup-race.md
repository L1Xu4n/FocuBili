# Inactive desktop cache cleanup race

Base: `64f1df8d412559794769d16b119b85bfd3a2f231`.

## Observed failure and boundary

The first macOS launch probe in run `39098956796`, job `117591094685`,
checked out PR merge `86be58110fdf2e1dafce01dc8b9a391152f660ac` (head above).
Its disk-cache measurements succeeded, then `releaseAfterPlayerClosed` failed
in `_cleanInactive` at the old line 347 with `PathNotFoundException`, errno 2.
The first process exited 1. The later LLDB process exiting 0 is diagnostic
evidence only, and does not turn the first result into a pass. Raw log:
`task-5/output/v18-64f-macos-job-log.download`.

`WindowsMediaCacheService._mutations` is already static, so multiple instances
in one isolate share serialization. Other isolates/processes use `sessions.lock`
and each live session's `owner.lock`. This change does not weaken or reorder
those locks. There is no demonstrated lock failure in the CI log.

The macOS Dart SDK recursive-delete implementation can report the root argument
when an enumerated child's `unlink` returns ENOENT. The error therefore does not
prove the session root itself had disappeared. mpv's cache destruction closes
and unlinks its packet file, not the session directory. A deterministic temporary
filesystem fixture reproduces this root-path error while asserting the parent
still exists. The CI run has no syscall trace proving which actor removed that
particular child.

Pinned `media_kit` 1.2.6's public `dispose` awaits `stop`, but schedules native
`mpv_terminate_destroy` five seconds later. Its returned Future is not a native
termination barrier. No dependency, native FFI, player lifecycle, artificial
delay, observer, or probe assertion is changed here. Successful public disposal
remains the existing lease-release boundary; comments now acknowledge that
native cleanup can overlap filesystem cleanup. Failed public disposal still
retains the lease through the existing path. This patch does not claim all native
handles are closed when the public Future completes.

Source references used to understand the failure:

- [mpv 0.36 packet cache](https://github.com/mpv-player/mpv/blob/v0.36.0/demux/cache.c)
- [Dart 3.12.2 macOS recursive deletion](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/directory_macos.cc)
- [Dart 3.12.2 directory error forwarding](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/directory.cc)
- Local pinned package: `media_kit-1.2.6/lib/src/player/native/player/real.dart`,
  `dispose` lines 89–108.

## Minimal change

Both inactive `session_*` cleanup and idle legacy cleanup now delete one node
at a time. Each lookup and directory enumeration uses `followLinks: false`;
links/junctions themselves are removed. A directory is deleted non-recursively
after its children, so a surviving or newly created child causes a visible
failure rather than a successful partial cleanup. Every node's disappearance,
including the parent directory, is checked after deletion.

A failed deletion is ignored only for errno 2 (all platforms), or error 3 on
Windows, with that same node now absent according to a no-follow lookup.
Unix error 3, missing `osError`, permission/I/O failures, and ENOENT while the
node still exists propagate. There is no retry. Since Dart's `typeSync` also
returns `notFound` on lookup errors, it cannot by itself authorize skipping a
node: the non-recursive deletion must still provide the actual OS result.

The existing `sessions.lock`, unique session namespace, live-owner checks,
playback checks, root-path validation, and final probe assertion that the closed
session has actually disappeared remain intact.

## Verification

Host: Windows, Flutter 3.44.6 / Dart 3.12.2. All fixtures use newly created
temporary directories, synthetic packet bytes and mock preferences. No real
account, application cache, signing key or remote state was accessed.

Before changing production source, the initial eight-case version of
`media_cache_cleanup_race_test.dart` against exact base produced **3 passes and
5 failures, exit 1**:

- session and legacy child disappearance while the parent remained: failed at
  the old recursive delete with root-path errno 2;
- session and legacy directory disappearance after enumeration: failed;
- nested legacy child disappearance: failed;
- surviving-node OS errors 2/5/13: already propagated, and remain covered.

The expanded fixture additionally checks unrelated errors after a node has
disappeared, error-3 platform semantics, failed no-follow type lookup, and link
target preservation. On Windows the latter creates a real temporary-directory
junction without administrator/developer-mode changes; on Unix it uses a symlink.

`media_cache_process_lock_test.dart` starts **three actual Dart VM processes**
with real OS lifetime locks. Maintenance preserves every live packet and the
legacy file, while reclaiming an orphan. Normal lock release and process exit
each permit only that session's reclamation. The legacy file is removed only
after the last owner releases its lock. This is real Windows process/filesystem
coverage, not simulated native macOS execution.

Commands (the locally installed cached Flutter entry point is used to avoid
refreshing the SDK; `FLUTTER_ROOT` and `CI=true` are set for that invocation):

```powershell
& C:/Users/L1XU4N/flutter/bin/cache/dart-sdk/bin/dart.exe `
  C:/Users/L1XU4N/flutter/bin/cache/flutter_tools.snapshot --no-version-check `
  test --no-pub test/media_cache_cleanup_race_test.dart `
  test/media_cache_process_lock_test.dart test/windows_media_cache_service_test.dart `
  test/desktop_disk_cache_session_test.dart test/cache_file_lock_test.dart `
  test/windows_playback_audio_lifecycle_test.dart test/cache_review_probe_test.dart `
  test/cache_management_custom_capacity_test.dart --reporter expanded

dart analyze lib/services/media_cache_service.dart lib/services/desktop_disk_cache_session.dart `
  test/media_cache_cleanup_race_test.dart test/media_cache_process_lock_test.dart `
  test/fixtures/media_cache_lock_peer.dart

dart format --output=none --set-exit-if-changed lib/services/media_cache_service.dart `
  lib/services/desktop_disk_cache_session.dart test/media_cache_cleanup_race_test.dart `
  test/media_cache_process_lock_test.dart test/fixtures/media_cache_lock_peer.dart

git diff --check
```

Final results: the eight-file targeted command passed **55 tests**, with **one
skip** (the existing Windows root-symlink creation test requires developer mode),
exit 0. Both new test files passed all **15 tests**, including the actual
Windows junction and three-process cases. Five-file analysis reported **No
issues found**. Final format checking reported **5 files, 0 changed**;
`git diff --check` passed. No full-suite or native build was run locally.

Actual macOS native launch/probe execution, Unix error-3 behavior and POSIX
flock execution remain for actual platform CI. The current first-run smoke-test
and closed-session-reclaimed assertion must pass there without retries or a
replacement LLDB success.
