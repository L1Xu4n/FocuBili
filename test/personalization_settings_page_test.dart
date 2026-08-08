import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/features/profile/app_theme_mode_controller.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/app_theme_mode_service.dart';

/// 为设置页更新摘要测试提供固定的已安装版本。
class _SettingsVersionProvider implements AppVersionProvider {
  /// 返回低于测试 Release 的版本号，确保控制器进入“有更新”状态。
  @override
  Future<String> loadVersion() async => '1.2.0';
}

/// 为设置页更新摘要测试提供始终开启且不访问真实存储的偏好服务。
class _SettingsUpdatePreferences extends AppUpdatePreferencesService {
  /// 测试默认允许执行启动更新检查。
  @override
  Future<bool> loadEnabled() async => true;

  /// 测试不验证开关持久化，因此保存操作保持为空。
  @override
  Future<void> saveEnabled(bool enabled) async {}
}

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

  /// 验证检测到新版本后，设置页“关于”入口直接展示第一条简略更新内容。
  testWidgets('设置页关于入口展示新版本简略', (WidgetTester tester) async {
    final AppUpdateController updateController = AppUpdateController(
      versionProvider: _SettingsVersionProvider(),
      preferencesService: _SettingsUpdatePreferences(),
      updateService: AppUpdateService(
        releaseLoader: () async => <String, Object?>{
          'tag_name': 'v1.2.1',
          'body': '''
<!-- focubili-update-summary:start -->
- 优化平板播放器和账号卡片
<!-- focubili-update-summary:end -->
''',
        },
      ),
    );
    addTearDown(updateController.dispose);
    await updateController.initialize(checkOnStart: true);

    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateScope(
          controller: updateController,
          child: PersonalizationSettingsPage(
            focusNotificationService: FocusNotificationService(
              channel: channel,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新版本：优化平板播放器和账号卡片'), findsOneWidget);
  });

  /// 验证设置页分别保存 Wi-Fi 和移动网络清晰度，并展示向下回退说明。
  testWidgets('设置页保存两种网络默认清晰度', (WidgetTester tester) async {
    const PlaybackPreferencesService preferencesService =
        PlaybackPreferencesService();
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          preferencesService: preferencesService,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('自动选择下一档更低清晰度'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('wifi-default-quality-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高清 1080P').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-default-quality-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清晰 480P').last);
    await tester.pumpAndSettle();

    final PlaybackPreferences preferences = await preferencesService.load();
    expect(preferences.wifiDefaultQuality, PreferredPlaybackQuality.p1080);
    expect(preferences.mobileDefaultQuality, PreferredPlaybackQuality.p480);
  });

  /// 验证外观设置首次选中跟随系统，点击深色后立即更新并写入本地。
  testWidgets('设置页切换并保存全局深色模式', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppThemeModeService service = AppThemeModeService(
      preferencesLoader: () async => preferences,
    );
    final AppThemeModeController controller = AppThemeModeController(
      service: service,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeModeScope(
          controller: controller,
          child: PersonalizationSettingsPage(
            focusNotificationService: FocusNotificationService(
              channel: channel,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    SegmentedButton<ThemeMode> selector = tester.widget(
      find.byKey(const Key('theme-mode-segmented-button')),
    );
    expect(selector.selected, <ThemeMode>{ThemeMode.system});
    await tester.tap(find.byKey(const Key('theme-mode-dark-option')));
    await tester.pumpAndSettle();

    selector = tester.widget(
      find.byKey(const Key('theme-mode-segmented-button')),
    );
    expect(selector.selected, <ThemeMode>{ThemeMode.dark});
    expect(controller.mode, ThemeMode.dark);
    expect(await service.load(), ThemeMode.dark);
  });
}
