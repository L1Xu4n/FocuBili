import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/profile/android_permission_management_page.dart';
import 'package:focubili/services/focus_notification_service.dart';

/// 注册统一 Android 权限页的状态、用途说明和系统入口组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'com.focubili.app/test_android_permission_management',
  );
  final List<MethodCall> calls = <MethodCall>[];

  /// 每项测试提供一台需要小米后台自启动保护的假 Android 设备。
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'getPermissionOverview') {
            return <String, Object?>{
              'notificationAllowed': false,
              'exactAlarmAllowed': true,
              'doNotDisturbAllowed': false,
              'batteryOptimizationIgnored': false,
              'backgroundRestricted': true,
              'requiresAutostartGuide': true,
              'manufacturer': 'Xiaomi',
              'apiLevel': 35,
            };
          }
          if (call.method == 'requestPermission') {
            return true;
          }
          return null;
        });
  });

  /// 每项测试后解除假原生通道，避免影响其他组件测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('统一权限页展示五类权限并保留申请和取消入口', (WidgetTester tester) async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidPermissionManagementPage(notificationService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('权限管理'), findsOneWidget);
    expect(find.byKey(const Key('permission-notifications')), findsOneWidget);
    expect(find.byKey(const Key('permission-exact-alarm')), findsOneWidget);
    expect(find.byKey(const Key('permission-do-not-disturb')), findsOneWidget);
    expect(find.textContaining('预约时间显示'), findsOneWidget);
    expect(find.text('管理/取消'), findsWidgets);

    await tester.tap(find.text('申请'));
    await tester.pumpAndSettle();
    expect(
      calls.map((MethodCall call) => call.method),
      containsAllInOrder(<String>[
        'getPermissionOverview',
        'requestPermission',
        'getPermissionOverview',
      ]),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('permission-battery')),
      300,
    );
    expect(find.byKey(const Key('permission-battery')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.descendant(
        of: find.byKey(const Key('permission-autostart')),
        matching: find.text('打开设置'),
      ),
      350,
    );
    expect(find.byKey(const Key('permission-autostart')), findsOneWidget);
    expect(find.textContaining('小米/HyperOS 划掉后台'), findsOneWidget);
    final Finder autostartSettingsButton = find.descendant(
      of: find.byKey(const Key('permission-autostart')),
      matching: find.text('打开设置'),
    );
    await tester.ensureVisible(autostartSettingsButton);
    await tester.pumpAndSettle();
    await tester.tap(autostartSettingsButton);
    await tester.pump();
    expect(calls.last.method, 'openBackgroundAutostartSettings');
  });
}
