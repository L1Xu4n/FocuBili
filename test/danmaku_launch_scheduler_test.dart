import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/danmaku_launch_scheduler.dart';

/// 验证高密度弹幕会连续排队、限制积压，并保持可见数量上限。
void main() {
  /// 同时到达的内容按 150ms 间隔连续发射，不再在同一横坐标形成竖墙。
  test('九秒轨迹和六十条上限生成一百五十毫秒发射间隔', () {
    final DanmakuLaunchScheduler scheduler = DanmakuLaunchScheduler(
      travelDuration: const Duration(seconds: 9),
      maximumVisibleEntries: 60,
    );
    final List<Duration> starts = <Duration>[];

    for (int index = 0; index < 4; index += 1) {
      final Duration? candidate = scheduler.candidateFor(
        const Duration(seconds: 10),
      );
      expect(candidate, isNotNull);
      scheduler.commit(candidate!);
      starts.add(candidate);
    }

    expect(starts, <Duration>[
      const Duration(seconds: 10),
      const Duration(seconds: 10, milliseconds: 150),
      const Duration(seconds: 10, milliseconds: 300),
      const Duration(seconds: 10, milliseconds: 450),
    ]);
  });

  /// 超过两秒的积压直接在画布外丢弃，防止旧内容延迟很久后再次冒出。
  test('高密度排队超过两秒后停止接纳', () {
    final DanmakuLaunchScheduler scheduler = DanmakuLaunchScheduler(
      travelDuration: const Duration(seconds: 9),
      maximumVisibleEntries: 60,
    );
    int accepted = 0;

    for (int index = 0; index < 30; index += 1) {
      final Duration? candidate = scheduler.candidateFor(Duration.zero);
      if (candidate == null) {
        continue;
      }
      scheduler.commit(candidate);
      accepted += 1;
    }

    expect(accepted, 14);
    expect(scheduler.candidateFor(Duration.zero), isNull);
  });

  /// 车道拒绝候选时间时不提交，下一条仍可复用同一个发射位置而不会产生空洞。
  test('未提交的候选时间不会推进调度器', () {
    final DanmakuLaunchScheduler scheduler = DanmakuLaunchScheduler(
      travelDuration: const Duration(seconds: 9),
      maximumVisibleEntries: 60,
    );
    final Duration first = scheduler.candidateFor(Duration.zero)!;
    scheduler.commit(first);

    final Duration rejected = scheduler.candidateFor(Duration.zero)!;
    final Duration next = scheduler.candidateFor(Duration.zero)!;

    expect(rejected, const Duration(milliseconds: 150));
    expect(next, rejected);
  });

  /// 损坏的时长和容量会安全归一化，不会出现零间隔或除零错误。
  test('异常配置仍返回正数间隔', () {
    expect(
      DanmakuLaunchScheduler.spacingFor(
        travelDuration: Duration.zero,
        maximumVisibleEntries: 0,
      ),
      const Duration(seconds: 9),
    );
  });
}
