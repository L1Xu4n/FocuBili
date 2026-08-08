part of 'player_page.dart';

const int _maximumVisibleDanmakuEntries = 60;

/// 保存一条滚动车道最后加入弹幕的时间和宽度，供后续条目执行追尾碰撞判断。
class _DanmakuScrollingLaneState {
  /// 创建车道尾部状态；时间使用视频毫秒，不受设备刷新率影响。
  const _DanmakuScrollingLaneState({
    required this.startedAt,
    required this.textWidth,
  });

  final int startedAt;
  final double textWidth;
}

/// 保存一条已经完成车道规划和文字布局的弹幕，逐帧绘制不再重新排版文字。
class _DanmakuLayoutItem {
  /// 创建包含原始弹幕、物理车道和两层文字画笔的只读渲染项。
  const _DanmakuLayoutItem({
    required this.entry,
    required this.startsAt,
    required this.lane,
    required this.textWidth,
    required this.textHeight,
    required this.fillPainter,
    required this.outlinePainter,
  });

  final DanmakuEntry entry;
  final Duration startsAt;
  final int lane;
  final double textWidth;
  final double textHeight;
  final TextPainter fillPainter;
  final TextPainter? outlinePainter;

  /// 释放 TextPainter 持有的段落缓存，切换分P、尺寸或样式后不会持续占用旧画布资源。
  void dispose() {
    fillPainter.dispose();
    outlinePainter?.dispose();
  }
}

/// 缓存当前弹幕片段在指定画布尺寸下的车道与文字布局，减少逐帧 CPU 和内存分配。
class _DanmakuLanePlanner {
  List<DanmakuEntry>? _cachedEntries;
  Size? _cachedSize;
  DanmakuPreferences? _cachedPreferences;
  List<_DanmakuLayoutItem> _cachedItems = const <_DanmakuLayoutItem>[];

  /// 清除旧分P、旧尺寸或旧样式的规划结果，并释放全部段落缓存。
  void clear() {
    _disposeCachedItems();
    _cachedEntries = null;
    _cachedSize = null;
    _cachedPreferences = null;
    _cachedItems = const <_DanmakuLayoutItem>[];
  }

  /// 释放当前缓存里的文字段落；重复调用也保持安全。
  void _disposeCachedItems() {
    for (final _DanmakuLayoutItem item in _cachedItems) {
      item.dispose();
    }
  }

  /// 按时间顺序规划弹幕车道；没有安全车道时丢弃该条，默认不让文字互相覆盖。
  List<_DanmakuLayoutItem> plan(
    List<DanmakuEntry> entries,
    Size size,
    DanmakuPreferences preferences,
  ) {
    if (identical(_cachedEntries, entries) &&
        _cachedSize == size &&
        identical(_cachedPreferences, preferences)) {
      return _cachedItems;
    }
    _disposeCachedItems();
    final double laneHeight = preferences.fontSize * 1.55;
    final double displayHeight = size.height * preferences.displayArea;
    final int laneCount = (displayHeight / laneHeight)
        .floor()
        .clamp(1, preferences.laneCount)
        .toInt();
    final List<_DanmakuScrollingLaneState?> scrollingLanes =
        List<_DanmakuScrollingLaneState?>.filled(laneCount, null);
    final int travelDurationMilliseconds =
        (preferences.scrollDurationSeconds * 1000).round();
    final DanmakuLaunchScheduler launchScheduler = DanmakuLaunchScheduler(
      travelDuration: Duration(milliseconds: travelDurationMilliseconds),
      maximumVisibleEntries: _maximumVisibleDanmakuEntries,
    );
    final List<DanmakuEntry> ordered = List<DanmakuEntry>.from(entries)
      ..sort(
        (DanmakuEntry left, DanmakuEntry right) =>
            left.position.compareTo(right.position),
      );
    final List<_DanmakuLayoutItem> items = <_DanmakuLayoutItem>[];
    for (final DanmakuEntry entry in ordered) {
      final _DanmakuTextLayout textLayout = _buildTextLayout(
        entry,
        size.width,
        preferences,
      );
      final Duration? scheduledStart = launchScheduler.candidateFor(
        entry.position,
      );
      if (scheduledStart == null) {
        textLayout.dispose();
        continue;
      }
      final int startedAt = scheduledStart.inMilliseconds;
      final int preferredLane =
          (startedAt ~/ 100 + entry.content.hashCode).abs() % laneCount;
      // 顶部、底部和反向类型只保留为筛选来源，展示时统一进入右到左滚动车道。
      final int lane = _findScrollingLane(
        laneStates: scrollingLanes,
        startedAt: startedAt,
        newTextWidth: textLayout.width,
        canvasWidth: size.width,
        durationMilliseconds: travelDurationMilliseconds,
        preferredLane: preferredLane,
      );
      if (lane < 0) {
        textLayout.dispose();
        continue;
      }
      launchScheduler.commit(scheduledStart);
      scrollingLanes[lane] = _DanmakuScrollingLaneState(
        startedAt: startedAt,
        textWidth: textLayout.width,
      );
      items.add(
        _DanmakuLayoutItem(
          entry: entry,
          startsAt: scheduledStart,
          lane: lane,
          textWidth: textLayout.width,
          textHeight: textLayout.height,
          fillPainter: textLayout.fillPainter,
          outlinePainter: textLayout.outlinePainter,
        ),
      );
    }
    items.sort(
      (_DanmakuLayoutItem left, _DanmakuLayoutItem right) =>
          left.startsAt.compareTo(right.startsAt),
    );
    _cachedEntries = entries;
    _cachedSize = size;
    _cachedPreferences = preferences;
    _cachedItems = List<_DanmakuLayoutItem>.unmodifiable(items);
    return _cachedItems;
  }

  /// 为单条弹幕创建可重复绘制的填充与描边段落，重复内容会附带合并计数。
  _DanmakuTextLayout _buildTextLayout(
    DanmakuEntry entry,
    double canvasWidth,
    DanmakuPreferences preferences,
  ) {
    final String displayText = entry.repeatCount > 1
        ? '${entry.content} ×${entry.repeatCount}'
        : entry.content;
    final Color fillColor = _DanmakuPainter.colorForEntry(
      entry,
    ).withValues(alpha: preferences.opacity);
    final TextPainter fillPainter = TextPainter(
      text: TextSpan(
        text: displayText,
        style: _DanmakuPainter.textStyleFor(
          preferences,
        ).copyWith(color: fillColor),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: canvasWidth * 0.92);
    final TextPainter? outlinePainter = preferences.strokeWidth <= 0
        ? null
        : (TextPainter(
            text: TextSpan(
              text: displayText,
              style: _DanmakuPainter.textStyleFor(preferences).copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = preferences.strokeWidth * 2
                  ..color = _DanmakuPainter.outlineColorFor(
                    fillColor,
                  ).withValues(alpha: preferences.opacity),
                shadows: null,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: canvasWidth * 0.92));
    return _DanmakuTextLayout(
      width: fillPainter.width,
      height: fillPainter.height,
      fillPainter: fillPainter,
      outlinePainter: outlinePainter,
    );
  }

  /// 从期望车道开始寻找不会在进入或离屏前追尾的滚动弹幕车道。
  int _findScrollingLane({
    required List<_DanmakuScrollingLaneState?> laneStates,
    required int startedAt,
    required double newTextWidth,
    required double canvasWidth,
    required int durationMilliseconds,
    required int preferredLane,
  }) {
    for (int offset = 0; offset < laneStates.length; offset += 1) {
      final int lane = (preferredLane + offset) % laneStates.length;
      if (_canUseScrollingLane(
        previous: laneStates[lane],
        startedAt: startedAt,
        newTextWidth: newTextWidth,
        canvasWidth: canvasWidth,
        durationMilliseconds: durationMilliseconds,
      )) {
        return lane;
      }
    }
    return -1;
  }

  /// 同时检查旧弹幕是否完整进入画面，以及更宽的新弹幕是否会在旧弹幕离屏前追上。
  bool _canUseScrollingLane({
    required _DanmakuScrollingLaneState? previous,
    required int startedAt,
    required double newTextWidth,
    required double canvasWidth,
    required int durationMilliseconds,
  }) {
    if (previous == null) {
      return true;
    }
    final int elapsedMilliseconds = startedAt - previous.startedAt;
    if (elapsedMilliseconds <= 0) {
      return false;
    }
    if (elapsedMilliseconds >= durationMilliseconds) {
      return true;
    }
    final double progress = elapsedMilliseconds / durationMilliseconds;
    final double previousX =
        canvasWidth - (canvasWidth + previous.textWidth) * progress;
    final double previousRight = previousX + previous.textWidth;
    if (previousRight > canvasWidth) {
      return false;
    }
    if (previous.textWidth < newTextWidth &&
        previousRight * newTextWidth >
            canvasWidth * (canvasWidth - previousX)) {
      return false;
    }
    return true;
  }
}

/// 临时持有一条弹幕新建的文字段落，在成功入轨后把所有权交给布局项。
class _DanmakuTextLayout {
  /// 创建已经完成 layout 的填充与可选描边画笔。
  const _DanmakuTextLayout({
    required this.width,
    required this.height,
    required this.fillPainter,
    required this.outlinePainter,
  });

  final double width;
  final double height;
  final TextPainter fillPainter;
  final TextPainter? outlinePainter;

  /// 没有进入车道时立即释放两个段落，避免高密度被丢弃弹幕产生内存压力。
  void dispose() {
    fillPainter.dispose();
    outlinePainter?.dispose();
  }
}

/// 在播放器画面上绘制已经预排版的弹幕，只在当前可见时间窗口遍历有限条目。
class _DanmakuPainter extends CustomPainter {
  /// 按配置生成共享文字样式；具体颜色和描边由单条布局阶段补充。
  static TextStyle textStyleFor(DanmakuPreferences preferences) => TextStyle(
    fontSize: preferences.fontSize,
    fontWeight: FontWeight.w600,
    height: 1.15,
  );

  /// 把 B 站返回的 RGB 整数颜色转换为带不透明 Alpha 的 Flutter 颜色。
  static Color colorForEntry(DanmakuEntry entry) {
    return Color(0xFF000000 | (entry.color & 0xFFFFFF));
  }

  /// 深色文字使用白描边，其余颜色使用黑描边，保证亮暗视频画面上都可阅读。
  static Color outlineColorFor(Color fillColor) {
    return fillColor.computeLuminance() < 0.28 ? Colors.white : Colors.black;
  }

  /// 创建由帧控制器驱动的画笔；原生播放器状态只负责周期性校准时间锚点。
  _DanmakuPainter({
    required this.entries,
    required this.positionAnchor,
    required this.playbackSpeed,
    required this.frameController,
    required this.lanePlanner,
    required this.preferences,
  }) : super(repaint: frameController);

  final List<DanmakuEntry> entries;
  final Duration positionAnchor;
  final double playbackSpeed;
  final AnimationController frameController;
  final _DanmakuLanePlanner lanePlanner;
  final DanmakuPreferences preferences;

  /// 将真实帧间时间乘播放倍速后加到原生锚点，使弹幕和视频使用同一时间轴。
  Duration _currentPosition() {
    final int realElapsedMicroseconds =
        (frameController.value * frameController.duration!.inMicroseconds)
            .round();
    return DanmakuTimeline.advance(
      positionAnchor: positionAnchor,
      realElapsed: Duration(microseconds: realElapsedMicroseconds),
      playbackSpeed: playbackSpeed,
    );
  }

  /// 绘制当前可见弹幕；段落、宽高和车道均复用缓存，不在每一帧重新 layout。
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || entries.isEmpty) {
      return;
    }
    final Duration position = _currentPosition();
    final List<_DanmakuLayoutItem> items = lanePlanner.plan(
      entries,
      size,
      preferences,
    );
    final Duration lookBehind = Duration(
      milliseconds: (preferences.scrollDurationSeconds * 1000).round() + 1000,
    );
    final int firstCandidate = _firstCandidateIndex(
      items,
      position - lookBehind,
    );
    int paintedEntries = 0;
    for (int index = firstCandidate; index < items.length; index += 1) {
      final _DanmakuLayoutItem item = items[index];
      if (item.startsAt > position ||
          paintedEntries >= _maximumVisibleDanmakuEntries) {
        break;
      }
      final Duration elapsed = position - item.startsAt;
      final double x = _horizontalOffsetForItem(item, elapsed, size.width);
      if (x >= size.width || x + item.textWidth <= 0) {
        continue;
      }
      final double displayHeight = size.height * preferences.displayArea;
      final double maximumTop = (displayHeight - item.textHeight)
          .clamp(0, double.infinity)
          .toDouble();
      final double y = (item.lane * preferences.fontSize * 1.55)
          .clamp(0, maximumTop)
          .toDouble();
      item.outlinePainter?.paint(canvas, Offset(x, y));
      item.fillPainter.paint(canvas, Offset(x, y));
      paintedEntries += 1;
    }
  }

  /// 使用二分查找跳过已经完整离屏的条目，避免六分钟大段每帧从头扫描。
  int _firstCandidateIndex(List<_DanmakuLayoutItem> items, Duration threshold) {
    int lower = 0;
    int upper = items.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (items[middle].startsAt < threshold) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    return lower;
  }

  /// 计算统一的右到左横坐标；原顶部、底部和反向类型不会再从中间或左边生成。
  double _horizontalOffsetForItem(
    _DanmakuLayoutItem item,
    Duration elapsed,
    double canvasWidth,
  ) {
    return DanmakuTimeline.horizontalOffsetForDisplayMode(
      mode: item.entry.mode,
      elapsed: elapsed,
      canvasWidth: canvasWidth,
      textWidth: item.textWidth,
      travelDuration: Duration(
        milliseconds: (preferences.scrollDurationSeconds * 1000).round(),
      ),
    );
  }

  /// 当时间锚点、速度、样式、条目或规划器变化时请求静态重绘；连续移动由动画直接触发。
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.positionAnchor != positionAnchor ||
        oldDelegate.playbackSpeed != playbackSpeed ||
        !identical(oldDelegate.preferences, preferences) ||
        !identical(oldDelegate.entries, entries) ||
        oldDelegate.lanePlanner != lanePlanner;
  }
}
