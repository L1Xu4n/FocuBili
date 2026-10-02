import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/features/profile/app_theme_mode_controller.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/app_theme_mode_service.dart';
import 'package:focubili/services/windows_clipboard_link_service.dart';
import 'package:focubili/platform/app_platform.dart';

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

/// 模拟笔记标记开关保存失败，检查界面是否恢复原值。
class _FailNoteMarkerPreferences extends PlaybackPreferencesService {
  /// 拒绝写入用于覆盖设置页失败回滚分支。
  @override
  Future<void> saveShowNoteTimeMarkers(bool enabled) async {
    throw StateError('测试写入失败');
  }
}

/// 从设置首页进入指定分类，并等待二级页面完成重建。
Future<void> _openSettingsLevel(WidgetTester tester, Key entryKey) async {
  await tester.tap(find.byKey(entryKey));
  await tester.pumpAndSettle();
}

/// 注册设置页专注勿扰开关、说明和系统权限入口测试。
void main() {
  /// 笔记开关可以搜索、即时保存；失败后保留原值。
  for (final fail in [false, true]) {
    testWidgets('笔记标记开关搜索并${fail ? '失败回滚' : '立即保存'}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalizationSettingsPage(
            appPlatform: AppPlatform.windows,
            preferencesService: fail
                ? _FailNoteMarkerPreferences()
                : const PlaybackPreferencesService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('settings-search')),
        '笔记时间标记',
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('show-note-time-markers'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, fail);
      expect(
        (await const PlaybackPreferencesService().load()).showNoteTimeMarkers,
        fail,
      );
      if (fail) expect(find.text('设置保存失败，请重试。'), findsOneWidget);
    });
  }

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
          appPlatform: AppPlatform.android,
          focusPreferencesService: preferencesService,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openSettingsLevel(
      tester,
      const Key('open-appearance-application-settings'),
    );
    expect(find.byKey(const Key('open-android-permissions')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-level-back-button')));
    await tester.pumpAndSettle();
    await _openSettingsLevel(tester, const Key('open-playback-focus-settings'));
    final Finder toggle = find.byKey(const Key('enable-focus-do-not-disturb'));
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
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

  /// Shows the mobile reset description and persists the default-on gesture switch immediately.
  testWidgets('移动端双指缩放开关默认开启并说明双击复位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.android,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openSettingsLevel(tester, const Key('open-playback-focus-settings'));
    final toggle = find.byKey(const Key('enable-two-finger-video-transform'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('全屏时双指拖动、缩放画面；双指双击恢复画面。'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      (await const PlaybackPreferencesService().load())
          .enableTwoFingerVideoTransform,
      isFalse,
    );
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

    await _openSettingsLevel(
      tester,
      const Key('open-appearance-application-settings'),
    );
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

    await _openSettingsLevel(tester, const Key('open-playback-focus-settings'));
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

    await _openSettingsLevel(
      tester,
      const Key('open-appearance-application-settings'),
    );
    SegmentedButton<ThemeMode> selector = tester.widget(
      find.byKey(const Key('theme-mode-segmented-button')),
    );
    expect(selector.selected, <ThemeMode>{ThemeMode.system});
    await tester.ensureVisible(find.byKey(const Key('theme-mode-dark-option')));
    await tester.tap(find.byKey(const Key('theme-mode-dark-option')));
    await tester.pumpAndSettle();

    selector = tester.widget(
      find.byKey(const Key('theme-mode-segmented-button')),
    );
    expect(selector.selected, <ThemeMode>{ThemeMode.dark});
    expect(controller.mode, ThemeMode.dark);
    expect(await service.load(), ThemeMode.dark);
  });

  /// 验证 Windows 设置页显示剪贴板检测开关，并将用户选择保存到本机。
  testWidgets('Windows 设置页保存剪贴板链接检测开关', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WindowsClipboardLinkPreferencesService service =
        WindowsClipboardLinkPreferencesService(
          preferencesLoader: () async => preferences,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.windows,
          windowsClipboardPreferencesService: service,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openSettingsLevel(
      tester,
      const Key('open-account-privacy-settings'),
    );
    final Finder toggle = find.byKey(
      const Key('enable-windows-clipboard-link-detection'),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(await service.loadEnabled(), isTrue);
  });

  /// 验证 Android 设置页也提供剪贴板链接检测开关并可保存。
  testWidgets('Android 设置页保存剪贴板链接检测开关', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WindowsClipboardLinkPreferencesService service =
        WindowsClipboardLinkPreferencesService(
          preferencesLoader: () async => preferences,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.android,
          windowsClipboardPreferencesService: service,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openSettingsLevel(
      tester,
      const Key('open-account-privacy-settings'),
    );

    final Finder toggle = find.byKey(
      const Key('enable-windows-clipboard-link-detection'),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(await service.loadEnabled(), isTrue);
  });

  /// 验证账号与隐私二级页使用要求的默认值，并把三个行为开关独立保存。
  testWidgets('账号与隐私设置使用默认值并可保存', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppBehaviorPreferencesService behaviorService =
        AppBehaviorPreferencesService(
          preferencesLoader: () async => preferences,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.android,
          behaviorPreferencesService: behaviorService,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-overview-list')), findsOneWidget);
    await _openSettingsLevel(
      tester,
      const Key('open-account-privacy-settings'),
    );

    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('enable-account-read-only')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('enable-search-history')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('enable-watch-history')))
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('enable-account-read-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enable-search-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enable-watch-history')));
    await tester.pumpAndSettle();

    expect(await behaviorService.loadAccountReadOnly(), isFalse);
    expect(await behaviorService.loadSearchHistoryEnabled(), isFalse);
    expect(await behaviorService.loadWatchHistoryEnabled(), isFalse);
  });

  /// 验证 Windows 开关只保存“开始时提醒”，不会继续声称能够自动修改系统专注。
  testWidgets('Windows 设置页如实说明系统专注需要手动启动', (WidgetTester tester) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService preferencesService = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.windows,
          focusPreferencesService: preferencesService,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openSettingsLevel(tester, const Key('open-playback-focus-settings'));
    final Finder toggle = find.byKey(const Key('enable-focus-do-not-disturb'));
    expect(toggle, findsOneWidget);
    expect(find.text('开始时提醒开启 Windows 系统专注'), findsOneWidget);
    expect(find.textContaining('自动切换'), findsNothing);
    // 新设置增加卡片高度，按用户滚动到可见范围后的实际点击验证。
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Windows 系统专注需要手动启动'), findsOneWidget);
    expect(find.textContaining('受限功能'), findsOneWidget);
    expect((await preferencesService.load()).enableDoNotDisturb, isTrue);
  });

  /// Searches actionable settings on the first level without retaining the removed filter UI.
  testWidgets('设置首页搜索具体项目并直接修改倍速', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('settings-search')), '倍速');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playback-speeds-preference')), findsOneWidget);
    expect(find.byKey(const Key('playback-source-preference')), findsNothing);
    expect(find.byKey(const Key('enable-play-count-filter')), findsNothing);
    await tester.tap(find.byKey(const Key('playback-speeds-preference')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('custom-playback-speed-input')),
      '4.5',
    );
    await tester.tap(find.byKey(const Key('add-playback-speed')));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(
      (await const PlaybackPreferencesService().load()).playbackSpeeds,
      contains(4.5),
    );
    await tester.enterText(
      find.byKey(const Key('settings-search')),
      'not-a-setting',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的设置项目'), findsOneWidget);
  });

  /// 新增项目可按标题、说明和别名搜索，平台隐藏项目不会留下空白结果。
  testWidgets('设置自动搜索新增项目并过滤平台不可用项目', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalizationSettingsPage(
          appPlatform: AppPlatform.windows,
          focusNotificationService: FocusNotificationService(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final (query, key) in <(String, Key)>[
      ('自定义双击触发区', const Key('double-tap-regions-preference')),
      ('双击 区域', const Key('double-tap-regions-preference')),
      ('分割线', const Key('double-tap-regions-preference')),
      ('播放暂停动画', const Key('show-playback-action-animation')),
      ('画面中央短暂', const Key('show-playback-action-animation')),
      ('控制栏', const Key('player-control-size-preference')),
      ('PLAYBACK BAR', const Key('player-control-size-preference')),
      ('主题颜色', const Key('theme-color-setting')),
    ]) {
      await tester.enterText(find.byKey(const Key('settings-search')), query);
      await tester.pumpAndSettle();
      expect(find.byKey(key), findsOneWidget, reason: query);
      expect(find.text('没有匹配的设置项目'), findsNothing, reason: query);
    }
    await tester.enterText(find.byKey(const Key('settings-search')), '双指缩放');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('enable-two-finger-video-transform')),
      findsNothing,
    );
    expect(find.text('没有匹配的设置项目'), findsOneWidget);
  });
}
