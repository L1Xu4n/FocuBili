import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/playback_queue.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, mountAb, unmountAb, menu;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const nextVideo = VideoPreview(
  bvid: 'BV1xx411c7mD',
  cid: 201,
  title: 'Next',
  ownerName: 'Teacher',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 201,
      title: 'One',
      duration: Duration(minutes: 2),
    ),
    VideoPart(
      pageNumber: 2,
      cid: 202,
      title: 'Two',
      duration: Duration(minutes: 2),
    ),
  ],
);

/// 只替换视频详情读取，复用原播放器回归的媒体后端。
class _PlaylistVideoService extends BilibiliVideoInfoService {
  Completer<VideoPreview>? gate;

  /// 可延迟完成以覆盖定时停止先于详情返回的竞争。
  @override
  Future<VideoPreview> lookupVideo(String input) async =>
      gate == null ? nextVideo : gate!.future;
}

/// 为指定分 P 构造清单条目，禁止自动扩展到未保存的 P。
LearningListEntry entry(VideoPreview video, int cid) => LearningListEntry(
  bvid: video.bvid,
  title: video.title,
  ownerName: video.ownerName,
  thumbnailUrl: '',
  partCid: cid,
  partPageNumber: 1,
  partTitle: 'Saved',
  position: Duration.zero,
  duration: const Duration(minutes: 2),
  status: LearningListStatus.notStarted,
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// 验证四种播放模式、明确来源、指定分 P 和停止指令的结束事件。
void main() {
  for (final mode in ['pause', 'order', 'single', 'cycle']) {
    testWidgets('completion obeys $mode across parts and at the end', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'playback_preferences.mode': mode,
      });
      final playback = AbPlayback();
      await mountAb(tester, playback);
      playback.at(120, phase: PlaybackPhase.ended, playing: false);
      await tester.pumpAndSettle();
      expect(
        playback.currentCid,
        mode == 'order' || mode == 'cycle' ? 102 : 101,
      );
      if (mode == 'single') expect(playback.seeks, contains(Duration.zero));
      if (mode == 'order' || mode == 'cycle') {
        playback.at(120, phase: PlaybackPhase.ended, playing: false);
        await tester.pumpAndSettle();
        expect(playback.currentCid, mode == 'cycle' ? 101 : 102);
      }
      await unmountAb(tester);
    });
  }
  testWidgets(
    'learning queue crosses video at saved P without extending current video',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final playback = AbPlayback();
      final first = entry(abVideo, 101);
      final next = entry(nextVideo, 202);
      final queue = PlaybackQueue(
        title: '学习清单',
        items: [
          PlaybackQueueItem(
            bvid: first.bvid,
            title: first.title,
            learningEntry: first,
          ),
          PlaybackQueueItem(
            bvid: next.bvid,
            title: next.title,
            learningEntry: next,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: abVideo,
            playbackService: playback,
            playbackQueue: queue,
            bilibiliService: _PlaylistVideoService(),
            offlineVideoService: ReviewOfflineLibrary(),
            playerOverlayService: AbOverlay(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      playback.at(120, phase: PlaybackPhase.ended, playing: false);
      await tester.pumpAndSettle();
      expect(playback.currentCid, 202);
      await unmountAb(tester);
    },
  );
  testWidgets('sleep expiry cancels pending next-video lookup', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final playback = AbPlayback();
    final service = _PlaylistVideoService()..gate = Completer<VideoPreview>();
    final first = entry(abVideo, 101);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: abVideo,
          playbackService: playback,
          playbackQueue: PlaybackQueue(
            title: '清单',
            items: [
              PlaybackQueueItem(
                bvid: first.bvid,
                title: first.title,
                learningEntry: first,
              ),
              const PlaybackQueueItem(bvid: 'BV1xx411c7mD', title: 'Next'),
            ],
          ),
          bilibiliService: service,
          offlineVideoService: ReviewOfflineLibrary(),
          playerOverlayService: AbOverlay(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    playback.emit(
      playback.current.copyWith(
        sleepTimerRemaining: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    playback.at(120, phase: PlaybackPhase.ended, playing: false);
    await tester.pump();
    playback.emit(
      playback.current.copyWith(
        sleepTimerRemaining: Duration.zero,
        playRequested: false,
      ),
    );
    await tester.pump();
    service.gate!.complete(nextVideo);
    await tester.pumpAndSettle();
    expect(playback.currentCid, 101);
    expect(playback.current.isPlaying, isFalse);
    await unmountAb(tester);
  });
  testWidgets('closing AB editor retains draft and navigation clears it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final playback = AbPlayback();
    await mountAb(tester, playback);
    await menu(tester, 'ab-repeat-menu-item');
    playback.at(27);
    await tester.pump();
    await tester.tap(find.byKey(const Key('ab-repeat-set-A')));
    await tester.tap(find.byTooltip('收起 A–B 设置'));
    await tester.pumpAndSettle();
    await menu(tester, 'ab-repeat-menu-item');
    expect(find.text('A 00:27'), findsOneWidget);
    await tester.tap(find.byTooltip('收起 A–B 设置'));
    await tester.pumpAndSettle();
    playback.at(120, phase: PlaybackPhase.ended, playing: false);
    await tester.pumpAndSettle();
    await menu(tester, 'ab-repeat-menu-item');
    expect(find.text('A 00:27'), findsNothing);
    await unmountAb(tester);
  });
}
