import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/focus/focus_video_launcher.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/video_preview.dart';

/// 注册专注记录转换为播放器启动参数的回归测试。
void main() {
  /// 验证零时间点不会覆盖原生观看历史，旧记录缺少 CID 也能打开默认分P。
  test('零位置专注记录保留原生观看历史恢复', () {
    final FocusSession session = FocusSession.start(
      id: 'focus-zero',
      goal: '继续课程',
      plannedDuration: const Duration(minutes: 25),
      now: DateTime(2026, 7, 18, 21),
      sourceBvid: 'BV1TEST',
      startImmediately: false,
    );

    final PlayerPage page = FocusVideoLauncher.buildPlayerPage(
      VideoPreview.placeholder(),
      session,
    );

    expect(page.initialPosition, isNull);
    expect(page.initialPartCid, isNull);
    expect(page.initialPositionSource, PlayerInitialPositionSource.focus);
  });

  /// 验证有真实保存进度时专注记录仍会精确恢复到该分P和时间点。
  test('专注记录保留非零分P位置', () {
    final FocusSession session = FocusSession.start(
      id: 'focus-position',
      goal: '继续课程',
      plannedDuration: const Duration(minutes: 25),
      now: DateTime(2026, 7, 18, 21),
      sourceBvid: 'BV1TEST',
      sourcePartCid: 789,
      sourcePosition: const Duration(minutes: 15),
      startImmediately: false,
    );

    final PlayerPage page = FocusVideoLauncher.buildPlayerPage(
      VideoPreview.placeholder(),
      session,
    );

    expect(page.initialPartCid, 789);
    expect(page.initialPosition, const Duration(minutes: 15));
  });
}
