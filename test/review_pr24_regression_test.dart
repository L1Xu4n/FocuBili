import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/native_playback_service.dart';

/// Simulates successful native playback without a device or a media file.
class ReviewLocalPlayback extends NativePlaybackService {
  final controller = StreamController<PlaybackSnapshot>.broadcast();
  bool paused = false;
  bool localOpened = false;
  int localOpenCount = 0;

  /// Avoids native device queries while using the real shared player page.
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async =>
      const SystemPlaybackLevels(brightness: 0.5, volume: 0.5);

  /// Supplies no prior resume state to keep this test deterministic.
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async => null;

  /// Prevents an offline player regression from silently opening the network.
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async => fail('Offline entry opened online media');

  /// Records a pause from the shared player's real control button.
  @override
  Future<void> pause() async {
    paused = true;
  }

  /// Supplies deterministic playback state events.
  @override
  Stream<PlaybackSnapshot> get states => controller.stream;

  /// Returns a fake texture identifier for widget testing.
  @override
  Future<int?> initialize() async => 1;

  /// Reports a successfully opened, currently playing local video.
  @override
  Future<void> openLocalFile({
    required String filePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  }) async {
    localOpened = true;
    localOpenCount++;
    controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        duration: Duration(minutes: 2),
        isPlaying: true,
      ),
    );
  }

  /// Closes only the in-memory event stream.
  @override
  Future<void> dispose() async => controller.close();
}

/// Supplies an already validated library record without accessing user files.
class ReviewOfflineLibrary extends OfflineVideoService {
  /// Uses a deterministic video identity shared by the real player and cache resolver.
  static final record = OfflineVideoDownload(
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: 'Review',
    coverUrl: '',
    ownerName: 'Review',
    filePath: 'review.mp4',
    sizeBytes: 3,
    qualityId: 32,
    qualityLabel: '480P',
    duration: const Duration(minutes: 2),
    downloadedAt: DateTime(2026),
    status: OfflineDownloadStatus.ready,
  );

  /// Returns the test record instead of consulting physical storage.
  @override
  Future<List<OfflineVideoDownload>> loadDownloads() async => [record];
}

/// Checks that a ready local player exposes usable playback controls.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('ready offline video can be paused', (WidgetTester tester) async {
    final service = ReviewLocalPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: ReviewOfflineLibrary.record.toPreview(),
          forceOffline: true,
          offlineVideoService: ReviewOfflineLibrary(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.localOpened, isTrue);
    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    expect(service.paused, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('uncached offline part keeps the current part and media', (
    tester,
  ) async {
    final service = ReviewLocalPlayback();
    final first = ReviewOfflineLibrary.record.toPreview().parts.single;
    final second = VideoPart(
      pageNumber: 2,
      cid: 137649200,
      title: 'Missing part',
      duration: const Duration(minutes: 2),
    );
    final video = VideoPreview(
      bvid: ReviewOfflineLibrary.record.bvid,
      cid: first.cid,
      title: 'Review',
      ownerName: 'Review',
      parts: [first, second],
      fromOfflineCache: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          forceOffline: true,
          offlineVideoService: ReviewOfflineLibrary(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.localOpenCount, 1);
    await tester.ensureVisible(find.byKey(const Key('part-2')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('part-2')).first);
    await tester.pumpAndSettle();
    expect(service.localOpenCount, 1);
    expect(find.textContaining('仍保留当前分 P'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
