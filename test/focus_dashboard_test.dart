import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';

/// 注册首页专注台的第一版用户流程组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每项页面测试从空白本机专注记录开始。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证首页创建等待视频关联的 Pin，并仍支持续时和从继续按钮打开视频。
  testWidgets('首页专注等待关联视频并保留任务 Pin', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    int openVideoCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusDashboard(
            controller: controller,
            // 视频入口测试函数只记录调用次数，不进行真实路由跳转。
            onOpenVideo: () => openVideoCalls += 1,
            // 统计入口测试函数不进行真实路由跳转。
            onOpenStatistics: () {},
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('focus-goal-field')),
      '完成 Flutter 专注计时',
    );
    await tester.tap(find.byKey(const Key('focus-duration-45')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.ensureVisible(find.byKey(const Key('start-focus-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-focus-button')));
    await tester.pump();
    expect(find.text('请打开一个视频关联本次专注任务'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('active-focus-card')), findsOneWidget);
    expect(find.text('完成 Flutter 专注计时'), findsOneWidget);
    expect(find.text('45:00'), findsOneWidget);

    expect(find.text('等待关联视频'), findsOneWidget);
    expect(find.byKey(const Key('resume-focus-button')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('extend-focus-button')));
    await tester.tap(find.byKey(const Key('extend-focus-button')));
    await tester.pump();
    expect(
      controller.activeSession?.plannedDuration,
      const Duration(minutes: 50),
    );

    await tester.tap(find.byKey(const Key('resume-focus-button')));
    expect(openVideoCalls, 1);
    expect(find.byKey(const Key('open-video-during-focus')), findsNothing);

    await controller.endFocusEarly();
    await tester.pump();
    expect(find.byKey(const Key('focus-finished-card')), findsOneWidget);
  });

  /// 验证关联视频 Pin 会明确展示最后保存的视频时间点。
  testWidgets('首页关联视频 Pin 展示视频时间点', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '复习集合运算',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '高中数学课程',
      sourcePartCid: 123,
      sourcePartPageNumber: 6,
      sourcePartTitle: '集合',
      sourcePosition: const Duration(minutes: 12, seconds: 34),
      startImmediately: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusDashboard(
            controller: controller,
            onOpenVideo: () {},
            onOpenStatistics: () {},
          ),
        ),
      ),
    );

    expect(find.text('视频时间点 12:34'), findsOneWidget);
    expect(find.byKey(const Key('focus-last-seen-position')), findsOneWidget);
  });

  /// 验证自定义时长点取消不会触发 Flutter 依赖断言，也不会改变选中值。
  testWidgets('自定义专注时长取消保持页面稳定', (WidgetTester tester) async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FocusDashboard(
          controller: controller,
          onOpenVideo: () {},
          onOpenStatistics: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('focus-duration-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('custom-focus-minutes-field')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('focus-ready-card')), findsOneWidget);
  });
}
