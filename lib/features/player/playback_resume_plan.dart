import '../../models/video_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/native_playback_service.dart';
import '../../services/playback_resume_policy.dart';

/// 标识首次打开的分 P 是由用户、平台记录、观看历史还是默认值决定。
enum PlaybackResumePartSource { initial, requested, platform, watchHistory }

/// 标识首次播放位置的来源，内部恢复不会向用户重复显示续播提示。
enum PlaybackResumePositionSource {
  none,
  requested,
  platform,
  watchHistory,
  internalRecovery,
}

/// 保存一次播放器打开前已经确定的分 P、位置和提示语义。
class PlaybackResumePlan {
  /// 创建一份不可变的续播计划，平台层只能执行计划，不能重新改变优先级。
  const PlaybackResumePlan({
    required this.part,
    required this.position,
    required this.partSource,
    required this.positionSource,
  });

  final VideoPart part;
  final Duration position;
  final PlaybackResumePartSource partSource;
  final PlaybackResumePositionSource positionSource;

  /// 说明当前计划是否需要在首个画面就绪前遮住尚未定位的画面。
  bool get requiresRestoringMask => position > Duration.zero;

  /// 说明当前计划是否应提示用户恢复了上次观看的分 P。
  bool get shouldShowPartNotice =>
      partSource == PlaybackResumePartSource.platform ||
      partSource == PlaybackResumePartSource.watchHistory;

  /// 说明当前计划是否应显示位置提示；内部重建播放器不会重复提示。
  bool get shouldShowPositionNotice =>
      position > Duration.zero &&
      positionSource != PlaybackResumePositionSource.none &&
      positionSource != PlaybackResumePositionSource.internalRecovery;

  /// 按用户明确入口、平台记录、观看历史、默认分 P 的顺序生成唯一续播计划。
  static PlaybackResumePlan resolve({
    required VideoPreview video,
    int? requestedPartCid,
    Duration? requestedPosition,
    SavedPlaybackState? savedState,
    WatchHistoryEntry? historyEntry,
  }) {
    final VideoPart? requestedPart = _findPartByCid(
      video.parts,
      requestedPartCid,
    );
    final VideoPart? savedPart = _findPartByCid(video.parts, savedState?.cid);
    final Duration savedPosition = savedPart == null || savedState == null
        ? Duration.zero
        : normalizeStoredPosition(savedState.position, savedPart.duration);
    final bool canUseHistory =
        requestedPartCid == null &&
        requestedPosition == null &&
        savedPosition == Duration.zero &&
        historyEntry != null &&
        historyEntry.bvid.trim().toUpperCase() ==
            video.bvid.trim().toUpperCase();
    final VideoPart? historyPart = canUseHistory
        ? _findPartByPageNumber(video.parts, historyEntry.lastPartPageNumber)
        : null;
    final Duration historyPosition = historyPart == null || historyEntry == null
        ? Duration.zero
        : normalizeStoredPosition(
            historyEntry.lastPosition,
            historyPart.duration,
          );
    final bool usesHistory =
        historyPart != null && historyPosition > Duration.zero;
    final VideoPart targetPart =
        requestedPart ??
        (usesHistory ? historyPart : null) ??
        savedPart ??
        video.initialPart;
    final PlaybackResumePartSource targetPartSource = requestedPart != null
        ? PlaybackResumePartSource.requested
        : usesHistory
        ? PlaybackResumePartSource.watchHistory
        : savedPart != null
        ? PlaybackResumePartSource.platform
        : PlaybackResumePartSource.initial;

    if (requestedPosition != null) {
      return PlaybackResumePlan(
        part: targetPart,
        position: normalizeRequestedPosition(requestedPosition),
        partSource: targetPartSource,
        positionSource: PlaybackResumePositionSource.requested,
      );
    }
    if (savedPart?.cid == targetPart.cid && savedPosition > Duration.zero) {
      return PlaybackResumePlan(
        part: targetPart,
        position: savedPosition,
        partSource: targetPartSource,
        positionSource: PlaybackResumePositionSource.platform,
      );
    }
    if (usesHistory && historyPart.cid == targetPart.cid) {
      return PlaybackResumePlan(
        part: targetPart,
        position: historyPosition,
        partSource: targetPartSource,
        positionSource: PlaybackResumePositionSource.watchHistory,
      );
    }
    return PlaybackResumePlan(
      part: targetPart,
      position: Duration.zero,
      partSource: targetPartSource,
      positionSource: PlaybackResumePositionSource.none,
    );
  }

  /// 为手动切分 P 或播放器内部重建创建明确计划，避免平台再次读取另一套旧位置。
  static PlaybackResumePlan direct({
    required VideoPart part,
    Duration position = Duration.zero,
    PlaybackResumePositionSource positionSource =
        PlaybackResumePositionSource.none,
  }) {
    return PlaybackResumePlan(
      part: part,
      position: normalizeRequestedPosition(position),
      partSource: PlaybackResumePartSource.requested,
      positionSource: positionSource,
    );
  }

  /// 校验本机保存的进度：时长未知、位置越界或距结尾三秒时统一从头播放。
  static Duration normalizeStoredPosition(
    Duration position,
    Duration duration,
  ) {
    return PlaybackResumePolicy.normalizeStoredPosition(position, duration);
  }

  /// 校验用户明确指定的位置；最终上限由掌握真实媒体时长的平台播放器裁剪。
  static Duration normalizeRequestedPosition(Duration position) {
    return PlaybackResumePolicy.normalizeRequestedPosition(position);
  }

  /// 在视频分 P 列表中按 CID 查找目标，非法或过期编号返回空值。
  static VideoPart? _findPartByCid(List<VideoPart> parts, int? cid) {
    if (cid == null || cid <= 0) {
      return null;
    }
    for (final VideoPart part in parts) {
      if (part.cid == cid) {
        return part;
      }
    }
    return null;
  }

  /// 在视频分 P 列表中按一基页码查找观看历史对应的目标。
  static VideoPart? _findPartByPageNumber(
    List<VideoPart> parts,
    int pageNumber,
  ) {
    if (pageNumber <= 0) {
      return null;
    }
    for (final VideoPart part in parts) {
      if (part.pageNumber == pageNumber) {
        return part;
      }
    }
    return null;
  }
}
