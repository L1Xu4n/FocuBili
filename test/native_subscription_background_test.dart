import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/native_subscription_scheduler.dart';
import 'package:focubili/services/subscription_background_service.dart';
import 'package:focubili/services/subscription_service.dart';

import 'subscription_background_test.dart' show AtomicSnapshots;
import 'subscription_service_test.dart' show Content, item, source;

const schedulerChannel = MethodChannel('test/native_subscription_scheduler');
const workerChannel = MethodChannel('test/apple_subscription_worker');

Future<Object?> nativeCall(
  MethodChannel channel,
  String method, [
  Object? args,
]) {
  final response = Completer<Object?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (data) {
          try {
            response.complete(
              data == null
                  ? null
                  : const StandardMethodCodec().decodeEnvelope(data),
            );
          } catch (error, stack) {
            response.completeError(error, stack);
          }
        },
      );
  return response.future;
}

class FakeAppleWorker extends SubscriptionService {
  final finished = Completer<void>();
  int? generation;
  Duration? budget;
  int cancelled = 0, disposed = 0;
  String? interruption;
  @override
  Future<void> runBackgroundCheck(
    int generation, {
    Duration budget = const Duration(minutes: 8),
  }) async {
    this.generation = generation;
    this.budget = budget;
    await finished.future;
  }

  @override
  void cancelBackgroundCheck() {
    cancelled++;
    if (!finished.isCompleted) finished.complete();
  }

  @override
  Future<void> recordBackgroundInterruption(String status) async {
    interruption = status;
  }

  @override
  void dispose() {
    disposed++;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final configurations = <Map<Object?, Object?>>[];
  var available = true, accepted = true;
  var status = 'ready', mode = 'process';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    configurations.clear();
    available = true;
    accepted = true;
    status = 'ready';
    mode = 'process';
    messenger.setMockMethodCallHandler(schedulerChannel, (call) async {
      if (call.method == 'configure') {
        configurations.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return {
        'available': available,
        'accepted': accepted,
        'status': status,
        'mode': mode,
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(schedulerChannel, null);
    messenger.setMockMethodCallHandler(workerChannel, null);
  });

  NativeSubscriptionScheduler scheduler(AppPlatform platform) =>
      NativeSubscriptionScheduler(
        platform: platform,
        channel: schedulerChannel,
      );

  test(
    'native bridge reports support, generations and exact default interval',
    () async {
      final native = scheduler(AppPlatform.windows);
      final checks = <int>[];
      await native.initialize((generation) async => checks.add(generation));
      expect(native.available, isTrue);
      expect(native.mode, 'process');
      await native.configure(true, 42);
      expect(configurations.single, {
        'enabled': true,
        'generation': 42,
        'intervalSeconds': 3600,
      });
      expect(
        await nativeCall(schedulerChannel, 'check', {'generation': -1}),
        isFalse,
      );
      expect(
        await nativeCall(schedulerChannel, 'check', {'generation': '42'}),
        isFalse,
      );
      expect(
        await nativeCall(schedulerChannel, 'check', {'generation': 42}),
        isTrue,
      );
      expect(checks, [42]);
      await native.dispose();
      expect(configurations.last['enabled'], isFalse);
    },
  );

  test(
    'missing native implementation falls back without pretending background support',
    () async {
      messenger.setMockMethodCallHandler(schedulerChannel, null);
      final native = scheduler(AppPlatform.linux);
      await native.initialize((_) async {});
      expect(native.available, isFalse);
      await expectLater(
        native.configure(true, 1),
        throwsA(isA<MissingPluginException>()),
      );
      await native.dispose();
    },
  );

  test(
    'disable rejects a queued old tick immediately and serializes native writes',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final writes = <bool>[];
      messenger.setMockMethodCallHandler(schedulerChannel, (call) async {
        if (call.method == 'configure') {
          final enabled = (call.arguments as Map)['enabled'] as bool;
          writes.add(enabled);
          if (enabled) {
            entered.complete();
            await release.future;
          }
        }
        return {
          'available': true,
          'accepted': true,
          'mode': 'process',
          'status': 'ready',
        };
      });
      final native = scheduler(AppPlatform.windows);
      var checks = 0;
      await native.initialize((_) async {
        checks++;
      });
      final first = native.configure(true, 11);
      await entered.future;
      final second = native.configure(false, 12);
      expect(
        await nativeCall(schedulerChannel, 'check', {'generation': 11}),
        isFalse,
      );
      expect(checks, 0);
      expect(writes, [true]);
      release.complete();
      await Future.wait([first, second]);
      expect(writes, [true, false]);
      await native.dispose();
    },
  );

  test(
    'native submission failure is reported and iOS UI disposal preserves OS request',
    () async {
      mode = 'opportunistic';
      final native = scheduler(AppPlatform.ios);
      await native.initialize((_) async {});
      accepted = false;
      status = 'schedule_failed';
      await expectLater(native.configure(true, 7), throwsStateError);
      expect(native.status, 'schedule_failed');
      await native.dispose();
      expect(configurations.length, 1);
    },
  );

  for (final platform in [
    AppPlatform.windows,
    AppPlatform.linux,
    AppPlatform.macos,
  ]) {
    test(
      '${platform.name}: losing focus keeps a running subscribed check alive',
      () async {
        var now = DateTime(2026, 10, 18);
        final content = Content()
          ..pages[1] = [
            [item('old')],
          ];
        final prefs = await SharedPreferences.getInstance();
        final service = SubscriptionService(
          platform: platform,
          nativeScheduler: scheduler(platform),
          preferencesLoader: () async => prefs,
          contentService: content,
          clock: () => now,
        );
        await service.initialize();
        await service.addSource(source(1));
        await service.setEnabled(true);
        service.setForeground(true);
        await service.refresh(manual: true);
        await service.setBackgroundRefreshEnabled(true);
        now = now.add(const Duration(hours: 2));
        content.pages[1] = [
          [item('new'), item('old')],
        ];
        content.hold = Completer<void>();
        final pending = service.refresh();
        while (content.calls.length < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        service.setForeground(false);
        content.hold!.complete();
        await pending;
        expect(service.feed.map((e) => e.bvid), ['new']);
        expect(service.backgroundCheckDescription, contains('退出'));
        final staleGeneration = service.notificationGeneration;
        await service.setBackgroundRefreshEnabled(false);
        content.calls.clear();
        await nativeCall(schedulerChannel, 'check', {
          'generation': staleGeneration,
        });
        expect(content.calls, isEmpty);
        service.dispose();
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  test(
    'iOS disabled-system state keeps opt-in, allows opt-out and foreground checking',
    () async {
      var now = DateTime(2026, 10, 18);
      mode = 'opportunistic';
      final store = AtomicSnapshots();
      final content = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final service = SubscriptionService(
        platform: AppPlatform.ios,
        snapshotStore: store,
        nativeScheduler: scheduler(AppPlatform.ios),
        contentService: content,
        clock: () => now,
      );
      await service.initialize();
      await service.addSource(source(1));
      await service.setEnabled(true);
      service.setForeground(true);
      await service.refresh(manual: true);
      await service.setBackgroundRefreshEnabled(true);
      available = false;
      await service.reconcileBackgroundSchedule();
      expect(service.backgroundRefreshEnabled, isTrue);
      expect(service.backgroundRefreshSupported, isFalse);
      expect(service.backgroundStatusText, contains('前台检查'));
      expect(configurations.last['enabled'], isFalse);
      now = now.add(const Duration(hours: 2));
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      await service.refresh();
      expect(service.unreadCount, 1);
      await service.setBackgroundRefreshEnabled(false);
      expect(service.backgroundRefreshEnabled, isFalse);
      service.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'iOS native expiration and startup failure are visible without clearing saved updates',
    () async {
      mode = 'opportunistic';
      final service = SubscriptionService(
        platform: AppPlatform.ios,
        snapshotStore: AtomicSnapshots(),
        nativeScheduler: scheduler(AppPlatform.ios),
        contentService: Content(),
      );
      await service.initialize();
      await service.setEnabled(true);
      await service.setBackgroundRefreshEnabled(true);
      for (final value in ['expired', 'engine_failed']) {
        status = value;
        await service.reconcileBackgroundSchedule();
        expect(service.backgroundStatusText, contains('前台或下次继续'));
      }
      service.dispose();
    },
  );

  testWidgets(
    'desktop background switch has process limits and no Android battery dialog',
    (tester) async {
      final service = SubscriptionService(
        platform: AppPlatform.windows,
        nativeScheduler: scheduler(AppPlatform.windows),
        contentService: Content(),
      );
      await service.initialize();
      await service.setEnabled(true);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subscription-background-switch')));
      await tester.pumpAndSettle();
      expect(service.backgroundRefreshEnabled, isTrue);
      expect(find.textContaining('仅在应用进程运行时有效'), findsOneWidget);
      expect(find.text('让每小时检查更可靠'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'iOS unavailable-system switch preserves on state and can still be turned off',
    (tester) async {
      mode = 'opportunistic';
      final service = SubscriptionService(
        platform: AppPlatform.ios,
        nativeScheduler: scheduler(AppPlatform.ios),
        snapshotStore: AtomicSnapshots(),
        contentService: Content(),
      );
      await service.initialize();
      await service.setEnabled(true);
      await service.setBackgroundRefreshEnabled(true);
      available = false;
      await service.reconcileBackgroundSchedule();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('subscription-background-switch')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('subscription-background-switch')));
      await tester.pumpAndSettle();
      expect(service.backgroundRefreshEnabled, isFalse);
      expect(find.textContaining('不保证每小时'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      await tester.pump();
    },
  );

  test(
    'native worker is invalidated before a notification policy commit',
    () async {
      final store = AtomicSnapshots();
      final service = SubscriptionService(
        platform: AppPlatform.ios,
        nativeScheduler: scheduler(AppPlatform.ios),
        snapshotStore: store,
        contentService: Content(),
      );
      await service.initialize();
      await service.setEnabled(true);
      await service.setBackgroundRefreshEnabled(true);
      final before = store.generation;
      final observed = <(bool, int, int)>[];
      messenger.setMockMethodCallHandler(schedulerChannel, (call) async {
        if (call.method == 'configure') {
          final args = call.arguments as Map;
          observed.add((
            args['enabled'] as bool,
            args['generation'] as int,
            store.generation,
          ));
        }
        return {
          'available': true,
          'accepted': true,
          'mode': 'opportunistic',
          'status': 'waiting_system',
        };
      });
      await service.setNotificationsEnabled(true);
      expect(observed.first, (false, before, before));
      expect(observed.last, (true, before + 1, before + 1));
      service.dispose();
    },
  );

  test(
    'manual request following an automatic no-op still scans once',
    () async {
      var now = DateTime(2026, 10, 18);
      final content = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final service = SubscriptionService(
        contentService: content,
        clock: () => now,
      );
      await service.initialize();
      await service.addSource(source(1));
      await service.setEnabled(true);
      service.setForeground(true);
      await service.refresh();
      now = now.add(const Duration(minutes: 1));
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      content.calls.clear();
      final automatic = service.refresh();
      final manual = service.refresh(manual: true);
      await Future.wait([automatic, manual]);
      expect(service.feed.map((e) => e.bvid), ['new']);
      expect(content.calls, ['1:1']);
      service.dispose();
    },
  );

  test('expiration before ready never creates a subscription reader', () async {
    final ready = Completer<Map<String, Object?>>();
    final complete = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(workerChannel, (call) async {
      if (call.method == 'ready') return ready.future;
      if (call.method == 'complete') {
        complete.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return true;
    });
    var created = false;
    final run = runAppleSubscriptionWorker(
      channel: workerChannel,
      createService: () {
        created = true;
        return FakeAppleWorker();
      },
    );
    await nativeCall(workerChannel, 'expire');
    ready.complete({'runId': 'synthetic-expired', 'generation': 17});
    await run;
    expect(created, isFalse);
    expect(complete, [
      {'runId': 'synthetic-expired', 'success': false},
    ]);
  });

  Future<List<Map<Object?, Object?>>> workerCalls(
    FakeAppleWorker worker,
  ) async {
    final complete = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(workerChannel, (call) async {
      if (call.method == 'ready') {
        return {
          'runId': 'synthetic-run',
          'generation': 17,
          'budgetMilliseconds': 1000,
        };
      }
      if (call.method == 'complete') {
        complete.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return true;
    });
    return complete;
  }

  test(
    'headless worker completes once and disposes without any account or native notification',
    () async {
      final worker = FakeAppleWorker()..finished.complete();
      final complete = await workerCalls(worker);
      await runAppleSubscriptionWorker(
        channel: workerChannel,
        createService: () => worker,
      );
      expect(worker.generation, 17);
      expect(worker.budget, const Duration(seconds: 1));
      expect(worker.disposed, 1);
      expect(complete, [
        {'runId': 'synthetic-run', 'success': true},
      ]);
    },
  );

  test(
    'native expiration cancels in-flight work and reports failure',
    () async {
      final worker = FakeAppleWorker();
      final complete = await workerCalls(worker);
      final run = runAppleSubscriptionWorker(
        channel: workerChannel,
        createService: () => worker,
      );
      while (worker.generation == null) {
        await Future<void>.delayed(Duration.zero);
      }
      await nativeCall(workerChannel, 'expire');
      await run;
      expect(worker.cancelled, 1);
      expect(worker.interruption, contains('时间已到'));
      expect(worker.disposed, 1);
      expect(complete.single['success'], isFalse);
    },
  );

  testWidgets(
    'worker enforces local time budget if native expiration is late',
    (tester) async {
      final worker = FakeAppleWorker();
      final complete = await workerCalls(worker);
      final run = runAppleSubscriptionWorker(
        channel: workerChannel,
        createService: () => worker,
      );
      await tester.pump();
      expect(worker.generation, 17);
      await tester.pump(const Duration(seconds: 1));
      await run;
      expect(worker.cancelled, 1);
      expect(complete.single['success'], isFalse);
    },
  );
}
