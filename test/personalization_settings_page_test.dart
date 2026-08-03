import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';

/// 注册设置页专注勿扰开关、说明和系统权限入口测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'com.focubili.app/test_settings_focus_notifications',
  );
  final List<MethodCall> calls = <MethodCall>[];

  /// 每项测试使用空白本机设置，并模拟尚未授予勿扰特殊访问权限。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'hasDoNotDisturbAccess' => false,
            'setFocusDoNotDisturb' => true,
            _ => null,
          };
        });
  });

  /// 每项测试后解除方法通道，避免权限结果泄漏到其他测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 验证首次开启开关会保存选择、解释权限，并可打开 Android 特殊访问设置。
  testWidgets('设置页开启专注勿扰并请求系统权限', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService preferencesService = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          focusPreferencesService: preferencesService,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-android-permissions')), findsOneWidget);
    final Finder toggle = find.byKey(const Key('enable-focus-do-not-disturb'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('允许控制勿扰模式'), findsOneWidget);
    expect((await preferencesService.load()).enableDoNotDisturb, isTrue);

    await tester.tap(find.text('打开系统设置'));
    await tester.pumpAndSettle();
    expect(
      calls.any((MethodCall call) => call.method == 'openDoNotDisturbSettings'),
      isTrue,
    );
    expect(find.textContaining('尚未授权'), findsOneWidget);
  });
}
