import 'dart:convert';

/// 播放后端确认可读取的时间区间，不用下载字节比例推算视频时长。
class PlaybackBufferRange {
  const PlaybackBufferRange({required this.start, required this.end});
  final Duration start;
  final Duration end;
}

/// 排除损坏数据，合并重叠区间；跳转留下的空隙保持可见。
List<PlaybackBufferRange> normalizePlaybackBufferRanges(
  Iterable<PlaybackBufferRange> ranges, {
  required Duration duration,
}) {
  if (duration <= Duration.zero) return const [];
  final sorted =
      ranges
          .map(
            (range) => PlaybackBufferRange(
              start: Duration(
                microseconds: range.start.inMicroseconds.clamp(
                  0,
                  duration.inMicroseconds,
                ),
              ),
              end: Duration(
                microseconds: range.end.inMicroseconds.clamp(
                  0,
                  duration.inMicroseconds,
                ),
              ),
            ),
          )
          .where((range) => range.end > range.start)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <PlaybackBufferRange>[];
  for (final range in sorted) {
    if (merged.isNotEmpty && merged.last.end >= range.start) {
      final previous = merged.removeLast();
      merged.add(
        PlaybackBufferRange(
          start: previous.start,
          end: previous.end > range.end ? previous.end : range.end,
        ),
      );
    } else {
      merged.add(range);
    }
  }
  return List.unmodifiable(merged);
}

/// mpv seekable-ranges 是实际保留的主解复用器区间，包含磁盘回看。
/// 独立音轨不在此属性范围内；它不构成离线音视频完整性的保证。
List<PlaybackBufferRange> playbackBufferRangesFromMpv(
  String value, {
  required Duration duration,
}) {
  try {
    final data = jsonDecode(value);
    if (data is! Map || data['seekable-ranges'] is! List) return const [];
    final ranges = <PlaybackBufferRange>[];
    for (final raw in data['seekable-ranges'] as List) {
      if (raw is! Map) continue;
      final start = raw['start'];
      final end = raw['end'];
      if (start is! num || end is! num || !start.isFinite || !end.isFinite) {
        continue;
      }
      ranges.add(
        PlaybackBufferRange(
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(milliseconds: (end * 1000).round()),
        ),
      );
    }
    return normalizePlaybackBufferRanges(ranges, duration: duration);
  } on FormatException {
    return const [];
  }
}
