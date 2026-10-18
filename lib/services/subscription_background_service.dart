import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../platform/app_platform.dart';
import 'focus_session_service.dart';
import 'subscription_notification_service.dart';
import 'subscription_service.dart';

/// Headless iOS entry point: no runApp, player, clipboard monitor or focus timer.
@pragma('vm:entry-point')
Future<void> subscriptionAppleBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runAppleSubscriptionWorker(
    channel: const MethodChannel('com.focubili.app/subscription_worker'),
    createService: () => SubscriptionService(
      backgroundScheduler: (_, _) async {},
      requestTimeout: const Duration(seconds: 10),
      pageBudget: 2,
    ),
  );
}

/// The bounded worker protocol is independently testable with a synthetic store.
/// This invocation owns and disposes its notification sender, including injections.
Future<void> runAppleSubscriptionWorker({
  required MethodChannel channel,
  required SubscriptionService Function() createService,
  SubscriptionNotificationService? notifications,
}) async {
  SubscriptionService? service;
  final workerNotifications =
      notifications ?? SubscriptionNotificationService();
  Timer? deadline;
  String? token;
  var expired = false;
  var success = false;
  channel.setMethodCallHandler((call) async {
    if (call.method == 'expire' && !expired) {
      expired = true;
      workerNotifications.cancelPending();
      service?.cancelBackgroundCheck();
    }
  });
  try {
    final request = await channel.invokeMapMethod<String, Object?>('ready');
    if (request == null ||
        request['runId'] is! String ||
        request['generation'] is! int) {
      return;
    }
    token = request['runId'] as String;
    final generation = request['generation'] as int;
    if (expired || generation < 0) return;
    final budget = Duration(
      milliseconds: (request['budgetMilliseconds'] as int? ?? 20000).clamp(
        1000,
        20000,
      ),
    );
    final worker = createService();
    service = worker;
    worker.notifyItems = (items) async {
      if (expired) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final focus = await FocusSessionService(
        preferencesLoader: () async => prefs,
      ).loadState();
      if (expired || focus.activeSession?.isActive == true) return false;
      return workerNotifications.showItems(
        items,
        generation: worker.notificationGeneration,
        background: true,
      );
    };
    deadline = Timer(budget, () {
      expired = true;
      workerNotifications.cancelPending();
      worker.cancelBackgroundCheck();
    });
    await worker.runBackgroundCheck(generation, budget: budget);
    if (expired) {
      await worker.recordBackgroundInterruption('iOS 本轮后台时间已到，剩余内容前台或下次继续');
    }
    success = !expired && worker.storageError == null;
  } catch (_) {
    // Native status reports failure. No credentials or exception contents logged.
  } finally {
    deadline?.cancel();
    workerNotifications.dispose();
    service?.dispose();
    channel.setMethodCallHandler(null);
    if (token != null) {
      try {
        await channel.invokeMethod<bool>('complete', {
          'runId': token,
          'success': success,
        });
      } catch (_) {
        /* Native expiration already owns completion. */
      }
    }
  }
}

/// Android may delay this work for Doze, battery policy, or offline constraints.
/// Force-stop is respected; there is no foreground service or remote push server.
@pragma('vm:entry-point')
void subscriptionCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    // Workmanager creates an auto-registered Android Flutter engine.
    if (task != SubscriptionBackgroundScheduler.taskName) return true;
    final generation = inputData?['generation'];
    if (generation is! int) return true;
    final service = SubscriptionService();
    final notifications = SubscriptionNotificationService();
    service.notifySummary = (count) async {
      // Read only. A headless engine must never finish/rewrite a focus session.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final focus = await FocusSessionService(
        preferencesLoader: () async => prefs,
      ).loadState();
      if (focus.activeSession?.isActive == true) return false;
      return notifications.showSummary(
        count,
        generation: service.notificationGeneration,
        background: true,
      );
    };
    service.notifyItems = (items) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final focus = await FocusSessionService(
        preferencesLoader: () async => prefs,
      ).loadState();
      if (focus.activeSession?.isActive == true) return false;
      return notifications.showItems(
        items,
        generation: service.notificationGeneration,
        background: true,
      );
    };
    try {
      await service.runBackgroundCheck(generation);
      return service.storageError == null;
    } catch (_) {
      // No exception bodies/cookies/URLs are logged. WorkManager may retry;
      // persistent checkpoints and notification claims make retries safe.
      return false;
    } finally {
      service.dispose();
    }
  });
}

abstract final class SubscriptionBackgroundScheduler {
  static const taskName = 'focubili.subscription.check';
  static const uniqueName = 'focubili.subscription.hourly.v2';
  static Future<void>? _initializing;
  static Future<void> _queue = Future.value();

  static Future<void> initialize() async {
    if (AppPlatformDetector.current != AppPlatform.android ||
        AppPlatformDetector.isFlutterTest) {
      return;
    }
    final pending = _initializing ??= Workmanager().initialize(
      subscriptionCallbackDispatcher,
    );
    try {
      await pending;
    } catch (_) {
      if (identical(_initializing, pending)) _initializing = null;
      rethrow;
    }
  }

  static Future<void> configure(bool enabled, int generation) {
    final result = _queue.then((_) async {
      await initialize();
      if (!enabled) {
        await Workmanager().cancelByUniqueName(uniqueName);
        return;
      }
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: const Duration(hours: 1),
        initialDelay: const Duration(hours: 1),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(networkType: NetworkType.connected),
        inputData: {'generation': generation},
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 15),
      );
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
