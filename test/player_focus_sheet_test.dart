import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/player_focus_sheet.dart';

/// 注册播放器专注面板的当前分P开始、来源记录和续时组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每项播放器专注测试使用空白本机偏好设置。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证从播放器按当前分P时长开始，并保存视频来源和增加五分钟。
  testWidgets('播放器专注面板记录当前分P并支持续时', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerFocusSheet(
            controller: controller,
            defaultGoal: '看完第二P',
            partRemainingDuration: const Duration(minutes: 12),
            bvid: 'BV1TEST',
            videoTitle: 'Flutter 入门',
            partCid: 456,
            partPageNumber: 2,
            partTitle: '状态管理',
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('player-focus-current-part')));
    await tester.tap(find.byKey(const Key('start-player-focus')));
    await tester.pump();

    expect(
      controller.activeSession?.plannedDuration,
      const Duration(minutes: 12),
    );
    expect(controller.activeSession?.sourceBvid, 'BV1TEST');
    expect(controller.activeSession?.sourcePartPageNumber, 2);
    expect(find.byKey(const Key('player-focus-active')), findsOneWidget);

    await tester.tap(find.byKey(const Key('extend-player-focus')));
    await tester.pump();
    expect(
      controller.activeSession?.plannedDuration,
      const Duration(minutes: 17),
    );

    await controller.endFocusEarly();
    await tester.pump();
  });

  /// 验证播放器面板同样支持自定义时长，取消弹窗不会破坏面板布局。
  testWidgets('播放器专注面板自定义时长可安全取消', (WidgetTester tester) async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerFocusSheet(
            controller: controller,
            defaultGoal: '测试自定义',
            partRemainingDuration: const Duration(minutes: 20),
            bvid: 'BV1TEST',
            videoTitle: '测试视频',
            partCid: 456,
            partPageNumber: 1,
            partTitle: '第一P',
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('player-focus-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('player-focus-ready')), findsOneWidget);
  });
}
