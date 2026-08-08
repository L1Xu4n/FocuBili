///
/// 把高密度弹幕的原始时间点整理成连续发射时间，避免同一批文字挤成只占半屏的竖墙。
///
/// 调度器只处理视频时间，不依赖 Flutter 或 Android，后续 Windows 播放器可以直接复用。
class DanmakuLaunchScheduler {
  /// 创建发射调度器；完整穿屏时长除以最大可见数量得到相邻弹幕的最小发射间隔。
  DanmakuLaunchScheduler({
    required Duration travelDuration,
    required int maximumVisibleEntries,
    this.maximumDelay = const Duration(seconds: 2),
  }) : minimumSpacing = spacingFor(
         travelDuration: travelDuration,
         maximumVisibleEntries: maximumVisibleEntries,
       );

  final Duration minimumSpacing;
  final Duration maximumDelay;
  Duration? _lastCommittedStart;

  /// 为一条弹幕提出最早可用的右侧发射时间；排队超过上限时返回空值，让调用方在画布外丢弃。
  Duration? candidateFor(Duration requestedStart) {
    final Duration safeRequested = requestedStart.isNegative
        ? Duration.zero
        : requestedStart;
    final Duration? lastStart = _lastCommittedStart;
    final Duration candidate = lastStart == null
        ? safeRequested
        : _laterOf(safeRequested, lastStart + minimumSpacing);
    if (candidate - safeRequested > maximumDelay) {
      return null;
    }
    return candidate;
  }

  /// 只在弹幕成功取得车道后提交候选时间，车道冲突导致的丢弃不会制造额外空档。
  void commit(Duration start) {
    _lastCommittedStart = start.isNegative ? Duration.zero : start;
  }

  /// 根据完整穿屏时长和容量计算全局最小间隔，保证画布同时可见的条目不会长期超过上限。
  static Duration spacingFor({
    required Duration travelDuration,
    required int maximumVisibleEntries,
  }) {
    final Duration safeTravelDuration = travelDuration > Duration.zero
        ? travelDuration
        : const Duration(seconds: 9);
    final int safeMaximum = maximumVisibleEntries.clamp(1, 1000).toInt();
    return Duration(
      microseconds: (safeTravelDuration.inMicroseconds / safeMaximum).ceil(),
    );
  }

  /// 返回两个视频时间中较晚的一个，避免依赖平台时钟或可变状态。
  static Duration _laterOf(Duration left, Duration right) {
    return left >= right ? left : right;
  }
}
