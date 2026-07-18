import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/services/focus_session_service.dart';

/// 提供可手动推进的本地时间，测试无需真实等待几十分钟。
class _MutableFocusClock {
  /// 创建以指定时刻为起点的测试时钟。
  _MutableFocusClock(this.value);

  DateTime value;

  /// 返回当前测试时刻，签名可直接注入专注控制器。
  DateTime call() => value;

  /// 向前推进指定时长，模拟后台、锁屏或用户持续专注。
  void advance(Duration duration) {
    value = value.add(duration);
  }
}

/// 注册专注控制器的开始、恢复、后台完成和目标限制测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每项测试使用空白内存偏好设置，避免专注记录互相影响。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证暂停期间剩余时间不变，继续后才重新消耗计划时长。
  test('控制器开始暂停和继续专注', () async {
    final _MutableFocusClock clock = _MutableFocusClock(
      DateTime(2026, 7, 18, 9),
    );
    final FocusTimerController controller = FocusTimerController(
      clock: clock.call,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(
      await controller.startFocus(
        goal: '学习状态管理',
        duration: const Duration(minutes: 25),
        sourceBvid: 'BV1TEST',
        sourceVideoTitle: '状态管理课程',
        sourcePartCid: 100,
        sourcePartPageNumber: 1,
        sourcePartTitle: '第一讲',
      ),
      isTrue,
    );
    await controller.updatePlaybackState(
      bvid: 'BV1TEST',
      partCid: 100,
      isPlaying: true,
    );
    clock.advance(const Duration(minutes: 10));
    expect(controller.remainingDuration, const Duration(minutes: 15));

    await controller.pauseFocus();
    clock.advance(const Duration(minutes: 20));
    expect(controller.remainingDuration, const Duration(minutes: 15));

    await controller.resumeFocus();
    clock.advance(const Duration(minutes: 5));
    expect(controller.remainingDuration, const Duration(minutes: 10));
  });

  /// 验证意外关闭后不会把后台时间算作播放，并自动记录“专注被打断”。
  test('意外关闭后恢复为暂停任务并记录打断', () async {
    final _MutableFocusClock clock = _MutableFocusClock(
      DateTime(2026, 7, 18, 10),
    );
    final FocusSessionService service = FocusSessionService();
    final FocusTimerController firstController = FocusTimerController(
      service: service,
      clock: clock.call,
      tickInterval: const Duration(days: 1),
    );
    await firstController.initialize();
    await firstController.startFocus(
      goal: '阅读文档',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '文档视频',
      sourcePartCid: 200,
      sourcePartPageNumber: 1,
      sourcePartTitle: '正文',
    );
    firstController.dispose();

    clock.advance(const Duration(minutes: 30));
    final FocusTimerController restoredController = FocusTimerController(
      service: service,
      clock: clock.call,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(restoredController.dispose);
    await restoredController.initialize();

    expect(restoredController.activeSession, isNotNull);
    expect(restoredController.history, isEmpty);
    expect(restoredController.activeSession?.status, FocusSessionStatus.paused);
    expect(restoredController.activeSession?.latestInterruptionReason, '专注被打断');
    expect(restoredController.todayCompletedCount(), 0);
    expect(restoredController.todayFocusedDuration(), Duration.zero);
  });

  /// 验证视频暂停、切换到其他分P和手动打断期间都不会增加专注时长。
  test('只有关联分P实际播放时才累计专注', () async {
    final _MutableFocusClock clock = _MutableFocusClock(
      DateTime(2026, 7, 18, 11),
    );
    final FocusTimerController controller = FocusTimerController(
      clock: clock.call,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '只统计播放时间',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '课程',
      sourcePartCid: 300,
      sourcePartPageNumber: 1,
      sourcePartTitle: '第一P',
      startImmediately: false,
    );

    clock.advance(const Duration(minutes: 3));
    expect(controller.elapsedDuration, Duration.zero);
    await controller.updatePlaybackState(
      bvid: 'BV1TEST',
      partCid: 300,
      isPlaying: true,
    );
    clock.advance(const Duration(minutes: 4));
    expect(controller.elapsedDuration, const Duration(minutes: 4));
    await controller.updatePlaybackState(
      bvid: 'BV1TEST',
      partCid: 300,
      isPlaying: false,
    );
    clock.advance(const Duration(minutes: 6));
    expect(controller.elapsedDuration, const Duration(minutes: 4));
    await controller.updatePlaybackState(
      bvid: 'BV1TEST',
      partCid: 301,
      isPlaying: true,
    );
    clock.advance(const Duration(minutes: 2));
    expect(controller.elapsedDuration, const Duration(minutes: 4));
  });

  /// 验证首页“今日专注”只计算午夜后的部分，不把整段跨日任务算到今天。
  test('今日专注时长正确拆分跨午夜活动任务', () async {
    final _MutableFocusClock clock = _MutableFocusClock(
      DateTime(2026, 7, 18, 23, 50),
    );
    final FocusTimerController controller = FocusTimerController(
      clock: clock.call,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '跨午夜学习',
      duration: const Duration(hours: 1),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '夜间课程',
      sourcePartCid: 302,
      sourcePartPageNumber: 1,
      sourcePartTitle: '第一P',
    );
    clock.advance(const Duration(minutes: 20));

    expect(controller.elapsedDuration, const Duration(minutes: 20));
    expect(controller.todayFocusedDuration(), const Duration(minutes: 10));
  });

  /// 验证超长目标在控制器入口被安全限制为 60 个码点。
  test('控制器限制专注目标最大长度', () async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.startFocus(
      goal: List<String>.filled(80, '学').join(),
      duration: const Duration(minutes: 25),
    );

    expect(controller.activeSession?.goal.runes.length, 60);
  });

  /// 验证活动专注可续时，结束后能删除单条或清空历史记录。
  test('控制器支持续时和统一历史管理', () async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '播放器内学习',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '测试视频',
      sourcePartCid: 123,
      sourcePartPageNumber: 1,
      sourcePartTitle: '第一P',
    );

    expect(await controller.extendFocus(const Duration(minutes: 5)), isTrue);
    expect(
      controller.activeSession?.plannedDuration,
      const Duration(minutes: 30),
    );
    await controller.endFocusEarly();
    final String id = controller.history.single.id;
    expect(controller.history.single.sourceBvid, 'BV1TEST');

    await controller.deleteHistoryEntry(id);
    expect(controller.history, isEmpty);

    await controller.startFocus(
      goal: '第二次专注',
      duration: const Duration(minutes: 25),
    );
    await controller.endFocusEarly();
    await controller.clearHistory();
    expect(controller.history, isEmpty);
    expect(controller.activeSession, isNull);
  });

  /// 验证刚结束记录仍可写入播放器结束瞬间的画面和真实时间点。
  test('控制器保存已结束记录的最后视频位置', () async {
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '完成课程',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '测试课程',
      sourcePartCid: 456,
      sourcePartPageNumber: 2,
      sourcePartTitle: '第二讲',
    );
    await controller.endFocusEarly();
    final String id = controller.history.single.id;

    await controller.updateFinishedLastSeen(
      sessionId: id,
      framePath: 'C:\\focus-finished.jpg',
      position: const Duration(minutes: 15),
    );

    expect(
      controller.history.single.sourcePosition,
      const Duration(minutes: 15),
    );
    expect(controller.history.single.sourceFramePath, 'C:\\focus-finished.jpg');
    expect(
      controller.lastFinishedSession?.sourcePosition,
      const Duration(minutes: 15),
    );
  });
}
