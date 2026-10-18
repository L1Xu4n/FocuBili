import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/content_blocklist_page.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/offline_download_queue.dart';

import 'ab_repeat_capture_lifecycle_test.dart'
    show ReviewAbPlayback, ReviewNoteService;
import 'player_ab_repeat_test.dart'
    show AbOverlay, abVideo, configureAb, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

enum NestedRoute { owner, mention, downloads, blocklist }

class UnavailableNestedPublicContent implements BilibiliPublicContentService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('Synthetic profile unavailable'));
}

class NestedOfflineLibrary extends ReviewOfflineLibrary {
  @override
  Future<List<PreferredPlaybackQuality>> availableQualities(
    VideoPreview video,
    VideoPart part,
  ) async => [PreferredPlaybackQuality.p720];
}

class NestedDownloadQueue extends ChangeNotifier
    implements OfflineDownloadQueue {
  NestedDownloadQueue(this.library);
  @override
  final NestedOfflineLibrary library;
  final entries = <OfflineDownloadTask>[];

  @override
  Stream<OfflineDownloadTask> get completions => const Stream.empty();

  @override
  String? get storageError => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synthetic queue operation');

  @override
  Future<void> initialize() async {}

  @override
  List<OfflineDownloadTask> get tasks => List.unmodifiable(entries);

  @override
  Future<OfflineDownloadTask> enqueue(
    VideoPreview video, {
    VideoPart? part,
    int quality = 32,
  }) async {
    final task = OfflineDownloadTask(
      video: video,
      part: part ?? video.initialPart,
      quality: quality,
      createdAt: DateTime(2026),
      status: DownloadTaskStatus.paused,
    );
    entries.add(task);
    notifyListeners();
    return task;
  }
}

final nestedVideo = VideoPreview(
  bvid: abVideo.bvid,
  cid: 101,
  title: abVideo.title,
  ownerName: abVideo.ownerName,
  ownerMid: 123,
  description: '@Synthetic mention',
  descriptionSegments: const [
    VideoDescriptionSegment(text: '@Synthetic mention', mentionedMid: 456),
  ],
  parts: abVideo.parts,
);

Future<void> mountNested(
  WidgetTester tester,
  ReviewAbPlayback playback,
  ReviewNoteService notes, {
  bool capturing = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (capturing) {
    final now = DateTime(2026, 10, 18);
    await notes.saveNote(
      VideoNote(
        id: 'synthetic-old-note',
        bvid: nestedVideo.bvid,
        videoTitle: nestedVideo.title,
        ownerName: nestedVideo.ownerName,
        partCid: 101,
        partPageNumber: 1,
        partTitle: 'Words',
        title: 'Old note outside AB',
        body: 'Synthetic text',
        createdAt: now,
        updatedAt: now,
        position: const Duration(seconds: 5),
      ),
    );
  }
  final library = NestedOfflineLibrary();
  final queue = NestedDownloadQueue(library);
  addTearDown(queue.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: nestedVideo,
        playbackService: playback,
        playerOverlayService: AbOverlay(),
        offlineVideoService: library,
        downloadQueue: queue,
        videoNoteService: notes,
        publicContentService: UnavailableNestedPublicContent(),
        initialPosition: const Duration(seconds: 20),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await configureAb(tester);
  if (!capturing) return;
  await tester.tap(find.byKey(const ValueKey('player-note-flag-hit-0')));
  await tester.pumpAndSettle();
  final composer = tester.widget<VideoNoteComposer>(
    find.byType(VideoNoteComposer),
  );
  composer.onIncludeFrameChanged(true);
  await tester.pump();
  composer.onSave();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  expect(playback.captures, 1);
  composer.onClose();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<BuildContext> openNested(WidgetTester tester, NestedRoute route) async {
  switch (route) {
    case NestedRoute.owner:
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, nestedVideo.ownerName).first,
          )
          .onTap!();
    case NestedRoute.mention:
      final description = tester.widget<Text>(
        find.byKey(const Key('video-description')),
      );
      final span = description.textSpan! as TextSpan;
      final mention = span.children!.first as TextSpan;
      (mention.recognizer! as TapGestureRecognizer).onTap!();
    case NestedRoute.downloads:
      await tester.ensureVisible(
        find.byKey(const Key('current-video-offline-download-button')).first,
      );
      await tester.tap(
        find.byKey(const Key('current-video-offline-download-button')).first,
      );
      // The covered download button stays busy until this dialog is answered.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('download-quality-64')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The video notice can be above the viewport after scrolling to the library.
      tester
          .widget<TextButton>(
            find
                .ancestor(
                  of: find.text('查看队列').first,
                  matching: find.byType(TextButton),
                )
                .first,
          )
          .onPressed!();
    case NestedRoute.blocklist:
      await tester.tap(find.byKey(const Key('more-settings-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-manage-blocklist')));
  }
  await tester.pumpAndSettle();
  final page = switch (route) {
    NestedRoute.owner || NestedRoute.mention => find.byType(UserProfilePage),
    NestedRoute.downloads => find.byType(OfflineVideosPage),
    NestedRoute.blocklist => find.byType(ContentBlocklistPage),
  };
  expect(page, findsOneWidget);
  return tester.element(page);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final route in NestedRoute.values) {
    testWidgets(
      '${route.name} route cancels late capture restore/resume and discards frame',
      (tester) async {
        final p = ReviewAbPlayback()
          ..captureGate = Completer<void>()
          ..capturedPath = 'synthetic-orphan-frame.png';
        final notes = ReviewNoteService();
        await mountNested(tester, p, notes, capturing: true);
        final routeContext = await openNested(tester, route);
        expect(p.current.isPlaying, isFalse);
        p.captureGate!.complete();
        await tester.pumpAndSettle();
        expect(p.plays, 0);
        expect(p.current.isPlaying, isFalse);
        expect(p.seeks, [const Duration(seconds: 5)]);
        expect(notes.discarded, ['synthetic-orphan-frame.png']);
        Navigator.of(routeContext).pop();
        await tester.pumpAndSettle();
        expect(p.current.isPlaying, isFalse);
        expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await unmountAb(tester);
      },
    );

    for (final playing in [true, false]) {
      testWidgets(
        '${route.name} ordinary route round trip preserves playing=$playing policy',
        (tester) async {
          final p = ReviewAbPlayback();
          await mountNested(tester, p, ReviewNoteService());
          if (!playing) await p.pause();
          await tester.pump();
          final routeContext = await openNested(tester, route);
          expect(p.current.isPlaying, isFalse);
          expect(p.plays, 0);
          Navigator.of(routeContext).pop();
          await tester.pumpAndSettle();
          final resumes = playing && route != NestedRoute.downloads;
          expect(p.current.isPlaying, resumes);
          expect(p.plays, resumes ? 1 : 0);
          expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
          await unmountAb(tester);
        },
      );
    }
  }
}
