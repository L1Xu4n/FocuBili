import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/dashboard_layout.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/services/dashboard_layout_service.dart';

/// 设置实际逻辑窗口，让首页断点和卡片的约束一致。
void _setWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

/// 构造真实首页编排，业务回调保持空操作，减少动画使编辑验证可以稳定结束。
Widget _homeHost(
  FocusTimerController controller,
  DashboardLayoutService service, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    // 继承真实窗口尺寸，仅修改本项测试需要的无障碍参数。
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: true, textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      body: FocusDashboard(
        controller: controller,
        layoutService: service,
        // 首页业务入口在本组测试中只验证保留，不执行路由。
        onOpenVideo: () {},
        onOpenStatistics: () {},
        onOpenProfile: () {},
        onOpenLearningList: () {},
        continueLearningCard: const Card(
          key: Key('test-continue-learning'),
          child: Padding(padding: EdgeInsets.all(20), child: Text('继续学习测试任务')),
        ),
      ),
    ),
  );
}

/// 滚动到具体操作再点击，覆盖按钮位于真实页面底部时的可达性。
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 读取首页登记表，检查页面状态变化只影响可用性而不删除编号。
EditableCardBoard _board(WidgetTester tester) =>
    tester.widget<EditableCardBoard>(find.byType(EditableCardBoard));

/// 覆盖首页接入持久化、计时隔离、响应式迁移和大字体入口。
void main() {
  /// 每项验证从独立本机偏好开始，防止上一项布局影响本项。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 首页底部可进入编辑，加回卡片追加末尾，重进后保留用户保存的最终布局。
  testWidgets('首页底部编辑排序隐藏加回并重进恢复', (tester) async {
    _setWindow(tester, const Size(430, 900));
    final controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final service = DashboardLayoutService();
    await tester.pumpWidget(_homeHost(controller, service));
    await tester.pumpAndSettle();

    final custom = find.text('自定义').last;
    expect(
      tester.getTopLeft(custom).dy,
      greaterThan(
        tester.getBottomLeft(find.byKey(const Key('home-utility-actions'))).dy,
      ),
    );
    expect(_board(tester).items, hasLength(7));
    expect(_board(tester).items.every((card) => !card.required), isTrue);
    await _tapVisible(tester, custom);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-menu-home.today_summary')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-before-home.today_summary')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-hide-home.continue_learning')),
    );
    final hidden = await service.load('home', []);
    expect(hidden.hidden, contains('home.continue_learning'));
    expect(
      hidden.order.indexOf('home.today_summary'),
      lessThan(hidden.order.indexOf('home.focus_session')),
    );
    expect(find.byKey(const Key('test-continue-learning')), findsNothing);

    await _tapVisible(tester, find.text('添加卡片'));
    await tester.tap(
      find.byKey(const ValueKey('dashboard-add-home.continue_learning')),
    );
    await tester.pumpAndSettle();
    final restored = await service.load('home', []);
    expect(restored.hidden, isEmpty);
    expect(restored.order.last, 'home.continue_learning');
    expect(
      restored.order.where((id) => id != 'home.continue_learning'),
      hidden.order.where((id) => id != 'home.continue_learning'),
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('完成'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_homeHost(controller, DashboardLayoutService()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-continue-learning')), findsOneWidget);
    expect((await service.load('home', [])).order, restored.order);
    expect(tester.takeException(), isNull);
  });

  /// 隐藏活动任务不会停表，结果提示出现、关闭和新任务开始均保留同一登记布局。
  testWidgets('首页条件专注更新保留隐藏顺序且不停止计时', (tester) async {
    _setWindow(tester, const Size(430, 900));
    DateTime now = DateTime(2026, 10, 2, 9);
    final controller = FocusTimerController(
      // 测试时钟只通过本项显式推进，确认隐藏期间仍累计时长。
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '隐藏后继续计时',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV_HOME_TEST',
      sourcePartCid: 1,
    );
    final service = DashboardLayoutService();
    await tester.pumpWidget(_homeHost(controller, service));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('自定义').last);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-hide-home.focus_session')),
    );
    final saved = await service.load('home', []);
    now = now.add(const Duration(minutes: 1));
    expect(controller.activeSession?.status, FocusSessionStatus.running);
    expect(controller.elapsedDuration, const Duration(minutes: 1));

    await controller.endFocusEarly();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('focus-finished-card')), findsOneWidget);
    expect(find.byKey(const Key('focus-ready-card')), findsNothing);
    controller.dismissLastFinishedSession();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('focus-finished-card')), findsNothing);
    expect(
      _board(
        tester,
      ).items.singleWhere((card) => card.id == 'home.focus_finished').available,
      isFalse,
    );
    await controller.startFocus(
      goal: '第二次专注',
      duration: const Duration(minutes: 25),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('active-focus-card')), findsNothing);
    final restored = await service.load('home', []);
    expect(restored.order, saved.order);
    expect(restored.hidden, saved.hidden);
    expect(_board(tester).items, hasLength(7));
    expect(tester.takeException(), isNull);
  });

  /// 手机进入编辑后切宽屏，卡片共用两列区域；再切回手机仍保持编辑。
  testWidgets('首页窗口切换保持编辑且全部卡片同区跨行布局', (tester) async {
    _setWindow(tester, const Size(430, 900));
    final controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(_homeHost(controller, DashboardLayoutService()));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('自定义').last);
    tester.view.physicalSize = const Size(1280, 600);
    await tester.pumpAndSettle();
    expect(find.byType(EditableCardBoard), findsOneWidget);
    expect(_board(tester).columnCount, 2);
    expect(find.text('完成'), findsOneWidget);
    final primary = find.byKey(const Key('focus-workspace-primary'));
    expect(
      find.descendant(
        of: primary,
        matching: find.byKey(const Key('test-continue-learning')),
      ),
      findsNothing,
    );
    final continueRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-home.continue_learning')),
    );
    final focusRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-home.focus_session')),
    );
    expect(continueRect.top, focusRect.top);
    expect(continueRect.right, lessThan(focusRect.left));
    await _tapVisible(tester, find.text('完成'));
    await _tapVisible(tester, find.text('自定义').last);
    tester.view.physicalSize = const Size(430, 900);
    await tester.pumpAndSettle();
    expect(_board(tester).columnCount, 1);
    expect(find.text('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 全部隐藏时底部入口仍可达，大字体矮屏欢迎区允许滚动到搜索动作。
  testWidgets('大字体矮首页保留搜索与空布局添加入口', (tester) async {
    _setWindow(tester, const Size(320, 430));
    final controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final service = DashboardLayoutService();
    const ids = <String>[
      'home.continue_learning',
      'home.focus_finished',
      'home.focus_session',
      'home.today_summary',
      'home.recent_history',
      'home.quick_actions',
    ];
    await service.save('home', DashboardLayout(order: ids, hidden: ids));
    await tester.pumpWidget(
      _homeHost(controller, service, textScaler: const TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('focus-home-hero'))).height,
      greaterThan(366),
    );
    await tester.ensureVisible(find.byKey(const Key('home-start-search')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('home-start-search')).hitTestable(),
      findsOneWidget,
    );
    await _tapVisible(tester, find.text('自定义').last);
    await _tapVisible(tester, find.text('添加卡片'));
    expect(
      find.byKey(const ValueKey('dashboard-add-home.continue_learning')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
