import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/watch_history_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:focubili/services/windows_playback_progress_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'course chapters persist independent learning progress, history and timestamp notes',
    () async {
      const course = VideoPreview(
        bvid: 'cheese:ss968174948',
        courseSeasonId: 968174948,
        cid: 101,
        title: 'Course',
        ownerName: 'Teacher',
        parts: [
          VideoPart(
            pageNumber: 1,
            cid: 101,
            title: 'A',
            duration: Duration(seconds: 300),
            courseEpisodeId: 1,
            courseAid: 11,
          ),
          VideoPart(
            pageNumber: 2,
            cid: 102,
            title: 'B',
            duration: Duration(seconds: 400),
            courseEpisodeId: 2,
            courseAid: 12,
          ),
        ],
      );
      final learning = LearningListService();
      await learning.addVideo(course, part: course.parts[0]);
      await learning.addVideo(course, part: course.parts[1]);
      await learning.updateProgress(
        course.bvid,
        part: course.parts[1],
        position: const Duration(seconds: 47),
      );
      final saved = await LearningListService().loadEntries();
      expect(saved, hasLength(2));
      expect(saved.firstWhere((e) => e.partCid == 101).position, Duration.zero);
      expect(saved.firstWhere((e) => e.partCid == 102).position.inSeconds, 47);

      final time = DateTime(2026, 10, 14);
      await WatchHistoryService().record(
        WatchHistoryEntry(
          bvid: course.bvid,
          title: course.title,
          ownerName: course.ownerName,
          lastPartTitle: 'B',
          lastPartPageNumber: 2,
          watchedAt: time,
          lastPosition: const Duration(seconds: 47),
        ),
      );
      final history = await WatchHistoryService().loadHistory();
      expect(history.single.bvid, course.bvid);
      expect(history.single.lastPartPageNumber, 2);
      expect(history.single.lastPosition.inSeconds, 47);

      await VideoNoteService().saveNote(
        VideoNote(
          id: 'course-note',
          bvid: course.bvid,
          videoTitle: course.title,
          ownerName: course.ownerName,
          partCid: 102,
          partPageNumber: 2,
          partTitle: 'B',
          title: 'Cache',
          body: 'Associativity',
          createdAt: time,
          updatedAt: time,
          position: const Duration(seconds: 47),
        ),
      );
      final notes = await VideoNoteService().loadNotesForVideo(course.bvid);
      expect(notes.single.partCid, 102);
      expect(notes.single.position.inSeconds, 47);
      const store = WindowsPlaybackProgressStore();
      for (final part in course.parts) {
        await store.save(
          WindowsPlaybackProgressSnapshot(
            bvid: course.bvid,
            cid: part.cid,
            pageNumber: part.pageNumber,
            position: Duration(seconds: part.pageNumber * 23),
            duration: part.duration,
          ),
        );
      }
      expect((await store.loadPart(course.bvid, 101))!.position.inSeconds, 23);
      expect((await store.loadPart(course.bvid, 102))!.position.inSeconds, 46);
      expect((await store.load(course.bvid))!.cid, 102);
      expect(await store.load('BV1GJ411x7h7'), isNull);
      expect(
        await VideoNoteService().loadNotesForVideo('BV1GJ411x7h7'),
        isEmpty,
      );
    },
  );
}
