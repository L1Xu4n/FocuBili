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
import 'package:focubili/services/bilibili_auth_service.dart';

/// 平板布局验证使用确定的未登录状态，避免账号读取启动真实网络等待。
class _SignedOutAccountFixture extends BilibiliAuthService {
  /// 直接返回未登录状态，保留个人中心真实的账号摘要布局。
  @override
  Future<BilibiliSessionState> loadCurrentSession() async =>
      const BilibiliSessionState.signedOut();
}

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

  /// 个人中心账号摘要全宽显示，功能卡按实际可用宽度排列为三列。
  testWidgets('平板我的页面使用统一可编辑卡片区域', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1280, 800));
    await tester.pumpWidget(
      MaterialApp(home: ProfilePage(authService: _SignedOutAccountFixture())),
    );
    await tester.pumpAndSettle();

    final Rect accountCardRect = tester.getRect(
      find.byKey(const Key('profile-account-card')),
    );
    final Rect historyRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-watch-history')),
    );
    final Rect offlineRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-offline-videos')),
    );
    final Rect favoritesRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-app-favorites')),
    );
    expect(accountCardRect.width, greaterThan(1200));
    expect(accountCardRect.height, lessThan(360));
    expect(historyRect.top, offlineRect.top);
    expect(offlineRect.top, favoritesRect.top);
    expect(historyRect.width, closeTo((1240 - 32) / 3, 1));
    expect(find.byKey(const Key('profile-card-board')), findsOneWidget);
    expect(find.text('设置').hitTestable(), findsOneWidget);
    expect(find.text('自定义').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 个性化设置在横屏仍使用清晰的分类首页，并只展示进入的单个二级分类。
  testWidgets('平板设置页使用分类首页和单个二级页面', (WidgetTester tester) async {
    _configureTestWindow(tester, const Size(1280, 800));
    await tester.pumpWidget(
      const MaterialApp(home: PersonalizationSettingsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-overview-list')), findsOneWidget);
    expect(
      find.byKey(const Key('open-account-privacy-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('open-playback-focus-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('open-appearance-application-settings')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('open-playback-focus-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-playback-section')), findsOneWidget);
    expect(find.byKey(const Key('settings-application-section')), findsNothing);
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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('focus-home-hero'))).height,
      336,
    );
    expect(tester.takeException(), isNull);
  });
}
