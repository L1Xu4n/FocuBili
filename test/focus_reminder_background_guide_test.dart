import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_reminder_background_guide.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';

/// 提供一个按钮宿主，用来从有效 BuildContext 触发一次后台提醒保护引导。
class _BackgroundGuideHost extends StatelessWidget {
  /// 创建使用假原生服务、内存偏好设置和导航回调的引导宿主。
  const _BackgroundGuideHost({
    required this.notificationService,
    required this.preferencesService,
    required this.onOpenPermissions,
  });

  final FocusNotificationService notificationService;
  final FocusPreferencesService preferencesService;
  final Future<void> Function() onOpenPermissions;

  /// 构建测试按钮；点击后异步执行与提醒设置成功后相同的引导函数。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('show-background-guide'),
          onPressed: () => unawaited(
            showFocusReminderBackgroundGuideIfNeeded(
              context,
              notificationService: notificationService,
              preferencesService: preferencesService,
              openPermissionManagement: onOpenPermissions,
            ),
          ),
          child: const Text('设置提醒成功'),
        ),
      ),
    );
  }
}

/// 注册小米首次成功设置提醒后的后台保护引导组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'com.focubili.app/test_background_reminder_guide',
  );

  /// 每项测试重置内存偏好并提供需要自启动引导的小米权限状态。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'getPermissionOverview') {
            return <String, Object?>{
              'notificationAllowed': true,
              'exactAlarmAllowed': true,
              'doNotDisturbAllowed': false,
              'batteryOptimizationIgnored': false,
              'backgroundRestricted': false,
              'requiresAutostartGuide': true,
              'manufacturer': 'Xiaomi',
              'apiLevel': 35,
            };
          }
          return null;
        });
  });

  /// 每项测试后解除假原生通道。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('小米第一次设置提醒会引导权限管理且只显示一次', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService preferencesService = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    int openedPermissions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _BackgroundGuideHost(
          notificationService: const FocusNotificationService(channel: channel),
          preferencesService: preferencesService,
          // 假导航函数记录用户已经选择进入统一权限管理页。
          onOpenPermissions: () async {
            openedPermissions += 1;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('show-background-guide')));
    await tester.pumpAndSettle();
    expect(find.text('开启后台提醒保护'), findsOneWidget);
    expect(find.textContaining('后台自启动'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '权限管理'));
    await tester.pumpAndSettle();
    expect(openedPermissions, 1);
    expect(
      (await preferencesService.load()).hasSeenBackgroundReminderGuide,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('show-background-guide')));
    await tester.pumpAndSettle();
    expect(find.text('开启后台提醒保护'), findsNothing);
    expect(openedPermissions, 1);
  });
}
