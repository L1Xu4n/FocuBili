import 'player_overlay_data.dart';

///
/// 记录每个六分钟片段本次允许开始呈现的时间，防止晚到的历史弹幕直接补画到屏幕中间。
///
/// 该模型只依赖视频时间轴，不依赖 Android 或窗口平台，因此平板与后续 Windows 播放器可以共用。
class DanmakuPresentationWindow {
  final Map<int, Duration> _segmentFloors = <int, Duration>{};

  /// 清空所有片段起点，切换视频或分P后不继承旧时间轴。
  void clear() {
    _segmentFloors.clear();
  }

  /// 忘记一个已淘汰片段的呈现起点，避免长视频播放时状态持续增长。
  void forgetSegment(int segmentIndex) {
    _segmentFloors.remove(segmentIndex);
  }

  /// 在开启弹幕或跳转进度后，以当前位置重新开始当前片段，之前的弹幕不再中途补画。
  void restartFrom(Duration position) {
    final Duration safePosition = position.isNegative
        ? Duration.zero
        : position;
    final int segmentIndex = DanmakuSegmentLoadResult.segmentIndexForPosition(
      safePosition,
    );
    _segmentFloors[segmentIndex] = safePosition;
  }

  /// 在片段下载完成时确定起点；预加载的未来片段从片段开头开始，晚到的当前片段从当前进度开始。
  void prepareSegment({
    required int segmentIndex,
    required Duration currentPosition,
  }) {
    final Duration segmentStart = startOfSegment(segmentIndex);
    final Duration segmentEnd =
        segmentStart + DanmakuSegmentLoadResult.segmentDuration;
    final bool currentInsideSegment =
        currentPosition >= segmentStart && currentPosition < segmentEnd;
    _segmentFloors[segmentIndex] = currentInsideSegment
        ? currentPosition
        : segmentStart;
  }

  /// 返回片段本次呈现起点；尚未登记的片段默认从自己的开头完整播放。
  Duration floorForSegment(int segmentIndex) {
    return _segmentFloors[segmentIndex] ?? startOfSegment(segmentIndex);
  }

  /// 使用二分查找丢弃起点以前的历史弹幕，并尽量复用原列表以保留渲染布局缓存。
  List<DanmakuEntry> filterEntries({
    required int segmentIndex,
    required List<DanmakuEntry> entries,
  }) {
    if (entries.isEmpty) {
      return entries;
    }
    final Duration floor = floorForSegment(segmentIndex);
    int lower = 0;
    int upper = entries.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (entries[middle].position < floor) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    if (lower == 0) {
      return entries;
    }
    if (lower >= entries.length) {
      return const <DanmakuEntry>[];
    }
    return List<DanmakuEntry>.unmodifiable(entries.sublist(lower));
  }

  /// 把一基片段编号换算成全局视频时间；非法编号安全回退到第一片段。
  static Duration startOfSegment(int segmentIndex) {
    final int safeIndex = segmentIndex < 1 ? 1 : segmentIndex;
    return Duration(
      milliseconds:
          (safeIndex - 1) *
          DanmakuSegmentLoadResult.segmentDuration.inMilliseconds,
    );
  }
}
