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

/// Models the native engine boundary, not UserNotifications itself. The real
/// worker and app run in Dart; the Foundation-only Swift probe covers the gate.
class _NativeHost {
  _NativeHost() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ui, _foreground);
    messenger.setMockMethodCallHandler(worker, _worker);
    messenger.setMockMethodCallHandler(protocol, (call) async {
      if (call.method == 'ready') {
        return {
          'runId': registeredToken,
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
    addTearDown(() {
      messenger.setMockMethodCallHandler(ui, null);
      messenger.setMockMethodCallHandler(worker, null);
      messenger.setMockMethodCallHandler(protocol, null);
    });
  }
  final ui = const MethodChannel('test/focus/ui-notifications');
  final worker = const MethodChannel('test/focus/worker-notifications');
  final protocol = const MethodChannel('test/focus/worker');
  final settings = Completer<void>();
  final entered = Completer<void>();
  final completions = <Map<Object?, Object?>>[];
  final focusUpdates = <bool>[];
  bool focusActive = false;
  int focusEpoch = 0;
  // Captured when the headless engine registers, before its Dart ready call.
  int? workerFocusEpoch = 0;
  String? runToken = 'run-one';
  String registeredToken = 'run-one';
  final shown = <String>[];
  int rejectedWorkerFocusWrites = 0;

  void registerNextRun() {
    runToken = registeredToken = 'run-two';
    workerFocusEpoch = focusActive ? null : focusEpoch;
  }

  Future<Object?> _foreground(MethodCall call) async {
    if (call.method == 'consumeTap' || call.method == 'cancelSummary') {
      return null;
    }
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

  Future<Object?> _worker(MethodCall call) async {
    if (call.method == 'setFocusActive') {
      rejectedWorkerFocusWrites++;
      return false;
    }
    if (call.method != 'showSummary') throw MissingPluginException();
    final args = call.arguments as Map;
    expect(args['background'], true);
    expect(args['generation'], 17);
    expect(args.containsKey('requestId'), false);
    final epoch = workerFocusEpoch;
    final token = registeredToken;
    if (!entered.isCompleted) entered.complete();
    if (!permits(epoch)) return false;
    await settings.future;
    if (runToken != token || !permits(epoch)) return false;
    shown.add(args['title'] as String);
    return true;
  }
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
        final fresh = _SendingWorker();
        await runAppleSubscriptionWorker(
          channel: host.protocol,
          createService: () => fresh,
          notifications: headless,
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
}
