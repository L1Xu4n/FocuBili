# FocuBili Android channels

This local Flutter plugin registers the existing authentication and subscription
notification channels in every Flutter engine, including the headless engine
created by Workmanager. Do not register the same channels again in MainActivity.

- Authentication keeps using Android WebView's existing application-sandbox cookie
  store. The plugin does not copy cookies to preferences or a database.
- Subscription summaries use application context and the existing notification
  channel, ID, and tap extra. Disabled notifications return false; the plugin
  never requests notification permission or starts a foreground service.
- ActivityAware and NewIntentListener route cold and warm notification taps to the
  existing Dart subscription-updates listener. A tap received before Dart installs
  its listener is retained until consumeTap.
- Detaching one engine only removes that engine's channel handlers. It never
  clears shared cookies or another engine's state.
- Production summary calls include the refresh generation and background flag.
  A short native SQLite transaction checks the latest enabled/notification flags
  and generation, then holds the same lock through posting. Disabling or resetting
  subscriptions cannot race past that check. No transaction survives a Dart await.

Run the platform-independent native tap-state tests from the app's android folder:

    ./gradlew :focubili_android:testDebugUnitTest

Device validation should also cover a Workmanager run after the UI has closed,
notifications denied, a blocked notification channel, cold/warm notification taps,
and opening the app while a background refresh is running. Android force-stop
suspends scheduled work until the user launches the app again.
