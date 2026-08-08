import 'danmaku_preferences.dart';
import 'player_overlay_data.dart';

///
/// 把六分钟弹幕段整理成 100ms 时间桶，并在进入绘制层前完成类型、关键词和重复内容过滤。
///
/// 该结构参考 PiliPlus 的时间桶调度思路，但保持纯 Dart、无平台依赖，未来 Windows 播放器可直接复用。
class DanmakuTimelineIndex {
  /// 创建经过排序和过滤的只读时间索引；同一时间桶的相同内容可合并为一条计数弹幕。
  factory DanmakuTimelineIndex.fromEntries(
    Iterable<DanmakuEntry> source,
    DanmakuPreferences preferences,
  ) {
    final List<DanmakuEntry> ordered =
        source
            .where(
              (DanmakuEntry entry) =>
                  preferences.allowsMode(entry.mode) &&
                  !preferences.blocks(entry.content),
            )
            .toList(growable: false)
          ..sort(
            (DanmakuEntry left, DanmakuEntry right) =>
                left.position.compareTo(right.position),
          );
    final List<DanmakuEntry> processed = <DanmakuEntry>[];
    final Map<String, int> mergeIndexes = <String, int>{};
    for (final DanmakuEntry entry in ordered) {
      final String mergeKey = _mergeKey(entry);
      final int? existingIndex = preferences.mergeRepeated
          ? mergeIndexes[mergeKey]
          : null;
      if (existingIndex == null) {
        mergeIndexes[mergeKey] = processed.length;
        processed.add(entry);
      } else {
        final DanmakuEntry existing = processed[existingIndex];
        processed[existingIndex] = existing.copyWith(
          repeatCount: existing.repeatCount + entry.repeatCount,
        );
      }
    }
    final Map<int, List<DanmakuEntry>> buckets = <int, List<DanmakuEntry>>{};
    for (final DanmakuEntry entry in processed) {
      (buckets[bucketForPosition(entry.position)] ??= <DanmakuEntry>[]).add(
        entry,
      );
    }
    return DanmakuTimelineIndex._(
      entries: List<DanmakuEntry>.unmodifiable(processed),
      buckets: Map<int, List<DanmakuEntry>>.unmodifiable(
        buckets.map(
          (int key, List<DanmakuEntry> value) =>
              MapEntry<int, List<DanmakuEntry>>(
                key,
                List<DanmakuEntry>.unmodifiable(value),
              ),
        ),
      ),
    );
  }

  /// 保存已经完成处理的有序列表和时间桶，只允许公开工厂创建。
  const DanmakuTimelineIndex._({
    required this.entries,
    required Map<int, List<DanmakuEntry>> buckets,
  }) : _buckets = buckets;

  static const Duration bucketDuration = Duration(milliseconds: 100);

  final List<DanmakuEntry> entries;
  final Map<int, List<DanmakuEntry>> _buckets;

  /// 把播放位置向下取整到 100ms 桶编号，负数统一回到第零桶。
  static int bucketForPosition(Duration position) {
    return position.isNegative
        ? 0
        : position.inMilliseconds ~/ bucketDuration.inMilliseconds;
  }

  /// 返回指定播放位置所属时间桶的弹幕；没有内容时返回稳定空列表。
  List<DanmakuEntry> entriesAt(Duration position) {
    return _buckets[bucketForPosition(position)] ?? const <DanmakuEntry>[];
  }

  /// 生成同时间桶、同文字的合并键；所有基础类型已统一右到左，颜色差异保留首次出现样式。
  static String _mergeKey(DanmakuEntry entry) {
    return '${bucketForPosition(entry.position)}|'
        '${entry.content.trim().toLowerCase()}';
  }
}
