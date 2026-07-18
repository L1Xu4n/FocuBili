part of 'player_page.dart';

/// 保存一条已经完成车道规划的弹幕，绘制阶段不再重复测量文字或争抢车道。
class _DanmakuLayoutItem {
  /// 创建包含原始弹幕、物理车道和已测量文字宽度的渲染项。
  const _DanmakuLayoutItem({
    required this.entry,
    required this.lane,
    required this.textWidth,
  });

  final DanmakuEntry entry;
  final int lane;
  final double textWidth;
}

/// 缓存当前弹幕片段在指定画布尺寸下的车道规划，减少逐帧布局运算。
class _DanmakuLanePlanner {
  List<DanmakuEntry>? _cachedEntries;
  Size? _cachedSize;
  DanmakuPreferences? _cachedPreferences;
  List<_DanmakuLayoutItem> _cachedItems = const <_DanmakuLayoutItem>[];

  /// 清除旧分P或旧尺寸的规划结果，确保新视频不会复用错误车道。
  void clear() {
    _cachedEntries = null;
    _cachedSize = null;
    _cachedPreferences = null;
    _cachedItems = const <_DanmakuLayoutItem>[];
  }

  /// 按时间顺序为弹幕寻找空闲车道；没有空闲车道时丢弃该条，避免文字叠成一团。
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
    final double laneHeight = preferences.fontSize + 9;
    final int laneCount = (size.height / laneHeight)
        .floor()
        .clamp(1, preferences.laneCount)
        .toInt();
    final List<int> scrollingLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<int> topFixedLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<int> bottomFixedLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<DanmakuEntry> ordered = List<DanmakuEntry>.from(entries)
      ..sort(
        (DanmakuEntry left, DanmakuEntry right) =>
            left.position.compareTo(right.position),
      );
    final List<_DanmakuLayoutItem> items = <_DanmakuLayoutItem>[];
    for (final DanmakuEntry entry in ordered) {
      final double textWidth = _measureTextWidth(
        entry.content,
        size.width,
        preferences,
      );
      final int startedAt = entry.position.inMilliseconds;
      final int lane;
      if (entry.mode == 5) {
        lane = _findFixedLane(
          laneFreeAt: topFixedLaneFreeAt,
          startedAt: startedAt,
          fromBottom: false,
        );
      } else if (entry.mode == 4) {
        lane = _findFixedLane(
          laneFreeAt: bottomFixedLaneFreeAt,
          startedAt: startedAt,
          fromBottom: true,
        );
      } else {
        final int preferredLane =
            (startedAt ~/ 100 + entry.content.hashCode).abs() % laneCount;
        lane = _findScrollingLane(
          laneFreeAt: scrollingLaneFreeAt,
          startedAt: startedAt,
          preferredLane: preferredLane,
        );
      }
      if (lane < 0) {
        continue;
      }
      if (entry.mode == 4 || entry.mode == 5) {
        final List<int> fixedLanes = entry.mode == 4
            ? bottomFixedLaneFreeAt
            : topFixedLaneFreeAt;
        fixedLanes[lane] = startedAt + 4000;
      } else {
        final int minimumGapMilliseconds =
            ((textWidth + 28) /
                    (size.width + textWidth) *
                    (preferences.scrollDurationSeconds * 1000))
                .ceil();
        scrollingLaneFreeAt[lane] = startedAt + minimumGapMilliseconds;
      }
      items.add(
        _DanmakuLayoutItem(entry: entry, lane: lane, textWidth: textWidth),
      );
    }
    _cachedEntries = entries;
    _cachedSize = size;
    _cachedPreferences = preferences;
    _cachedItems = List<_DanmakuLayoutItem>.unmodifiable(items);
    return _cachedItems;
  }

  /// 测量单行弹幕的真实宽度并限制极端长文本，保证移动速度与碰撞判断一致。
  double _measureTextWidth(
    String text,
    double canvasWidth,
    DanmakuPreferences preferences,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _DanmakuPainter.textStyleFor(preferences),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: canvasWidth * 0.92);
    return painter.width;
  }

  /// 从期望车道开始循环寻找尾部已经离开起点的滚动弹幕车道。
  int _findScrollingLane({
    required List<int> laneFreeAt,
    required int startedAt,
    required int preferredLane,
  }) {
    for (int offset = 0; offset < laneFreeAt.length; offset += 1) {
      final int lane = (preferredLane + offset) % laneFreeAt.length;
      if (laneFreeAt[lane] <= startedAt) {
        return lane;
      }
    }
    return -1;
  }

  /// 从顶部或底部寻找空闲固定弹幕车道，四秒内被占用的车道不会重复使用。
  int _findFixedLane({
    required List<int> laneFreeAt,
    required int startedAt,
    required bool fromBottom,
  }) {
    for (int offset = 0; offset < laneFreeAt.length; offset += 1) {
      final int lane = fromBottom ? laneFreeAt.length - 1 - offset : offset;
      if (laneFreeAt[lane] <= startedAt) {
        return lane;
      }
    }
    return -1;
  }
}

/// 在整个播放器画面上平滑绘制真实弹幕，不受上下控制栏的布局内边距影响。
class _DanmakuPainter extends CustomPainter {
  static const Duration _fixedDisplayDuration = Duration(seconds: 4);
  static const int _maximumVisibleEntries = 48;

  /// 按配置生成绘制样式；字号单位为 Flutter 逻辑像素，透明度限制在 20% 至 100%。
  static TextStyle textStyleFor(DanmakuPreferences preferences) => TextStyle(
    color: Colors.white.withValues(alpha: preferences.opacity),
    fontSize: preferences.fontSize,
    fontWeight: FontWeight.w600,
    shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 2)],
  );

  /// 创建使用逐帧控制器重绘的弹幕画笔，原生播放器状态只负责校准时间锚点。
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

  /// 将帧间真实时间乘当前倍速后加到播放器锚点，使弹幕与倍速播放保持同一时间轴。
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

  /// 绘制当前可见弹幕；车道无空间的高密度条目已经在规划阶段被安全丢弃。
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
    final int firstCandidate = _firstCandidateIndex(
      items,
      position - const Duration(seconds: 14),
    );
    int paintedEntries = 0;
    for (int index = firstCandidate; index < items.length; index += 1) {
      final _DanmakuLayoutItem item = items[index];
      if (item.entry.position > position ||
          paintedEntries >= _maximumVisibleEntries) {
        break;
      }
      final Duration elapsed = position - item.entry.position;
      final double x = _horizontalOffsetForItem(item, elapsed, size.width);
      if (x > size.width || x + item.textWidth < 0) {
        continue;
      }
      if ((item.entry.mode == 4 || item.entry.mode == 5) &&
          elapsed > _fixedDisplayDuration) {
        continue;
      }
      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: item.entry.content,
          style: textStyleFor(preferences).copyWith(
            color: _colorForEntry(
              item.entry,
            ).withValues(alpha: preferences.opacity),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width * 0.92);
      final double maximumTop = (size.height - textPainter.height)
          .clamp(0, double.infinity)
          .toDouble();
      final double y = (item.lane * (preferences.fontSize + 9))
          .clamp(0, maximumTop)
          .toDouble();
      textPainter.paint(canvas, Offset(x, y));
      paintedEntries += 1;
    }
  }

  /// 使用二分查找跳过远早于当前时间的条目，降低长弹幕片段的逐帧遍历开销。
  int _firstCandidateIndex(List<_DanmakuLayoutItem> items, Duration threshold) {
    int lower = 0;
    int upper = items.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (items[middle].entry.position < threshold) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    return lower;
  }

  /// 按固定视频时长让弹幕完整穿过整个画布，横屏再宽也不会只挤在左半边。
  double _horizontalOffsetForItem(
    _DanmakuLayoutItem item,
    Duration elapsed,
    double canvasWidth,
  ) {
    if (item.entry.mode == 4 || item.entry.mode == 5) {
      return (canvasWidth - item.textWidth) / 2;
    }
    return DanmakuTimeline.horizontalOffset(
      elapsed: elapsed,
      canvasWidth: canvasWidth,
      textWidth: item.textWidth,
      reverse: item.entry.mode == 6,
      travelDuration: Duration(
        milliseconds: (preferences.scrollDurationSeconds * 1000).round(),
      ),
    );
  }

  /// 把 B 站返回的 RGB 整数颜色转换为带不透明 Alpha 的 Flutter 颜色。
  Color _colorForEntry(DanmakuEntry entry) {
    return Color(0xFF000000 | (entry.color & 0xFFFFFF));
  }

  /// 当片段列表或原生时间锚点改变时重绘；连续移动由动画控制器直接驱动。
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.positionAnchor != positionAnchor ||
        oldDelegate.playbackSpeed != playbackSpeed ||
        !identical(oldDelegate.preferences, preferences) ||
        !identical(oldDelegate.entries, entries) ||
        oldDelegate.lanePlanner != lanePlanner;
  }
}
