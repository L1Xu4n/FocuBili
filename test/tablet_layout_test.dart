import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/layout/adaptive_layout.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/profile/profile_page.dart';
import 'package:focubili/features/search/search_page.dart';

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

  /// 搜索主体和模式选择器在平板横屏中居中限宽，不再横跨整个屏幕。
  testWidgets('平板搜索页限制内容和模式选择器宽度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();

    final Rect searchContentRect = tester.getRect(
      find.byKey(const Key('search-adaptive-content')),
    );
    expect(searchContentRect.width, AdaptiveLayout.searchContentMaxWidth);
    expect(searchContentRect.left, 160);
    expect(searchContentRect.right, 1120);
    final Rect modeSelectorRect = tester.getRect(
      find.byKey(const Key('search-mode-selector')),
    );
    expect(modeSelectorRect.width, 480);
    expect(modeSelectorRect.center.dx, 640);
    expect(tester.takeException(), isNull);
  });

  /// “我的”页面账号卡在平板横屏中保持紧凑行长，入口仍可正常滚动。
  testWidgets('平板我的页面限制账号卡宽度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pumpAndSettle();

    final Finder accountCard = find
        .descendant(
          of: find.byKey(const Key('profile-adaptive-content')),
          matching: find.byType(Card),
        )
        .first;
    final Rect accountCardRect = tester.getRect(accountCard);
    expect(accountCardRect.width, AdaptiveLayout.profileContentMaxWidth);
    expect(accountCardRect.left, 280);
    expect(accountCardRect.right, 1000);
    await tester.ensureVisible(find.text('设置'));
    await tester.pump();
    expect(find.text('设置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 矮横屏平板缩短首页欢迎区并限制卡片宽度，首张卡片仍能滚动显示。
  testWidgets('矮横屏首页缩短首屏并限制专注卡片宽度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
      536,
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -560));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('focus-ready-card')), findsOneWidget);
    final Rect readyCardRect = tester.getRect(
      find.byKey(const Key('focus-ready-card')),
    );
    expect(readyCardRect.width, AdaptiveLayout.homeContentMaxWidth);
    expect(readyCardRect.left, 92);
    expect(readyCardRect.right, 932);
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
