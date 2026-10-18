import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/subscription_notification_delivery.dart';
import 'package:focubili/services/subscription_notification_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/windows_focus_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_service_test.dart' show Content, item, source;

final _disposed = Expando<bool>();

List<SubscriptionFeedItem> _items() => [
  SubscriptionFeedItem(
    bvid: 'synthetic-entry',
    title: 'Synthetic entry',
    coverUrl: '',
    sources: const {'creator:1': 'Synthetic source'},
    discoveredAt: DateTime.utc(2026),
  ),
];

class _Preferences extends Fake implements SharedPreferences {
  final values = <String, String>{};
  @override
  Future<void> reload() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }
}

class _Client extends Fake implements WindowsNotificationClient {
  final entered = Completer<void>();
  final ready = Completer<bool>();
  final shown = <({int id, String title})>[];
  @override
  Future<bool> initialize() {
    entered.complete();
    return ready.future;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add((id: id, title: title));
  }
}

Future<(SubscriptionService, Content)> _service(String prefix) async {
  final content = Content()
    ..pages[1] = [
      [item('$prefix-old')],
    ];
  final prefs = _Preferences();
  final service = SubscriptionService(
    contentService: content,
    preferencesLoader: () async => prefs,
  );
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
  return (service, content);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [AppPlatform.windows, AppPlatform.linux]) {
    for (final change in [
      'notifications',
      'enabled',
      'pause',
      'delete',
      'focus',
      'dispose',
      'none',
    ]) {
      test(
        '${platform.name} provider preparation rechecks $change before delivery',
        () async {
          final (service, _) = await _service('fixture');
          final client = _Client();
          final notifications = SubscriptionNotificationService(
            platform: platform,
            desktopBackend: WindowsFocusNotificationBackend(client: client),
          );
          service.notifyItems = (items) => notifications.showItems(
            items,
            generation: service.notificationGeneration,
          );
          final pending = service.refresh(manual: true);
          await client.entered.future;
          switch (change) {
            case 'notifications':
              await service.setNotificationsEnabled(false);
            case 'enabled':
              await service.setEnabled(false);
            case 'pause':
              await service.pauseSource('creator:1', true);
            case 'delete':
              await service.deleteSource('creator:1');
            case 'focus':
              service.suppressNotifications = () => true;
            case 'dispose':
              service.dispose();
              _disposed[service] = true;
          }
          client.ready.complete(true);
          await pending;
          expect(
            client.shown.map((entry) => entry.title).toList(),
            change == 'none' ? ['fixture-new'] : isEmpty,
          );
        },
      );
    }
  }

  test(
    'two services sharing provider initialization retain independent guards',
    () async {
      final (first, _) = await _service('first');
      final (second, _) = await _service('second');
      final client = _Client();
      final notifications = SubscriptionNotificationService(
        platform: AppPlatform.windows,
        desktopBackend: WindowsFocusNotificationBackend(client: client),
      );
      final secondEntered = Completer<void>();
      first.notifyItems = (items) => notifications.showItems(
        items,
        generation: first.notificationGeneration,
      );
      second.notifyItems = (items) {
        secondEntered.complete();
        return notifications.showItems(
          items,
          generation: second.notificationGeneration,
        );
      };
      final firstCheck = first.refresh(manual: true);
      await client.entered.future;
      final secondCheck = second.refresh(manual: true);
      await secondEntered.future;
      await first.setNotificationsEnabled(false);
      client.ready.complete(true);
      await Future.wait([firstCheck, secondCheck]);
      expect(client.shown.map((entry) => entry.title).toList(), ['second-new']);
    },
  );

  test('nested service delivery restores the outer request guard', () async {
    final (outer, _) = await _service('outer');
    final (inner, _) = await _service('inner');
    final client = _Client();
    final notifications = SubscriptionNotificationService(
      platform: AppPlatform.windows,
      desktopBackend: WindowsFocusNotificationBackend(client: client),
    );
    inner.notifyItems = (items) => notifications.showItems(
      items,
      generation: inner.notificationGeneration,
    );
    outer.notifyItems = (items) async {
      await inner.refresh(manual: true);
      return notifications.showItems(
        items,
        generation: outer.notificationGeneration,
      );
    };
    final pending = outer.refresh(manual: true);
    await client.entered.future;
    await outer.setNotificationsEnabled(false);
    client.ready.complete(true);
    await pending;
    expect(client.shown.map((entry) => entry.title).toList(), ['inner-new']);
  });

  test(
    'subscription guards fail closed and leave focus completion independent',
    () async {
      final client = _Client()..ready.complete(true);
      final backend = WindowsFocusNotificationBackend(client: client);
      final notifications = SubscriptionNotificationService(
        platform: AppPlatform.windows,
        desktopBackend: backend,
      );
      final feed = _items();
      await SubscriptionNotificationDelivery.run(() => false, () async {
        await backend.showFocusCompleted(
          sessionId: 'synthetic-focus',
          goal: 'Synthetic goal',
          focusedMinutes: 5,
        );
        expect(await notifications.showItems(feed), isFalse);
      });
      expect(client.shown, hasLength(1));
      expect(client.shown.single.id, isNot(48108));
      await SubscriptionNotificationDelivery.run(
        () => throw StateError('synthetic guard failure'),
        () async {
          expect(await notifications.showItems(feed), isFalse);
        },
      );
      expect(client.shown, hasLength(1));
      expect(await notifications.showItems(feed), isTrue);
      expect(client.shown.last.id, 48108);
    },
  );

  for (final rejected in [false, true]) {
    test(
      'provider ${rejected ? 'exception' : 'unavailable'} preserves failed-delivery behavior',
      () async {
        final client = _Client();
        final notifications = SubscriptionNotificationService(
          platform: AppPlatform.windows,
          desktopBackend: WindowsFocusNotificationBackend(client: client),
        );
        final pending = notifications.showItems(_items());
        await client.entered.future;
        if (rejected) {
          client.ready.completeError(StateError('synthetic provider failure'));
        } else {
          client.ready.complete(false);
        }
        expect(await pending, isFalse);
        expect(client.shown, isEmpty);
      },
    );
  }
}
