import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/app.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/subscription_notification_delivery.dart';
import 'package:focubili/services/subscription_notification_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_subscription_background_test.dart' show nativeCall;
import 'subscription_service_test.dart' show Content, item, source;

class _Preparation {
  _Preparation(this.args);
  final Map<Object?, Object?> args;
  final settings = Completer<void>();
  final checked = Completer<bool>();
  String get requestId => args['requestId'] as String;
}

/// Protocol double: holds the system-settings boundary and can hold a guard
/// reply in flight. The Foundation-only Swift probe checks the native gate.
class _AppleHost {
  _AppleHost(this.channel, {this.holdCommit = false, this.cancelFailure}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }
  final MethodChannel channel;
  final bool holdCommit;
  final String? cancelFailure;
  final commit = Completer<void>();
  final preparations = <_Preparation>[];
  final cancelled = <String>{};
  final shown = <String>[];
  final _waiters = <int, Completer<void>>{};

  Future<void> waitForRequests(int count) async {
    if (preparations.length >= count) return;
    await (_waiters[count] ??= Completer<void>()).future;
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'consumeTap') return false;
    if (call.method == 'cancelSummary') {
      if (cancelFailure == 'missing') throw MissingPluginException();
      if (cancelFailure == 'exception') {
        throw PlatformException(code: 'synthetic_cancel_failure');
      }
      cancelled.add((call.arguments as Map)['requestId'] as String);
      return null;
    }
    if (call.method != 'showSummary') throw MissingPluginException();
    final preparation = _Preparation(Map.of(call.arguments as Map));
    preparations.add(preparation);
    _waiters.remove(preparations.length)?.complete();
    await preparation.settings.future;
    final id = preparation.requestId;
    final allowed = await nativeCall(channel, 'canDeliver', {'requestId': id});
    preparation.checked.complete(allowed == true);
    if (holdCommit) await commit.future;
    if (allowed != true || cancelled.contains(id)) return false;
    shown.add(preparation.args['title'] as String? ?? 'summary');
    return true;
  }
}

final _disposed = Expando<bool>();

Future<SubscriptionService> _service(String prefix) async {
  SharedPreferences.setMockInitialValues({});
  final content = Content()
    ..pages[1] = [
      [item('$prefix-old')],
    ];
  final service = SubscriptionService(contentService: content);
  addTearDown(() {
    if (_disposed[service] != true) service.dispose();
  });
  await service.addSource(source(1));
  await service.setEnabled(true);
  await service.setNotificationsEnabled(true);
  service.setForeground(true);
  await service.refresh(manual: true);
  content.pages[1] = [
    [item('$prefix-new'), item('$prefix-old')],
  ];
  return service;
}

class _Focus extends FocusTimerController {
  bool active = false;
  @override
  bool get hasActiveSession => active;
  @override
  Future<void> initialize() async {}
  void change(bool value) {
    active = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [AppPlatform.ios, AppPlatform.macos]) {
    for (final change in [
      'notifications',
      'notifications off/on',
      'enabled',
      'enabled off/on',
      'pause',
      'pause/resume',
      'delete',
      'delete/readd',
      'focus',
      'service dispose',
      'notification dispose',
      'none',
    ]) {
      test('${platform.name} late settings recheck $change', () async {
        final service = await _service('fixture');
        final host = _AppleHost(MethodChannel('test/apple/${platform.name}'));
        final notifications = SubscriptionNotificationService(
          channel: host.channel,
          platform: platform,
        );
        addTearDown(notifications.dispose);
        service.notifyItems = (items) => notifications.showItems(
          items,
          generation: service.notificationGeneration,
        );
        final pending = service.refresh(manual: true);
        await host.waitForRequests(1);
        expect(service.backgroundRefreshEnabled, false);
        switch (change) {
          case 'notifications':
            await service.setNotificationsEnabled(false);
          case 'notifications off/on':
            await service.setNotificationsEnabled(false);
            await service.setNotificationsEnabled(true);
          case 'enabled':
            await service.setEnabled(false);
          case 'enabled off/on':
            await service.setEnabled(false);
            await service.setEnabled(true);
          case 'pause':
            await service.pauseSource('creator:1', true);
          case 'pause/resume':
            await service.pauseSource('creator:1', true);
            await service.pauseSource('creator:1', false);
          case 'delete':
            await service.deleteSource('creator:1');
          case 'delete/readd':
            await service.deleteSource('creator:1');
            await service.addSource(source(1));
          case 'focus':
            service.suppressNotifications = () => true;
          case 'service dispose':
            service.dispose();
            _disposed[service] = true;
          case 'notification dispose':
            notifications.dispose();
        }
        host.preparations.single.settings.complete();
        await pending;
        expect(host.shown, change == 'none' ? ['fixture-new'] : isEmpty);
      });
    }

    test(
      '${platform.name} requests retain captured guards and tap handler',
      () async {
        final channel = MethodChannel('test/apple/${platform.name}');
        final host = _AppleHost(channel);
        final first = SubscriptionNotificationService(
          channel: channel,
          platform: platform,
        );
        // A distinct MethodChannel object with the same messenger/name.
        final second = SubscriptionNotificationService(
          channel: MethodChannel(channel.name),
          platform: platform,
        );
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        var taps = 0;
        await first.initialize(() => taps += 100);
        var firstAllowed = true;
        final firstSend = SubscriptionNotificationDelivery.run(
          () => firstAllowed,
          () => first.showSummary(1, title: 'first'),
        );
        await host.waitForRequests(1);
        await second.initialize(() => taps++);
        final secondSend = SubscriptionNotificationDelivery.run(
          () => true,
          () => second.showSummary(1, title: 'second'),
        );
        await host.waitForRequests(2);
        firstAllowed = false;
        host.preparations[0].settings.complete();
        // Evaluate before disposal so the test proves that the original guard
        // was captured, independently of the owner's disposal check.
        expect(await host.preparations[0].checked.future, false);
        first.dispose();
        await nativeCall(channel, 'subscriptionTapped');
        expect(taps, 1);
        expect(
          host.preparations[0].requestId,
          isNot(host.preparations[1].requestId),
        );
        host.preparations[1].settings.complete();
        expect(await firstSend, false);
        expect(await secondSend, true);
        expect(host.shown, ['second']);
        expect(
          await nativeCall(channel, 'canDeliver', {
            'requestId': host.preparations[1].requestId,
          }),
          false,
        );
        expect(
          await nativeCall(channel, 'canDeliver', {'requestId': 'unknown'}),
          false,
        );
        expect(await nativeCall(channel, 'canDeliver', 4), false);
      },
    );

    test('${platform.name} late guard throws fail closed', () async {
      final host = _AppleHost(MethodChannel('test/apple/${platform.name}'));
      final notifications = SubscriptionNotificationService(
        channel: host.channel,
        platform: platform,
      );
      addTearDown(notifications.dispose);
      var fail = false;
      final pending = SubscriptionNotificationDelivery.run(
        () => fail ? throw StateError('synthetic guard failure') : true,
        () => notifications.showSummary(1),
      );
      await host.waitForRequests(1);
      fail = true;
      host.preparations.single.settings.complete();
      expect(await pending, false);
      expect(host.shown, isEmpty);
    });

    test(
      '${platform.name} cancellation rejects an in-flight positive reply',
      () async {
        final host = _AppleHost(
          MethodChannel('test/apple/${platform.name}'),
          holdCommit: true,
        );
        final notifications = SubscriptionNotificationService(
          channel: host.channel,
          platform: platform,
        );
        addTearDown(notifications.dispose);
        final pending = notifications.showSummary(1);
        await host.waitForRequests(1);
        host.preparations.single.settings.complete();
        expect(await host.preparations.single.checked.future, true);
        expect(
          await nativeCall(host.channel, 'canDeliver', {
            'requestId': host.preparations.single.requestId,
          }),
          false,
          reason:
              'The first guard query consumes its request before delivery completes',
        );
        notifications.cancelPending();
        host.commit.complete();
        expect(await pending, false);
        expect(host.cancelled, contains(host.preparations.single.requestId));
        expect(host.shown, isEmpty);
      },
    );

    for (final failure in ['missing', 'exception']) {
      test(
        '${platform.name} cancellation $failure still rejects late queries',
        () async {
          final host = _AppleHost(
            MethodChannel('test/apple/${platform.name}'),
            cancelFailure: failure,
          );
          final notifications = SubscriptionNotificationService(
            channel: host.channel,
            platform: platform,
          );
          addTearDown(notifications.dispose);
          final pending = notifications.showSummary(1);
          await host.waitForRequests(1);
          notifications.cancelPending();
          host.preparations.single.settings.complete();
          expect(await pending, false);
          expect(host.shown, isEmpty);
        },
      );
    }
  }

  test(
    'iOS headless keeps generation protocol without foreground callback',
    () async {
      const channel = MethodChannel('test/apple/headless');
      Map? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            args = call.arguments as Map;
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final notifications = SubscriptionNotificationService(
        channel: channel,
        platform: AppPlatform.ios,
      );
      addTearDown(notifications.dispose);
      expect(
        await notifications.showSummary(2, background: true, generation: 7),
        true,
      );
      expect(args, {'count': 2, 'generation': 7, 'background': true});
      expect(
        await nativeCall(channel, 'canDeliver', {'requestId': 'unknown'}),
        isNull,
      );
    },
  );

  testWidgets(
    'app focus start/end permanently cancels old preparations and keeps taps/new requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final focus = _Focus();
      final subscriptions = SubscriptionService();
      final host = _AppleHost(const MethodChannel('test/apple/app-focus'));
      final notifications = SubscriptionNotificationService(
        channel: host.channel,
        platform: AppPlatform.ios,
      );
      addTearDown(focus.dispose);
      addTearDown(subscriptions.dispose);
      await tester.pumpWidget(
        FocuBiliApp(
          focusTimerController: focus,
          subscriptionService: subscriptions,
          subscriptionNotificationService: notifications,
        ),
      );
      // Unscoped requests still require an active service/request, even when no
      // SubscriptionService refresh guard exists.
      final old = notifications.showSummary(1, title: 'old');
      await host.waitForRequests(1);
      focus.change(true);
      focus.change(true); // Routine active-session ticks are idempotent.
      focus.change(false);
      host.preparations[0].settings.complete();
      expect(await old, false);
      var taps = 0;
      await notifications.initialize(() => taps++);
      await nativeCall(host.channel, 'subscriptionTapped');
      expect(taps, 1);
      final fresh = notifications.showSummary(1, title: 'fresh');
      await host.waitForRequests(2);
      host.preparations[1].settings.complete();
      expect(await fresh, true);
      expect(host.shown, ['fresh']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
