import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/features/profile/playback_speeds_dialog.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'offline_download_queue_test.dart' show QueueLibrary;
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

/// Keeps both source paths observable without requiring native media in widget tests.
class FeedbackPlayback extends ReviewLocalPlayback {
  int onlineOpens = 0;
  int localOpens = 0;
  double rate = 1;
  Duration? openedPosition;

  /// Emits complete online playback state for quality and local-source switching.
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    onlineOpens++;
    openedPosition = initialPosition;
    controller.add(
      PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        position: initialPosition ?? const Duration(seconds: 20),
        duration: const Duration(minutes: 2),
        currentQuality: quality,
        availableQualities: const [PlaybackQuality(id: 64, label: '720P')],
      ),
    );
  }

  /// Records local media opens and their requested resume position.
  @override
  Future<void> openLocalFile({
    required String filePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  }) async {
    localOpens++;
    openedPosition = initialPosition;
    controller.add(
      PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        position: initialPosition ?? Duration.zero,
        duration: const Duration(minutes: 2),
      ),
    );
  }

  /// Records custom rates without calling the Android platform channel.
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    rate = speed;
  }
}

/// Returns either a cached entry or selectable download qualities without network access.
class FeedbackLibrary extends ReviewOfflineLibrary {
  /// Selects cached membership for source-switch or new-download scenarios.
  FeedbackLibrary({this.cached = true});
  final bool cached;

  /// Uses only the in-memory completed record.
  @override
  Future<List<OfflineVideoDownload>> loadDownloads() async =>
      cached ? [ReviewOfflineLibrary.record] : [];

  /// Supplies two qualities so enqueue selection can be verified exactly.
  @override
  Future<List<PreferredPlaybackQuality>> availableQualities(
    VideoPreview video,
    VideoPart part,
  ) async => [PreferredPlaybackQuality.p720, PreferredPlaybackQuality.p480];
}

const video = VideoPreview(
  bvid: 'BV1GJ411x7h7',
  cid: 137649199,
  title: 'Online lesson',
  ownerName: 'Teacher',
  description: 'Complete online description',
  duration: Duration(minutes: 2),
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 137649199,
      title: 'Lesson',
      duration: Duration(minutes: 2),
    ),
  ],
);

/// Covers the changed user workflows only, not unrelated application behavior.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('custom rates protect 1x, remove defaults and reject above 5x', (
    tester,
  ) async {
    List<double> result = PlaybackPreferences.defaultSpeeds;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => PlaybackSpeedsDialog(
                    speeds: PlaybackPreferences.defaultSpeeds,
                    onChanged: (speeds) async => result = speeds,
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InputChip>(find.byKey(const Key('configured-speed-1.0')))
          .onDeleted,
      isNull,
    );
    tester
        .widget<InputChip>(find.byKey(const Key('configured-speed-0.75')))
        .onDeleted!();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('custom-playback-speed-input')),
      '5.1',
    );
    await tester.tap(find.byKey(const Key('add-playback-speed')));
    await tester.pump();
    expect(find.text('请输入 0.5 到 5 之间的倍速'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('custom-playback-speed-input')),
      '5',
    );
    await tester.tap(find.byKey(const Key('add-playback-speed')));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(result, [1, 1.25, 1.5, 2, 3, 5]);
    await const PlaybackPreferencesService().savePlaybackSpeeds(result);
    expect(
      (await const PlaybackPreferencesService().load()).playbackSpeeds,
      result,
    );
  });

  testWidgets(
    'favorites search finds videos across folders and deduplicates BV',
    (tester) async {
      final service = AppFavoritesService();
      for (final name in ['Folder A', 'Folder B']) {
        final folder = (await service.createFolder(name))!;
        await service.addItem(
          AppFavoriteItem(
            folderId: folder.id,
            bvid: video.bvid,
            title: 'Flutter lesson',
            coverUrl: '',
            ownerName: 'Teacher',
            durationText: '2:00',
            addedAt: DateTime(2026),
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(home: AppFavoriteFoldersPage(favoritesService: service)),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('app-favorite-folders-search'));
      for (final query in ['flutter', 'teacher', 'bv1gj411x7h7']) {
        await tester.enterText(input, query);
        await tester.pump();
        expect(
          find.byKey(Key('app-favorite-result-${video.bvid}')),
          findsOneWidget,
        );
      }
      await tester.enterText(input, 'Folder A');
      await tester.pump();
      expect(find.text('没有匹配的收藏视频'), findsOneWidget);
    },
  );

  testWidgets('online page selects local quality in place and switches back', (
    tester,
  ) async {
    await const PlaybackPreferencesService().savePreferOfflineCache(true);
    await const PlaybackPreferencesService().savePlaybackSpeeds([1, 4.5]);
    final backend = FeedbackPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: backend,
          offlineVideoService: FeedbackLibrary(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backend.onlineOpens, 1);
    expect(backend.localOpens, 0);
    expect(find.text('已缓存'), findsOneWidget);
    expect(find.text('简介'), findsNothing);
    backend.controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
        isPlaying: true,
        currentQuality: 64,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('speed-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speed-4.5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quality-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quality-local-cache')));
    await tester.pumpAndSettle();
    expect(backend.localOpens, 1);
    expect(backend.openedPosition, const Duration(seconds: 20));
    expect(backend.rate, 4.5);
    expect(find.text('Online lesson'), findsWidgets);
    await tester.tap(find.byKey(const Key('quality-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quality-64')));
    await tester.pumpAndSettle();
    expect(backend.onlineOpens, 2);
    expect(backend.openedPosition, const Duration(seconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('download prompts for quality and enqueue hint expires', (
    tester,
  ) async {
    final queue = OfflineDownloadQueue(library: QueueLibrary());
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: FeedbackPlayback(),
          offlineVideoService: FeedbackLibrary(cached: false),
          downloadQueue: queue,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('current-video-offline-download-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('下载清晰度'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-quality-32')));
    await tester.pumpAndSettle();
    expect(queue.tasks.single.quality, 32);
    expect(find.text('已加入下载队列'), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('已加入下载队列'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await queue.close();
  });
}
