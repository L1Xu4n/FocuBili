# Android subscription background checks (beta 2)

## Contract

- Off by default; explicit setting is independent of local notification opt-in.
- WorkManager requests a unique hourly periodic job, requiring connected networking. Android controls actual execution time. Doze, battery restrictions, network loss and OEM policies may delay it. Force-stop is respected until the user opens the app again.
- No remote push/cloud service, foreground-service notification, real-time promise or force-stop bypass.
- Existing public content APIs and the existing sandboxed Android WebView session are reused. Cookies are never copied into the subscription database or logs. Anonymous UP submission risk control remains unresolved: a response blocked by Bilibili is shown as a source failure with backoff, not reported as a successful empty feed.
- A headless run uses at most two requests concurrently, three pages per source and an eight-minute budget. A durable cursor rotates sources between bounded runs. An initial baseline stores checkpoints without importing/notifying historical items. Large collections may need several checks to complete their initial baseline.
- New items remain in the unread list even when notification permission/channel is blocked. A durable notification claim is saved before dispatch. This deliberately favors at-most-once hints: process death, permission denial, active focus suppression or a dispatch failure can omit a system hint, never erase unread items.

## Storage and cancellation

Android migrates the existing `focubili_subscriptions_v1` snapshot into a device-local SQLite database, without deleting the legacy primary/backup or touching learning/focus data. All foreground and headless writers reload the latest snapshot, apply their in-memory mutation, and commit it with one atomic SQLite compare-and-swap statement. A contending writer retries against the new snapshot. Neither network requests nor Dart callbacks hold a database transaction, preventing abandoned locks when Android destroys a worker engine. Each engine uses an independent database handle. A detached source scan may commit only if its generation, source token, paused state and original checkpoint still match; feed merges retain existing read timestamps. Disabling, pausing, deleting or adding a source invalidates prior scheduled generations.

Primary and previous-valid snapshots are saved atomically by the same SQL statement. A malformed primary can recover only from the validated SQLite previous snapshot, while preserving the corrupt bytes in quarantine. If both fail validation, writes fail closed. A disk/commit failure rolls the in-memory state back. The old SharedPreferences snapshot is never silently substituted for an authoritative SQLite database.

Periodic-job reconciliation runs on startup and relevant setting/source changes. A scheduling failure is shown as a status message; reopen or toggle to retry. SQLite and Android's scheduler cannot commit atomically, so interruption between preference commit and scheduling is repaired on the next app launch. After the claim is committed, native notification dispatch validates enabled/notification/background flags and the generation inside a short native SQLite transaction, then posts before releasing it. This serializes dispatch with configuration writes without a Dart-held lock.

## Automated checks

- `flutter test test/subscription_service_test.dart test/subscription_background_test.dart test/app_subscription_lifecycle_test.dart`
- `cd android && ./gradlew :focubili_android:testDebugUnitTest`
- On an Android device/emulator: `flutter test integration_test/subscription_snapshot_store_test.dart -d DEVICE`

The Dart protocol tests use a serialized atomic-store test double for repeatability. The Android integration test uses real sqflite storage and a distinct test database, covering concurrent compare-and-swap connections, failed-mutation rollback and reopening. Native tests cover cold/warm tap consumption. None of those alone verifies process death or OEM scheduling behavior.

## Device acceptance checklist (must be recorded as run or not run)

Use a dedicated test install/session and controlled subscription source. Avoid secrets in logs/screenshots.

1. Fresh install: background and notifications are off. Enable subscriptions and complete a baseline; verify historical items do not notify. Add up to 50 sources; the 51st is rejected.
2. Enable background checks; inspect the app's WorkManager/JobScheduler entry and connected-network constraint. Add a genuinely new item after baseline. Trigger the scheduled job with Android development tools or wait for system execution. Verify one summary and the unread item, then reopen and verify last-check/status.
3. Swipe the app away / kill its process without force-stop. Allow the scheduled job to run. Verify session access, storage, summary and notification tap cold-launch into subscription updates. Repeat warm-tap navigation.
4. Deny Android notification permission and separately disable the subscription channel. Run with a new item. Verify no crash, unread remains, no repeated notification after permission restoration.
5. Disable background while a network request is in flight. Verify stale response does not write or notify. Repeat with pause, delete/re-add of the same source, and foreground mark-read. Re-enable and verify a new generation can run.
6. Disconnect networking and enter Doze. Verify no real-time promise and no bypass. Restore networking/exit Doze, then verify eventual eligible execution. Force-stop the app and verify it does not work around the stop; manually reopen to reconcile.
7. Kill during a scan/transaction boundary; reopen and verify valid data, pending pagination and notification deduplication. Simulate full/unwritable storage in a dedicated test environment and verify failed saves retain prior data.
8. Run an active focus session while a new item is found. Verify unread updates without a subscription summary interrupting focus. Do not infer exact OS timing from emulator success.

## Upstream references

- Flutter Workmanager quick start: https://docs.page/fluttercommunity/flutter_workmanager/quickstart
- Current periodic-task API: https://pub.dev/documentation/workmanager/latest/workmanager/Workmanager/registerPeriodicTask.html
- sqflite transactions: https://pub.dev/packages/sqflite
