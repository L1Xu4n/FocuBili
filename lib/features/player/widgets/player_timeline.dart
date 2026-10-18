import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/video_note.dart';
import '../../../models/ab_repeat_range.dart';
import '../../../models/playback_buffer_range.dart';
import '../../notes/video_note_composer.dart' show formatVideoNotePosition;

/// 普通进度条、章节条和笔记旗标共用的真实轨道几何。
class PlayerTimelineGeometry {
  static const double trackInset = 8;

  /// 与控制栏 SafeArea 的最小左右边距一致。
  static EdgeInsets safeInsets(EdgeInsets padding) => EdgeInsets.only(
    left: math.max(4, padding.left),
    right: math.max(4, padding.right),
  );

  /// 返回实际可绘制轨道，显式包含滑块覆盖圆需要的空间。
  static Rect trackRect(
    Size size, {
    Offset offset = Offset.zero,
    double thickness = 1.2,
  }) => Rect.fromLTWH(
    offset.dx + trackInset,
    offset.dy + (size.height - thickness) / 2,
    math.max(0, size.width - trackInset * 2),
    thickness,
  );
}

/// A/B labels and the selected span use exactly the Slider track coordinates.
class PlayerAbRepeatMarkers extends StatelessWidget {
  const PlayerAbRepeatMarkers({
    super.key,
    required this.range,
    required this.duration,
  });
  final AbRepeatRange range;
  final Duration duration;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '区间循环，A ${formatAbRepeatTime(range.a)}，B ${formatAbRepeatTime(range.b)}，点击修改或清除',
    button: true,
    child: SizedBox(
      height: 24,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final track = PlayerTimelineGeometry.trackRect(
            Size(constraints.maxWidth, 24),
          );
          final total = math.max(1, duration.inMilliseconds);
          final left =
              track.left +
              track.width * (range.a.inMilliseconds / total).clamp(0, 1);
          final right =
              track.left +
              track.width * (range.b.inMilliseconds / total).clamp(0, 1);
          final closePoints = right - left < 18;
          return Stack(
            children: [
              Positioned(
                left: left,
                width: math.max(1, right - left),
                top: 9,
                height: 7,
                child: const ColoredBox(color: Color(0x9948C9B0)),
              ),
              for (final point in [('A', left), ('B', right)])
                Positioned(
                  left: (point.$2 - 7).clamp(
                    0,
                    math.max(0, constraints.maxWidth - 14),
                  ),
                  top: closePoints && point.$1 == 'B' ? 11 : 0,
                  child: Text(
                    point.$1,
                    key: Key('ab-repeat-marker-${point.$1}'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

/// 固定 Slider 真实轨道端点，避免 Material 版本的默认 padding 改变轨道长度。
class PlayerTimelineTrackShape extends RoundedRectSliderTrackShape {
  /// 创建播放器专用轨道形状。
  const PlayerTimelineTrackShape({
    this.bufferedRanges = const [],
    this.duration = Duration.zero,
  });

  final List<PlaybackBufferRange> bufferedRanges;
  final Duration duration;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );
    for (final segment in playbackBufferRects(
      bufferedRanges,
      duration,
      rect,
      textDirection,
    )) {
      final inactive = textDirection == TextDirection.ltr
          ? Rect.fromLTRB(
              math.max(segment.left, thumbCenter.dx),
              segment.top,
              segment.right,
              segment.bottom,
            )
          : Rect.fromLTRB(
              segment.left,
              segment.top,
              math.min(segment.right, thumbCenter.dx),
              segment.bottom,
            );
      if (inactive.width <= 0) continue;
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(inactive, Radius.circular(rect.height / 2)),
        Paint()..color = Colors.white.withValues(alpha: .52),
      );
    }
  }

  /// 使用所有时间轴组件共用的端点与长度。
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => PlayerTimelineGeometry.trackRect(
    parentBox.size,
    offset: offset,
    thickness: sliderTheme.trackHeight ?? 1.2,
  );
}

/// 与轨道共用坐标，避免把非连续缓冲误画为零点开始的单一进度。
List<Rect> playbackBufferRects(
  List<PlaybackBufferRange> ranges,
  Duration duration,
  Rect track,
  TextDirection direction,
) {
  if (duration <= Duration.zero) return const [];
  return [
    for (final range in normalizePlaybackBufferRanges(
      ranges,
      duration: duration,
    ))
      Rect.fromLTRB(
        track.left +
            track.width *
                (direction == TextDirection.ltr
                    ? range.start.inMicroseconds / duration.inMicroseconds
                    : 1 - range.end.inMicroseconds / duration.inMicroseconds),
        track.top,
        track.left +
            track.width *
                (direction == TextDirection.ltr
                    ? range.end.inMicroseconds / duration.inMicroseconds
                    : 1 - range.start.inMicroseconds / duration.inMicroseconds),
        track.bottom,
      ),
  ];
}

/// 收起控制栏后的微型轨道仍显示相同的缓存区间。
class PlayerMiniProgress extends StatelessWidget {
  const PlayerMiniProgress({
    super.key,
    required this.value,
    required this.duration,
    required this.bufferedRanges,
  });
  final double value;
  final Duration duration;
  final List<PlaybackBufferRange> bufferedRanges;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _MiniProgressPainter(
      value,
      duration,
      bufferedRanges,
      Theme.of(context).colorScheme.primary,
      Directionality.of(context),
    ),
    child: const SizedBox(width: double.infinity, height: 2),
  );
}

class _MiniProgressPainter extends CustomPainter {
  _MiniProgressPainter(
    this.value,
    this.duration,
    this.ranges,
    this.color,
    this.direction,
  );
  final double value;
  final Duration duration;
  final List<PlaybackBufferRange> ranges;
  final Color color;
  final TextDirection direction;
  @override
  void paint(Canvas canvas, Size size) {
    final track = Offset.zero & size;
    canvas.drawRect(track, Paint()..color = Colors.white24);
    for (final rect in playbackBufferRects(
      ranges,
      duration,
      track,
      direction,
    )) {
      canvas.drawRect(rect, Paint()..color = Colors.white54);
    }
    final progress = size.width * value.clamp(0, 1);
    canvas.drawRect(
      Rect.fromLTWH(
        direction == TextDirection.ltr ? 0 : size.width - progress,
        0,
        progress,
        size.height,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniProgressPainter old) =>
      old.value != value ||
      old.duration != duration ||
      old.ranges != ranges ||
      old.color != color ||
      old.direction != direction;
}

/// 把同一秒内的笔记合并为一个旗标，与现有笔记显示的秒级时间一致。
List<List<VideoNote>> groupPlayerNoteFlags({
  required Iterable<VideoNote> notes,
  required String bvid,
  required int cid,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return const [];
  final groups = <int, List<VideoNote>>{};
  for (final note in notes) {
    if (note.bvid != bvid ||
        note.partCid != cid ||
        note.position < Duration.zero ||
        note.position > duration) {
      continue;
    }
    groups.putIfAbsent(note.position.inSeconds, () => <VideoNote>[]).add(note);
  }
  final seconds = groups.keys.toList()..sort();
  return [for (final second in seconds) List.unmodifiable(groups[second]!)];
}

/// 在独立命中区域显示笔记旗标；密集时间点使用共享选择入口保证全部可达。
class PlayerNoteFlags extends StatelessWidget {
  /// 创建当前视频分 P 的旗标，点击回调仅打开笔记。
  const PlayerNoteFlags({
    super.key,
    required this.notes,
    required this.bvid,
    required this.cid,
    required this.duration,
    required this.onOpen,
  });

  final List<VideoNote> notes;
  final String bvid;
  final int cid;
  final Duration duration;
  final ValueChanged<List<VideoNote>> onOpen;

  /// 将旗标绘制在轨道对应位置，并把相邻重叠命中范围合并为可关闭的选择列表入口。
  @override
  Widget build(BuildContext context) {
    final groups = groupPlayerNoteFlags(
      notes: notes,
      bvid: bvid,
      cid: cid,
      duration: duration,
    );
    if (groups.isEmpty) return const SizedBox.shrink();
    // 提高主题色的亮度以适配黑色视频，并用轻微暗边缘区分明亮画面。
    final flagColor = HSLColor.fromColor(
      Theme.of(context).colorScheme.primary,
    ).withLightness(0.78).toColor();
    return SizedBox(
      key: const Key('player-note-flags'),
      height: 28,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final track = PlayerTimelineGeometry.trackRect(Size(width, 28));
          final positions = [
            for (final group in groups)
              track.left +
                  track.width *
                      (group.first.position.inSeconds *
                              1000 /
                              duration.inMilliseconds)
                          .clamp(0, 1),
          ];
          final clusters = <List<int>>[];
          for (var index = 0; index < groups.length; index++) {
            if (clusters.isEmpty ||
                positions[index] - positions[clusters.last.last] >= 28) {
              clusters.add([index]);
            } else {
              clusters.last.add(index);
            }
          }
          return Stack(
            children: [
              for (var index = 0; index < groups.length; index++)
                Positioned(
                  left: positions[index] - 7,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Icon(
                      Icons.flag_rounded,
                      key: ValueKey(
                        'player-note-flag-${groups[index].first.position.inSeconds}',
                      ),
                      size: 14,
                      color: flagColor,
                      shadows: const [
                        Shadow(color: Colors.black87, blurRadius: 2),
                        Shadow(
                          color: Colors.black54,
                          offset: Offset(0, 1),
                          blurRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              for (final cluster in clusters)
                Positioned(
                  left: (positions[cluster.first] - 14).clamp(
                    0,
                    math.max(0, width - 28),
                  ),
                  width: math.min(
                    width,
                    math.max(
                      28,
                      positions[cluster.last] - positions[cluster.first] + 28,
                    ),
                  ),
                  top: 0,
                  bottom: 0,
                  child: Tooltip(
                    message: cluster
                        .expand((index) => groups[index])
                        .map(
                          (note) =>
                              '${formatVideoNotePosition(note.position)} ${note.title}',
                        )
                        .join('\n'),
                    child: GestureDetector(
                      key: ValueKey('player-note-flag-hit-${cluster.first}'),
                      behavior: HitTestBehavior.opaque,
                      // 点击只把本区域的笔记交给工作区，独立于下方 Slider。
                      onTap: () => onOpen([
                        for (final index in cluster) ...groups[index],
                      ]),
                      child: Semantics(
                        button: true,
                        label: '打开笔记时间标记',
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
