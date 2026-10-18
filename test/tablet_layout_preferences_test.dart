import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/layout/device_orientation_policy.dart';
import 'package:focubili/features/onboarding/first_launch_gate.dart';
import 'package:focubili/services/app_layout_preferences_service.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';

/// 使用已同意协议的合成存储验证升级引导、拒绝、幂等及启动布局快照。
void main() {
  setUp(() {
    AppLayoutPreferencesService.activeMode = AppLayoutMode.adaptive;
    SharedPreferences.setMockInitialValues({
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });
  });
  tearDown(
    () => AppLayoutPreferencesService.activeMode = AppLayoutMode.adaptive,
  );

  // 下次启动才应用新布局，播放器退出方向也遵循同一快照。
  test('竖屏保存重启加载并覆盖平板自动横屏', () async {
    const service = AppLayoutPreferencesService();
    await service.save(AppLayoutMode.portrait);
    expect(AppLayoutPreferencesService.activeMode, AppLayoutMode.adaptive);
    await service.initialize();
    expect(
      DeviceOrientationPolicy.startupOrientations(
        logicalSize: const Size(1280, 800),
        isMobile: true,
      ),
      [DeviceOrientation.portraitUp],
    );
    expect(
      DeviceOrientationPolicy.playerOrientations(
        logicalSize: const Size(1280, 800),
        isMobile: true,
      ),
      contains(DeviceOrientation.portraitUp),
    );
  });

  // 老用户已完成登录引导也应看到新布局介绍，确认后重启不重复。
  testWidgets('大屏升级接受引导仅出现一次', (tester) async {
    const gate = MaterialApp(
      home: FirstLaunchGate(
        isLargeScreenMobile: true,
        child: Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpWidget(gate);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tablet-layout-guide')), findsOneWidget);
    await tester.tap(find.text('好的，我使用横屏布局'));
    await tester.pumpAndSettle();
    expect(await const AppLayoutPreferencesService().guideShown(), isTrue);
    expect(
      await const AppLayoutPreferencesService().load(),
      AppLayoutMode.landscape,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(gate);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tablet-layout-guide')), findsNothing);
  });

  // 拒绝横屏立即保存竖屏选择并打开相关设置，返回后不再次询问。
  testWidgets('大屏拒绝横屏跳设置并保存竖屏', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FirstLaunchGate(
          isLargeScreenMobile: true,
          child: Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不，我使用竖屏布局'));
    await tester.pumpAndSettle();
    expect(
      await const AppLayoutPreferencesService().load(),
      AppLayoutMode.portrait,
    );
    expect(await const AppLayoutPreferencesService().guideShown(), isTrue);
    expect(find.text('外观与应用'), findsWidgets);
  });

  // 旧用户沿用三倍速，新增选择跨服务实例保持且坏值不污染播放器。
  test('长按倍速默认兼容并持久化', () async {
    const service = PlaybackPreferencesService();
    expect((await service.load()).longPressPlaybackSpeed, 3);
    await service.saveLongPressPlaybackSpeed(2.25);
    expect((await service.load()).longPressPlaybackSpeed, 2.25);
    await service.saveLongPressPlaybackSpeed(double.nan);
    expect((await service.load()).longPressPlaybackSpeed, 3);
  });
}
