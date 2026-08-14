import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/player/playback_resume_plan.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/native_playback_service.dart';

/// 验证所有播放器入口共用同一张分P与位置优先级决策表。
void main() {
  /// 用户明确指定的分P和位置必须覆盖本机平台记录与观看历史。
  test('用户明确位置优先', () {
    final VideoPreview video = _video();
    final PlaybackResumePlan plan = PlaybackResumePlan.resolve(
      video: video,
      requestedPartCid: 202,
      requestedPosition: const Duration(seconds: 42),
      savedState: const SavedPlaybackState(
        cid: 101,
        pageNumber: 1,
        position: Duration(seconds: 20),
      ),
      historyEntry: _history(position: const Duration(seconds: 30)),
    );

    expect(plan.part.cid, 202);
    expect(plan.position, const Duration(seconds: 42));
    expect(plan.positionSource, PlaybackResumePositionSource.requested);
    expect(plan.requiresRestoringMask, isTrue);
  });

  /// 平台存在合法位置时必须优先于较旧的 Flutter 观看历史。
  test('平台合法进度优先于观看历史', () {
    final PlaybackResumePlan plan = PlaybackResumePlan.resolve(
      video: _video(),
      savedState: const SavedPlaybackState(
        cid: 202,
        pageNumber: 2,
        position: Duration(seconds: 20),
      ),
      historyEntry: _history(position: const Duration(seconds: 30)),
    );

    expect(plan.part.cid, 202);
    expect(plan.position, const Duration(seconds: 20));
    expect(plan.positionSource, PlaybackResumePositionSource.platform);
  });

  /// 平台只有最后分P而没有合法时间点时，观看历史可以提供完整兜底。
  test('平台零进度时使用观看历史兜底', () {
    final PlaybackResumePlan plan = PlaybackResumePlan.resolve(
      video: _video(),
      savedState: const SavedPlaybackState(
        cid: 101,
        pageNumber: 1,
        position: Duration.zero,
      ),
      historyEntry: _history(position: const Duration(seconds: 30)),
    );

    expect(plan.part.cid, 202);
    expect(plan.position, const Duration(seconds: 30));
    expect(plan.positionSource, PlaybackResumePositionSource.watchHistory);
  });

  /// 平台记录距结尾三秒时只记住最后分P，不再恢复时间点。
  test('距结尾三秒的平台进度从头播放', () {
    final PlaybackResumePlan plan = PlaybackResumePlan.resolve(
      video: _video(),
      savedState: const SavedPlaybackState(
        cid: 202,
        pageNumber: 2,
        position: Duration(seconds: 117),
      ),
    );

    expect(plan.part.cid, 202);
    expect(plan.position, Duration.zero);
    expect(plan.partSource, PlaybackResumePartSource.platform);
    expect(plan.shouldShowPositionNotice, isFalse);
  });

  /// 观看历史接近结尾时同样不得制造“打开后直接结束”的假续播。
  test('距结尾三秒的观看历史不参与续播', () {
    final PlaybackResumePlan plan = PlaybackResumePlan.resolve(
      video: _video(),
      historyEntry: _history(position: const Duration(seconds: 117)),
    );

    expect(plan.part.cid, 101);
    expect(plan.position, Duration.zero);
    expect(plan.positionSource, PlaybackResumePositionSource.none);
  });
}

/// 创建两个两分钟分P的稳定测试视频。
VideoPreview _video() {
  return const VideoPreview(
    bvid: 'BV1GJ411x7h7',
    cid: 101,
    title: '续播测试视频',
    ownerName: '测试作者',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 101,
        title: '第一P',
        duration: Duration(minutes: 2),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 202,
        title: '第二P',
        duration: Duration(minutes: 2),
      ),
    ],
  );
}

/// 创建指向第二P的本机观看历史。
WatchHistoryEntry _history({required Duration position}) {
  return WatchHistoryEntry(
    bvid: 'BV1GJ411x7h7',
    title: '续播测试视频',
    ownerName: '测试作者',
    lastPartTitle: '第二P',
    lastPartPageNumber: 2,
    watchedAt: DateTime(2026, 8, 14),
    lastPosition: position,
  );
}
