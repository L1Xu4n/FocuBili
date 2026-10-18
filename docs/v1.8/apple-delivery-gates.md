# Apple subscription delivery gates

PR #63: [foreground guard](https://github.com/L1Xu4n/FocuBili/pull/63#discussion_r4305519038)
and [background focus guard](https://github.com/L1Xu4n/FocuBili/pull/63#discussion_r4305665815).
The combined production source includes `12148a5` and `b3460cd` from the isolated
fix branch, integrated as `b037194` and `f8a3146`.

The UI publishes the actual focus controller state to a process-wide native
gate. Starting focus increments its epoch; ending focus cannot revive an old
request or worker. A headless engine captures its epoch when it registers,
before a delayed Dart notification message can arrive, and cannot overwrite the
UI state. Registration during focus captures no usable epoch.

One native `canDeliver` closure is used at notification entry, after the
asynchronous UserNotifications settings reply, and immediately before
`center.add`, serialized on the main queue.

| State or cancellation | Foreground | iOS headless |
| --- | --- | --- |
| Subscription/notification opt-out | Original request-owned Dart guard and cancellation | Authoritative native configuration/generation/run-token guard |
| Source pause/delete and later restore | Original generation-aware Dart guard | Native invalidation precedes authoritative source transaction; old token/generation cannot revive |
| Focus start, including start then end | Shared epoch plus original Dart guard | Registration-owned epoch plus shared active state |
| Worker created during focus | Not applicable | Missing focus epoch is rejected permanently |
| Delayed show message after focus ends | Request guard remains captured | Registration epoch is retained rather than recaptured at show time |
| Foreground cancel/dispose | One-shot request IDs are removed for their owner | A UI request cannot revoke another engine |
| Native expiration, replacement or cancellation | Existing request ownership retained | Existing scheduler generation/token guard; nil/old tokens rejected |
| Dart local budget expires while settings is pending | Not applicable | Worker-owned native cancellation marker is revoked; default 20s budget cannot wait for the 25s native watchdog |
| Worker dispose/finally | Not applicable | The same sender is disposed; pending native delivery is revoked for its own engine |
| Old engine cancellation arrives after a new run | Other owners remain independent | Cancellation changes only the old plugin instance; a new engine starts uncancelled |
| Notification permission denied | Rejected before submission | Rejected before submission |

Existing scheduler lifecycle, global generation, run-token ownership and
entitlements are unchanged. These guards act before submission and do not claim
to withdraw a notification already submitted to the operating system.

## Observed local evidence

Windows / existing Flutter 3.44.6, synthetic SharedPreferences, real Dart
`runAppleSubscriptionWorker`, `FocuBiliApp` and `FocusTimerController`, and a
controlled MethodChannel host that holds the settings reply:

- Original focus-start and focus-start/end cases returned `true` when `false`
  was expected. The same cases pass after the focus fix.
- A virtual-clock case advances to 24s while the native token is still valid.
  It returned `true` before worker-owned cancellation and is rejected after it.
- `flutter test --no-pub test/apple_background_focus_delivery_test.dart`:
  **8 passed, exit 0**.
- The unchanged prior 109 Apple/notification cases plus background/settings and
  new cases: **133 passed, exit 0** in the isolated fix worktree.
- Full analysis, Dart formatting, source equality checks and whitespace checks
  passed in that worktree. Combined-source results are recorded separately in
  `publication-stage.md`.

`tool/subscription_gate_probe.swift` also exercises epoch capture, nil capture,
one-shot requests, worker cancellation, repeated cancellation and new-engine /
scheduler ownership. This Windows host has no Swift compiler: actual Swift
compilation and execution remain the responsibility of the exact-head Apple CI.
No real UserNotifications delivery or physical-device background acceptance is
claimed by the local protocol tests.
