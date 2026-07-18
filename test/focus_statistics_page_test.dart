import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_statistics_page.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';

/// 注册统计看板的指标展示、搜索、删除和清空记录组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每项看板测试使用空白本机偏好设置。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证看板展示指标和趋势，并能搜索及删除单条记录。
  testWidgets('专注统计看板筛选并管理本机记录', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '学习 Flutter',
      duration: const Duration(minutes: 25),
    );
    await controller.endFocusEarly();
    await controller.startFocus(
      goal: '阅读项目文档',
      duration: const Duration(minutes: 45),
    );
    await controller.endFocusEarly();
    final String latestId = controller.history.first.id;

    await tester.pumpWidget(
      MaterialApp(home: FocusStatisticsPage(controller: controller)),
    );
    await tester.pump();

    expect(find.text('专注数据'), findsOneWidget);
    expect(find.byKey(const Key('focus-total-duration')), findsOneWidget);
    expect(find.byKey(const Key('focus-trend-card')), findsOneWidget);
    expect(find.byKey(const Key('focus-trend-line-chart')), findsOneWidget);
    expect(find.text('学习 Flutter'), findsOneWidget);
    expect(find.text('阅读项目文档'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('focus-history-search')));
    await tester.enterText(
      find.byKey(const Key('focus-history-search')),
      '项目文档',
    );
    await tester.pump();
    expect(find.text('学习 Flutter'), findsNothing);
    expect(find.text('阅读项目文档'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(Key('delete-focus-history-$latestId')),
    );
    await tester.tap(find.byKey(Key('delete-focus-history-$latestId')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(controller.history, hasLength(1));
  });

  /// 验证统一清空会删除历史，但不影响页面继续正常显示空状态。
  testWidgets('专注统计看板可以清空全部历史', (WidgetTester tester) async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '待清空记录',
      duration: const Duration(minutes: 25),
    );
    await controller.endFocusEarly();

    await tester.pumpWidget(
      MaterialApp(home: FocusStatisticsPage(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('clear-focus-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '全部清空'));
    await tester.pumpAndSettle();

    expect(controller.history, isEmpty);
    await tester.scrollUntilVisible(
      find.byKey(const Key('empty-focus-history')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('empty-focus-history')), findsOneWidget);
  });

  /// 验证旧版完成记录即使缺少分P CID，只要保留 BV 号仍提供视频跳转入口。
  testWidgets('旧版完成记录保留可点击的视频入口', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '旧版已完成记录',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1LEGACY',
      startImmediately: false,
    );
    await controller.endFocusEarly();
    final String id = controller.history.single.id;

    await tester.pumpWidget(
      MaterialApp(home: FocusStatisticsPage(controller: controller)),
    );
    await tester.pump();

    final Card recordCard = tester.widget<Card>(
      find.byKey(Key('focus-history-$id')),
    );
    final InkWell record = recordCard.child! as InkWell;
    expect(record.onTap, isNotNull);
  });
}
