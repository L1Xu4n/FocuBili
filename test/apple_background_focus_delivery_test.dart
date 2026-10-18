import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/app.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/focus_session_service.dart';
import 'package:focubili/services/subscription_background_service.dart';
import 'package:focubili/services/subscription_notification_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SendingWorker extends SubscriptionService {
  bool? notified;
  int cancelled = 0;
  String? interruption;
  @override
  int get notificationGeneration => 17;
  @override
  Future<void> runBackgroundCheck(
    int generation, {
    Duration budget = const Duration(minutes: 8),
  }) async {
    notified = await notifyItems!([
      SubscriptionFeedItem(
        bvid: 'synthetic-update',
        title: 'Synthetic update',
        coverUrl: '',
        sources: const {'creator:1': 'Synthetic source'},
        discoveredAt: DateTime.utc(2026),
      ),
    ]);
  }

  @override
  void cancelBackgroundCheck() {
    cancelled++;
    super.cancelBackgroundCheck();
  }

  @override
  Future<void> recordBackgroundInterruption(String status) async {
    interruption = status;
  }
}

class _HeldNotifications extends SubscriptionNotificationService {
  _HeldNotifications(MethodChannel channel)
    : super(channel: channel, platform: AppPlatform.ios);
  final called = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<bool> showItems(
    List<SubscriptionFeedItem> items, {
    int? generation,
    bool background = false,
  }) async {
    called.complete();
    await resume.future;
    return super.showItems(
      items,
      generation: generation,
      background: background,
    );
  }
}

class _WorkerEngine {
  _WorkerEngine(int index, this.token, this.focusEpoch)
    : notifications = MethodChannel('test/focus/notifications-$index'),
      protocol = MethodChannel('test/focus/worker-$index');
  final MethodChannel notifications;
  final MethodChannel protocol;
  final String token;
  final int? focusEpoch;
  final settings = Completer<void>();
  final entered = Completer<void>();
  bool cancelled = false;
}

/// Models the native engine boundary, not UserNotifications itself. The real
/// worker and app run in Dart; the Foundation-only Swift probe covers the gate.
class _NativeHost {
  _NativeHost() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ui, _foreground);
    _registerEngine('run-one');
    addTearDown(() {
      messenger.setMockMethodCallHandler(ui, null);
      for (final engine in engines) {
        messenger.setMockMethodCallHandler(engine.notifications, null);
        messenger.setMockMethodCallHandler(engine.protocol, null);
      }
    });
  }
  final ui = const MethodChannel('test/focus/ui-notifications');
  final engines = <_WorkerEngine>[];
  _WorkerEngine get engine => engines.last;
  MethodChannel get worker => engine.notifications;
  MethodChannel get protocol => engine.protocol;
  Completer<void> get settings => engine.settings;
  Completer<void> get entered => engine.entered;
  final completions = <Map<Object?, Object?>>[];
  final focusUpdates = <bool>[];
  bool focusActive = false;
  int focusEpoch = 0;
  String? runToken;
  final shown = <String>[];
  int rejectedWorkerFocusWrites = 0;

  void _registerEngine(String token) {
    // Both run identity and focus epoch belong to this engine registration.
    final engine = _WorkerEngine(
      engines.length,
      token,
      focusActive ? null : focusEpoch,
    );
    engines.add(engine);
    runToken = token;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      engine.notifications,
      (call) => _worker(call, engine),
    );
    messenger.setMockMethodCallHandler(engine.protocol, (call) async {
      if (call.method == 'ready') {
        return {
          'runId': engine.token,
          'generation': 17,
          'budgetMilliseconds': 20000,
        };
      }
      if (call.method == 'complete') {
        completions.add(Map.of(call.arguments as Map));
        return true;
      }
      throw MissingPluginException();
    });
  }

  void registerNextRun() => _registerEngine('run-two');

  Future<Object?> _foreground(MethodCall call) async {
    if (call.method == 'consumeTap' || call.method == 'cancelSummary') {
      return null;
    }
    if (call.method == 'cancelWorkerSummary') return false;
    if (call.method == 'setFocusActive') {
      final active = (call.arguments as Map)['active'] as bool;
      focusUpdates.add(active);
      if (active && !focusActive) focusEpoch++;
      focusActive = active;
      return null;
    }
    throw MissingPluginException();
  }

  bool permits(int? epoch) =>
      !focusActive && epoch != null && epoch == focusEpoch;

  Future<Object?> _worker(MethodCall call, _WorkerEngine engine) async {
    if (call.method == 'setFocusActive') {
      rejectedWorkerFocusWrites++;
      return false;
    }
    if (call.method == 'cancelWorkerSummary') {
      engine.cancelled = true;
      return null;
    }
    if (call.method != 'showSummary') throw MissingPluginException();
    final args = call.arguments as Map;
    expect(args['background'], true);
    expect(args['generation'], 17);
    expect(args.containsKey('requestId'), false);
    final epoch = engine.focusEpoch;
    if (!engine.entered.isCompleted) engine.entered.complete();
    if (engine.cancelled || !permits(epoch)) return false;
    await engine.settings.future;
    if (engine.cancelled || runToken != engine.token || !permits(epoch)) {
      return false;
    }
    shown.add(args['title'] as String);
    return true;
  }
}

Future<void> _expire(MethodChannel channel) {
  final reply = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('expire'),
        ),
        (_) => reply.complete(),
      );
  return reply.future;
}

Future<FocusTimerController> _mountApp(
  WidgetTester tester,
  _NativeHost host,
) async {
  SharedPreferences.setMockInitialValues({});
  final focus = FocusTimerController();
  await focus.initialize();
  final subscriptions = SubscriptionService();
  final foreground = SubscriptionNotificationService(
    channel: host.ui,
    platform: AppPlatform.ios,
  );
  addTearDown(focus.dispose);
  addTearDown(subscriptions.dispose);
  await tester.pumpWidget(
    FocuBiliApp(
      focusTimerController: focus,
      subscriptionService: subscriptions,
      subscriptionNotificationService: foreground,
    ),
  );
  return focus;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['start', 'start/end', 'none']) {
    testWidgets('headless pending settings respects focus $change', (
      tester,
    ) async {
      final host = _NativeHost();
      final focus = await _mountApp(tester, host);
      final headless = SubscriptionNotificationService(
        channel: host.worker,
        platform: AppPlatform.ios,
      );
      addTearDown(headless.dispose);
      final worker = _SendingWorker();
      final run = runAppleSubscriptionWorker(
        channel: host.protocol,
        createService: () => worker,
        notifications: headless,
      );
      await host.entered.future;
      // Reaching the native settings boundary proves the production worker's
      // prefs.reload()/FocusSessionService guard passed with no active focus.
      expect(focus.hasActiveSession, false);
      if (change != 'none') {
        expect(
          await focus.startFocus(
            goal: 'Synthetic focus',
            duration: const Duration(minutes: 5),
          ),
          true,
        );
        expect(
          (await FocusSessionService().loadState()).activeSession?.isActive,
          true,
        );
        if (change == 'start/end') {
          await focus.endFocusEarly(reason: 'Synthetic end');
        }
        if (change == 'start') {
          headless.updateFocusState(false);
          await tester.pump();
          expect(
            host.focusActive,
            true,
            reason: 'A stale headless snapshot cannot clear UI focus',
          );
          expect(host.rejectedWorkerFocusWrites, 1);
        }
      }
      host.settings.complete();
      await run;
      expect(worker.notified, change == 'none');
      expect(host.shown, change == 'none' ? ['Synthetic update'] : isEmpty);
      expect(
        host.runToken,
        'run-one',
        reason: 'Focus must not expire or replace the scheduler run',
      );
      expect(host.completions, [
        {'runId': 'run-one', 'success': true},
      ]);
      if (change != 'none') expect(host.focusUpdates, contains(true));
      if (change == 'start/end') {
        expect(host.focusActive, false);
        host.registerNextRun();
        host.settings.complete();
        final fresh = _SendingWorker();
        await runAppleSubscriptionWorker(
          channel: host.protocol,
          createService: () => fresh,
          notifications: SubscriptionNotificationService(
            channel: host.worker,
            platform: AppPlatform.ios,
          ),
        );
        expect(
          fresh.notified,
          true,
          reason: 'Focus must not disable future background runs',
        );
        expect(host.completions.last, {'runId': 'run-two', 'success': true});
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'worker show queued before focus stays revoked after focus ends',
    (tester) async {
      final host = _NativeHost();
      final focus = await _mountApp(tester, host);
      final headless = _HeldNotifications(host.worker);
      addTearDown(headless.dispose);
      final worker = _SendingWorker();
      final run = runAppleSubscriptionWorker(
        channel: host.protocol,
        createService: () => worker,
        notifications: headless,
      );
      await headless.called.future;
      expect(
        await focus.startFocus(
          goal: 'Synthetic focus',
          duration: const Duration(minutes: 5),
        ),
        true,
      );
      await focus.endFocusEarly(reason: 'Synthetic end');
      expect(host.focusActive, false);
      headless.resume.complete();
      await run;
      expect(worker.notified, false);
      expect(host.settings.isCompleted, false);
      expect(host.shown, isEmpty);
      expect(host.runToken, 'run-one');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final cancellation in ['deadline', 'native expire', 'dispose']) {
    testWidgets(
      'headless pending settings respects cancellation $cancellation',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final host = _NativeHost();
        final oldEngine = host.engine;
        final headless = SubscriptionNotificationService(
          channel: host.worker,
          platform: AppPlatform.ios,
        );
        addTearDown(headless.dispose);
        final worker = _SendingWorker();
        final run = runAppleSubscriptionWorker(
          channel: host.protocol,
          createService: () => worker,
          notifications: headless,
        );
        await host.entered.future;
        switch (cancellation) {
          case 'deadline':
            // Fake time reaches the Dart 20s deadline, inside the native 25s
            // watchdog grace period. The native run still owns its token.
            await tester.pump(const Duration(seconds: 24));
          case 'native expire':
            await _expire(host.protocol);
          case 'dispose':
            headless.dispose();
        }
        expect(host.runToken, 'run-one');
        host.settings.complete();
        await run;
        expect(worker.notified, false);
        expect(host.shown, isEmpty);
        expect(oldEngine.cancelled, true);
        expect(host.completions, [
          {'runId': 'run-one', 'success': cancellation == 'dispose'},
        ]);
        if (cancellation != 'dispose') {
          expect(worker.cancelled, 1);
          expect(worker.interruption, isNotNull);
        }

        host.registerNextRun();
        final fresh = _SendingWorker();
        final next = runAppleSubscriptionWorker(
          channel: host.protocol,
          createService: () => fresh,
          notifications: SubscriptionNotificationService(
            channel: host.worker,
            platform: AppPlatform.ios,
          ),
        );
        await host.entered.future;
        // A delayed old-engine cancel and a UI call cannot revoke the new
        // engine's notification, even though its system settings are pending.
        await oldEngine.notifications.invokeMethod<void>('cancelWorkerSummary');
        expect(await host.ui.invokeMethod<bool>('cancelWorkerSummary'), false);
        expect(host.engine.cancelled, false);
        host.settings.complete();
        await next;
        expect(fresh.notified, true);
        expect(host.completions.last, {'runId': 'run-two', 'success': true});
      },
    );
  }

  testWidgets('worker finally disposes its notification sender', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = _NativeHost();
    host.settings.complete();
    final headless = SubscriptionNotificationService(
      channel: host.worker,
      platform: AppPlatform.ios,
    );
    addTearDown(headless.dispose);
    final worker = _SendingWorker();
    await runAppleSubscriptionWorker(
      channel: host.protocol,
      createService: () => worker,
      notifications: headless,
    );
    expect(worker.notified, true);
    expect(
      await headless.showSummary(1, generation: 17, background: true),
      false,
      reason: 'A completed worker must not start another native preparation',
    );
    expect(host.shown, hasLength(1));
  });
}
