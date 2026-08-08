import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/layout/adaptive_layout.dart';
import 'package:focubili/core/layout/adaptive_page_frame.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/profile/profile_page.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/features/search/search_page.dart';

/// 把测试窗口设置为指定逻辑尺寸，确保 MediaQuery 和布局约束使用同一宽高。
void _configureTestWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

/// 注册首页、搜索和“我的”三个一级页面的平板布局回归测试。
void main() {
  /// 每项测试清空本机偏好，避免历史数据改变卡片数量或页面状态。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 三个边距档位在临界宽度使用确定值，分屏缩放时不会落入错误分支。
  test('响应式边距在 600 和 840 断点切换', () {
    expect(AdaptiveLayout.pageHorizontalPadding(599), 12);
    expect(AdaptiveLayout.pageHorizontalPadding(600), 24);
    expect(AdaptiveLayout.pageHorizontalPadding(839), 24);
    expect(AdaptiveLayout.pageHorizontalPadding(840), 32);
  });

  /// 二级页面在超宽窗口中居中限宽，避免列表文字跨越整个平板或桌面窗口。
  testWidgets('二级页面使用统一宽屏阅读框架', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1600, 900));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AdaptivePageFrame(
            maxWidth: 900,
            child: ColoredBox(
              key: Key('adaptive-page-content'),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    );

    final Rect frameRect = tester.getRect(
      find.byKey(const Key('adaptive-page-frame')),
    );
    expect(frameRect.width, 900);
    expect(frameRect.left, 350);
    expect(frameRect.right, 1250);
  });

  /// 搜索页在平板横屏中固定条件侧栏，并把剩余空间交给结果区。
  testWidgets('平板搜索页使用条件和结果双栏', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1280, 800));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();

    final Rect sidebarRect = tester.getRect(
      find.byKey(const Key('search-workspace-sidebar')),
    );
    expect(sidebarRect.width, AdaptiveLayout.searchSidebarWidth);
    expect(sidebarRect.left, 16);
    final Rect modeSelectorRect = tester.getRect(
      find.byKey(const Key('search-mode-selector')),
    );
    expect(modeSelectorRect.width, 312);
    expect(find.byKey(const Key('search-workspace-results')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// “我的”页面在平板横屏中把账号摘要和功能网格并排展示。
  testWidgets('平板我的页面使用账号和功能双栏', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1280, 800));
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pumpAndSettle();

    final Rect accountPaneRect = tester.getRect(
      find.byKey(const Key('profile-workspace-account')),
    );
    expect(accountPaneRect.width, 300);
    expect(accountPaneRect.left, 20);
    final Rect accountCardRect = tester.getRect(
      find.byKey(const Key('profile-account-card')),
    );
    final Rect avatarRect = tester.getRect(
      find.byKey(const Key('profile-workspace-avatar')),
    );
    expect(accountCardRect.height, lessThan(360));
    expect(avatarRect.center.dx, closeTo(accountCardRect.center.dx, 1));
    expect(find.byKey(const Key('profile-workspace-grid')), findsOneWidget);
    expect(find.text('设置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 个性化设置在横屏把高频播放选项和应用维护入口分栏，避免形成一条过宽长列表。
  testWidgets('平板设置页使用播放和应用双栏', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1280, 800));
    await tester.pumpWidget(
      const MaterialApp(home: PersonalizationSettingsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-workspace-layout')), findsOneWidget);
    final Rect playbackRect = tester.getRect(
      find.byKey(const Key('settings-playback-section')),
    );
    final Rect applicationRect = tester.getRect(
      find.byKey(const Key('settings-application-section')),
    );
    expect(playbackRect.left, lessThan(applicationRect.left));
    expect(playbackRect.width, applicationRect.width);
    expect(tester.takeException(), isNull);
  });

  /// 矮横屏平板首页把学习入口和专注状态同时放在左右两栏。
  testWidgets('矮横屏首页使用学习和专注双栏', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1024, 600));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FocusDashboard(
          controller: controller,
          // 搜索入口测试函数不执行真实导航。
          onOpenVideo: () {},
          // 统计入口测试函数不执行真实导航。
          onOpenStatistics: () {},
          // 提供个人入口以启用真实首页欢迎区。
          onOpenProfile: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('focus-workspace-layout')), findsOneWidget);
    expect(find.byKey(const Key('focus-workspace-primary')), findsOneWidget);
    expect(find.byKey(const Key('focus-workspace-secondary')), findsOneWidget);
    expect(find.byKey(const Key('focus-home-hero')), findsNothing);
    expect(find.byKey(const Key('focus-ready-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 低于平板断点的矮屏也缩短欢迎区，避免首屏高度超过实际视口。
  testWidgets('矮手机首页缩短首屏且没有布局异常', (WidgetTester tester) async {
    // 首页高度读取 MediaQuery，因此这里设置测试设备视图而不只设置绘制表面。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(599, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FocusDashboard(
          controller: controller,
          // 搜索入口测试函数不执行真实导航。
          onOpenVideo: () {},
          // 统计入口测试函数不执行真实导航。
          onOpenStatistics: () {},
          // 提供个人入口以启用真实首页欢迎区。
          onOpenProfile: () {},
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('focus-home-hero'))).height,
      336,
    );
    expect(tester.takeException(), isNull);
  });
}
