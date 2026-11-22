import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/learning/learning_video_launcher.dart';
import 'package:focubili/features/learning/learning_video_lookup.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart' show AbOverlay;
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

const _bvid = 'BV1GJ411x7h7';
const _first = VideoPart(
  pageNumber: 1,
  cid: 137649198,
  title: 'First',
  duration: Duration(minutes: 2),
);
const _target = VideoPart(
  pageNumber: 2,
  cid: 137649199,
  title: 'Target',
  duration: Duration(minutes: 2),
);
const _video = VideoPreview(
  bvid: _bvid,
  cid: 137649198,
  title: 'Online metadata',
  ownerName: 'Review',
  parts: [_first, _target],
);
const _resume = Duration(seconds: 37);
const _preferenceKey = 'playback_preferences.prefer_offline_cache';

LearningListEntry _entry({int cid = 137649199, Duration position = _resume}) =>
    LearningListEntry(
      bvid: _bvid,
      title: 'Learning task',
      ownerName: 'Review',
      thumbnailUrl: '',
      partCid: cid,
      partPageNumber: 2,
      partTitle: 'Target',
      position: position,
      duration: const Duration(minutes: 2),
      status: LearningListStatus.learning,
      addedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

class _Details extends BilibiliVideoInfoService {
  _Details(this.response);

  final VideoPreview? response;
  final lookupRequests = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupRequests.add(input);
    return response ?? (throw StateError('No network'));
  }
}

class _DisconnectedLibrary extends ReviewOfflineLibrary {
  @override
  Future<List<OfflineVideoDownload>> loadDownloads() async =>
      throw StateError('Storage ejected');
}

enum _StartupOutcome { ready, throwsImmediately, failsAsynchronously }

class _Playback extends ReviewLocalPlayback {
  _Playback({
    this.online = _StartupOutcome.ready,
    this.local = _StartupOutcome.ready,
  });

  final _StartupOutcome online;
  final _StartupOutcome local;
  final attempts = <({bool local, String bvid, int cid, Duration? position})>[];

  void _record(
    bool local,
    VideoPreview video,
    VideoPart part,
    Duration? position,
  ) {
    attempts.add((
      local: local,
      bvid: video.bvid,
      cid: part.cid,
      position: position,
    ));
    final identity = (bvid: video.bvid, cid: part.cid, local: local);
    controller.add(
      PlaybackSnapshot(phase: PlaybackPhase.loading, sourceIdentity: identity),
    );
    switch (local ? this.local : online) {
      case _StartupOutcome.throwsImmediately:
        throw StateError('Cannot open media');
      case _StartupOutcome.failsAsynchronously:
        // Model the native stream, including a similarly timed old error.
        controller.add(
          PlaybackSnapshot(
            phase: PlaybackPhase.error,
            sourceIdentity: (bvid: _bvid, cid: _first.cid, local: local),
          ),
        );
        controller.add(
          PlaybackSnapshot(
            phase: PlaybackPhase.error,
            sourceIdentity: identity,
            message: 'Cannot open media',
          ),
        );
      case _StartupOutcome.ready:
        controller.add(
          PlaybackSnapshot(
            phase: PlaybackPhase.ready,
            sourceIdentity: identity,
            isPlaying: true,
            duration: const Duration(minutes: 2),
            position: position ?? Duration.zero,
          ),
        );
    }
  }

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async => _record(false, video, part ?? video.initialPart, initialPosition);

  @override
  Future<void> openLocalFile({
    required String filePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  }) async {
    expect(filePath, ReviewOfflineLibrary.record.filePath);
    _record(true, video!, part!, initialPosition);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('learning prefers exact cache without calling the network', () async {
    final details = _Details(_video);
    final entry = _entry();
    final video = await lookupLearningVideo(
      entry,
      videoService: details,
      offlineVideoService: ReviewOfflineLibrary(),
      preferCache: true,
    );
    expect(details.lookupRequests, isEmpty);
    expect(video.fromOfflineCache, isTrue);
    expect(video.parts.single.cid, entry.partCid);
    expect(video.parts.single.pageNumber, entry.partPageNumber);
    final player = LearningVideoLauncher.buildPlayerPage(video, entry);
    expect(player.initialPartCid, entry.partCid);
    expect(player.initialPosition, _resume);
    expect(player.forceOffline, isFalse);
  });

  test(
    'learning online priority uses online details and exact zero position',
    () async {
      final details = _Details(_video);
      final entry = _entry(position: Duration.zero);
      final video = await lookupLearningVideo(
        entry,
        videoService: details,
        offlineVideoService: ReviewOfflineLibrary(),
        preferCache: false,
      );
      expect(details.lookupRequests, [_bvid]);
      expect(video, same(_video));
      final player = LearningVideoLauncher.buildPlayerPage(video, entry);
      expect(player.initialPartCid, entry.partCid);
      expect(player.initialPosition, Duration.zero);
    },
  );

  test(
    'learning online metadata failure falls back to the exact part',
    () async {
      final details = _Details(null);
      final video = await lookupLearningVideo(
        _entry(),
        videoService: details,
        offlineVideoService: ReviewOfflineLibrary(),
        preferCache: false,
      );
      expect(details.lookupRequests, [_bvid]);
      expect(video.fromOfflineCache, isTrue);
      expect(video.initialPart.cid, _target.cid);
    },
  );

  test(
    'a different cached part cannot satisfy the original learning task',
    () async {
      // Generic metadata can include parts with no matching downloaded file.
      const cachedOtherPart = VideoPreview(
        bvid: _bvid,
        cid: 137649199,
        title: 'One cached part',
        ownerName: 'Review',
        parts: [_first, _target],
        fromOfflineCache: true,
      );
      await expectLater(
        lookupLearningVideo(
          _entry(cid: _first.cid),
          videoService: _Details(cachedOtherPart),
          offlineVideoService: ReviewOfflineLibrary(),
          preferCache: true,
        ),
        throwsA(isA<BilibiliLookupException>()),
      );
    },
  );

  Future<void> mount(
    WidgetTester tester,
    _Playback playback, {
    bool preferCache = false,
    bool forceOffline = false,
    int cid = 137649199,
    ReviewOfflineLibrary? library,
  }) async {
    SharedPreferences.setMockInitialValues({_preferenceKey: preferCache});
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _video,
          initialPartCid: cid,
          initialPosition: _resume,
          playbackService: playback,
          playerOverlayService: AbOverlay(),
          offlineVideoService: library ?? ReviewOfflineLibrary(),
          forceOffline: forceOffline,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectAttempts(
    _Playback playback,
    List<bool> localAttempts, {
    int cid = 137649199,
  }) {
    expect(playback.attempts, [
      for (final local in localAttempts)
        (local: local, bvid: _bvid, cid: cid, position: _resume),
    ]);
  }

  testWidgets('player uses the saved priority when both sources exist', (
    tester,
  ) async {
    for (final preferCache in [false, true]) {
      final playback = _Playback();
      await mount(tester, playback, preferCache: preferCache);
      expectAttempts(playback, [preferCache]);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'player opens online for an uncached part or unreadable library',
    (tester) async {
      final wrongPart = _Playback();
      await mount(tester, wrongPart, preferCache: true, cid: _first.cid);
      expectAttempts(wrongPart, [false], cid: _first.cid);
      await tester.pumpWidget(const SizedBox.shrink());
      final disconnected = _Playback();
      await mount(
        tester,
        disconnected,
        preferCache: true,
        library: _DisconnectedLibrary(),
      );
      expectAttempts(disconnected, [false]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final failure in [
    _StartupOutcome.throwsImmediately,
    _StartupOutcome.failsAsynchronously,
  ]) {
    testWidgets('player falls back online when local startup ${failure.name}', (
      tester,
    ) async {
      final playback = _Playback(local: failure);
      await mount(tester, playback, preferCache: true);
      expectAttempts(playback, [true, false]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('online startup failure tries exact cached media once', (
    tester,
  ) async {
    final playback = _Playback(
      online: _StartupOutcome.failsAsynchronously,
      local: _StartupOutcome.failsAsynchronously,
    );
    await mount(tester, playback);
    expectAttempts(playback, [false, true]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit offline entry does not fall back online', (
    tester,
  ) async {
    final playback = _Playback(local: _StartupOutcome.failsAsynchronously);
    await mount(tester, playback, forceOffline: true);
    expectAttempts(playback, [true]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
