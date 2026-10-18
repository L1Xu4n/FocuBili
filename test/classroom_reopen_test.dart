import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_video_launcher.dart';
import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'bilibili_course_service_test.dart' show purchasedResponse;
import 'package:focubili/features/focus/focus_video_launcher.dart';
import 'package:focubili/models/focus_session.dart';

BilibiliVideoInfoService fixtureService() => BilibiliVideoInfoService(
  requestJson: (_) async =>
      throw StateError('A course storage key must never call UGC'),
  courseService: BilibiliCourseService(
    readCookies: () async => 'synthetic',
    requestJson: (uri, _) async {
      if (uri.path.endsWith('/my/paid')) return purchasedResponse;
      expect(uri.path, '/pugv/view/web/season');
      expect(uri.queryParameters['season_id'], '968174948');
      return jsonEncode({
        'code': 0,
        'data': {
          'season_id': 968174948,
          'title': 'Synthetic course',
          'episodes': [
            {'id': 1, 'aid': 11, 'cid': 101, 'title': 'First', 'duration': 300},
            {
              'id': 2,
              'aid': 12,
              'cid': 102,
              'title': 'Second',
              'duration': 400,
            },
          ],
          'episode_page': {'total': 2, 'next': false},
        },
      });
    },
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'course focus bookmark with removed CID is rejected instead of using another chapter',
    () async {
      final video = await fixtureService().lookupVideo('cheese:ss968174948');
      final session = FocusSession.start(
        id: 'synthetic-focus',
        goal: 'Synthetic',
        plannedDuration: const Duration(minutes: 25),
        now: DateTime(2026),
        sourceBvid: video.bvid,
        sourcePartCid: 999,
        sourcePosition: const Duration(seconds: 47),
      );
      expect(
        () => FocusVideoLauncher.buildPlayerPage(video, session),
        throwsA(isA<BilibiliLookupException>()),
      );
    },
  );

  testWidgets(
    'missing classroom note CID never falls back to the same page number or first chapter',
    (tester) async {
      final notes = VideoNoteService();
      final time = DateTime(2026, 10, 17);
      final note = VideoNote(
        id: 'missing-chapter',
        bvid: 'cheese:ss968174948',
        videoTitle: 'Synthetic course',
        ownerName: 'Synthetic teacher',
        partCid: 999,
        partPageNumber: 2,
        partTitle: 'Removed',
        title: 'Synthetic note',
        body: '',
        createdAt: time,
        updatedAt: time,
        position: const Duration(seconds: 47),
      );
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: VideoNoteDetailPage(
            note: note,
            noteService: notes,
            videoService: fixtureService(),
            playerBuilder: (_, _, _) {
              opened = true;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-video-source-card')).first);
      await tester.pumpAndSettle();
      expect(opened, isFalse);
      expect(find.text('原课程章节已失效，请从课程目录重新选择。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'persisted learning entry rehydrates course context before launcher builds player',
    () async {
      final service = fixtureService();
      final video = await service.lookupVideo('cheese:ss968174948');
      final learning = LearningListService();
      await learning.addVideo(video, part: video.parts[1]);
      await learning.updateProgress(
        video.bvid,
        part: video.parts[1],
        position: const Duration(seconds: 47),
      );
      final saved = (await LearningListService().loadEntries()).single;
      final restored = await service.lookupVideo(saved.bvid);
      final player = LearningVideoLauncher.buildPlayerPage(
        restored,
        saved,
        videoService: service,
      );
      expect(player.video.isCourse, isTrue);
      expect(player.video.courseSeasonId, 968174948);
      expect(player.initialPartCid, 102);
      expect(player.initialPosition, const Duration(seconds: 47));
      expect(player.video.parts[1].courseEpisodeId, 2);
      expect(player.video.parts[1].courseAid, 12);
    },
  );

  testWidgets(
    'saved note source card reopens exact classroom chapter and timestamp',
    (tester) async {
      final notes = VideoNoteService();
      final time = DateTime(2026, 10, 17);
      await notes.saveNote(
        VideoNote(
          id: 'synthetic-course-note',
          bvid: 'cheese:ss968174948',
          videoTitle: 'Synthetic course',
          ownerName: 'Synthetic teacher',
          partCid: 102,
          partPageNumber: 2,
          partTitle: 'Second',
          title: 'Synthetic note',
          body: 'Synthetic body',
          createdAt: time,
          updatedAt: time,
          position: const Duration(seconds: 47),
        ),
      );
      final saved = (await notes.loadNotesForVideo(
        'cheese:ss968174948',
      )).single;
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: VideoNoteDetailPage(
            note: saved,
            noteService: notes,
            videoService: fixtureService(),
            playerBuilder: (video, cid, position) {
              opened = true;
              expect(video.isCourse, isTrue);
              expect(video.courseSeasonId, 968174948);
              expect(
                video.parts
                    .singleWhere((part) => part.cid == cid)
                    .courseEpisodeId,
                2,
              );
              expect(position, const Duration(seconds: 47));
              return const Scaffold(body: Text('Classroom chapter restored'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-video-source-card')).first);
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(find.text('Classroom chapter restored'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
