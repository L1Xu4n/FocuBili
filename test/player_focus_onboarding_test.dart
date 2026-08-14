import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/player_focus_onboarding.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/focus_preferences_service.dart';

/// 注册播放器专注首次勿扰说明的显示、设置入口和只展示一次测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 验证首次打开会说明自动勿扰并进入设置，第二次打开不再重复提示。
  testWidgets('播放器专注首次引导自动勿扰设置', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService service = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    int settingsOpenCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              // 测试按钮函数模拟用户第一次和第二次打开播放器专注面板。
              onPressed: () => unawaited(
                showPlayerFocusDoNotDisturbGuideIfNeeded(
                  context,
                  preferencesService: service,
                  openSettings: () async => settingsOpenCount += 1,
                  appPlatform: AppPlatform.android,
                ),
              ),
              child: const Text('打开播放器专注'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开播放器专注'));
    await tester.pumpAndSettle();
    expect(find.text('专注时可以自动开启勿扰'), findsOneWidget);
    await tester.tap(find.text('前往设置'));
    await tester.pumpAndSettle();
    expect(settingsOpenCount, 1);
    expect((await service.load()).hasSeenPlayerDoNotDisturbGuide, isTrue);

    await tester.tap(find.text('打开播放器专注'));
    await tester.pumpAndSettle();
    expect(find.text('专注时可以自动开启勿扰'), findsNothing);
    expect(settingsOpenCount, 1);
  });

  /// 验证 Windows 首次引导只说明手动启动，不再展示 Android 自动勿扰承诺。
  testWidgets('播放器专注首次引导说明 Windows 手动启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService service = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              // 测试按钮函数以明确 Windows 平台打开首次专注引导。
              onPressed: () => unawaited(
                showPlayerFocusDoNotDisturbGuideIfNeeded(
                  context,
                  preferencesService: service,
                  appPlatform: AppPlatform.windows,
                ),
              ),
              child: const Text('打开 Windows 专注'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开 Windows 专注'));
    await tester.pumpAndSettle();

    expect(find.text('Windows 系统专注需要手动启动'), findsOneWidget);
    expect(find.textContaining('微软单独授权'), findsOneWidget);
    expect(find.text('专注时可以自动开启勿扰'), findsNothing);
  });
}
