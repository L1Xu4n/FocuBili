import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/subscription_notification_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/windows_focus_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_service_test.dart' show Content, item, source;

class _DelayedNotificationClient extends Fake
    implements WindowsNotificationClient {
  final entered = Completer<void>();
  final ready = Completer<bool>();
  final events = <String>[];
  @override
  Future<bool> initialize() async {
    entered.complete();
    return ready.future;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    events.add('show:$title');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'review: a completed notification opt-out cancels delivery waiting on the desktop provider',
    () async {
      SharedPreferences.setMockInitialValues({});
      final content = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final service = SubscriptionService(contentService: content);
      addTearDown(service.dispose);
      await service.addSource(source(1));
      await service.setEnabled(true);
      await service.setNotificationsEnabled(true);
      service.setForeground(true);
      await service.refresh(manual: true);

      final client = _DelayedNotificationClient();
      final notifications = SubscriptionNotificationService(
        platform: AppPlatform.windows,
        desktopBackend: WindowsFocusNotificationBackend(client: client),
      );
      service.notifyItems = (items) => notifications.showItems(
        items,
        generation: service.notificationGeneration,
      );
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      final check = service.refresh(manual: true);
      await client.entered.future;
      final oldGeneration = service.notificationGeneration;
      await service.setNotificationsEnabled(false);
      client.events.add('opt-out-committed');
      expect(service.notificationGeneration, greaterThan(oldGeneration));
      expect(service.notificationsEnabled, isFalse);
      client.ready.complete(true);
      await check;
      expect(client.events, ['opt-out-committed']);
    },
  );
}
