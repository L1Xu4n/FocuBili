import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/focus_notification_service.dart';

class Permission extends FocusNotificationService {
  int requests = 0;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return false;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'off default, permission only on explicit notifications switch; rejection keeps list',
    (tester) async {
      final s = SubscriptionService();
      addTearDown(s.dispose);
      await s.initialize();
      final permission = Permission();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionUpdatesPage(
            service: s,
            notificationService: permission,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('开启订阅更新'), findsOneWidget);
      expect(permission.requests, 0);
      expect(s.enabled, false);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      expect(s.enabled, true);
      expect(permission.requests, 0);
      await tester.tap(find.byType(SwitchListTile).last);
      await tester.pumpAndSettle();
      expect(permission.requests, 1);
      expect(s.notificationsEnabled, false);
      expect(find.text('通知未获授权，更新列表仍可使用。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
