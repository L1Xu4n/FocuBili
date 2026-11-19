import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/download_queue_view.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'course_cache_library_test.dart' show Access, part, video;
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class _CourseFixtures extends CourseCacheLibrary {
  _CourseFixtures(this.account) : super(access: account);
  final Access account;
  Completer<List<CourseCacheEntry>>? gate;
  List<CourseCacheEntry> rows = [];
  CourseCacheEntry? removed;
  late DateTime now;

  @override
  Future<List<CourseCacheEntry>> entries() async =>
      await (gate?.future ?? Future.value(rows));

  @override
  Future<void> remove(CourseCacheEntry entry) async {
    removed = entry;
    rows = [];
  }

  @override
  bool isUsable(CourseCacheEntry entry) => entry.usableAt(now);

  @override
  Duration? untilExpiry(CourseCacheEntry entry) => entry.until?.difference(now);
}

CourseCacheEntry _record(DateTime now, {int mid = 51}) => CourseCacheEntry(
  mid: mid,
  season: 11,
  ep: 21,
  aid: 55,
  cid: 31,
  courseTitle: video.title,
  chapterTitle: part.title,
  duration: part.duration,
  quality: 64,
  videoBytes: 102400,
  checkedAt: now,
  until: now.add(const Duration(seconds: 10)),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'shared queue copies only a failed course task’s fixed diagnostic code',
    (tester) async {
      final courses = _CourseFixtures(Access());
      final queue = OfflineDownloadQueue(
        library: QueueLibrary(),
        courseLibrary: courses,
      );
      const allowed = 'course-cache/v1/playback/drmUnknown';
      final lesson = OfflineDownloadTask(
        video: video,
        part: part,
        quality: 64,
        createdAt: DateTime.utc(2026),
        courseMid: 51,
        status: DownloadTaskStatus.failed,
        error: '当前无法确认本章能否离线缓存。',
      ).toJson();
      final forgedLesson = {
        ...lesson,
        'cid': 999,
        'courseEpisodeId': 999,
        'courseDiagnostic': 'course-cache/v1/playback/SESSDATA=unexpected',
      };
      final ordinary = fixture(171);
      SharedPreferences.setMockInitialValues({
        OfflineDownloadQueue.storageKey: jsonEncode([
          {...lesson, 'courseDiagnostic': allowed},
          forgedLesson,
          {
            ...OfflineDownloadTask(
              video: ordinary,
              part: ordinary.initialPart,
              quality: 32,
              createdAt: DateTime.utc(2026),
              status: DownloadTaskStatus.failed,
              error: '旧任务',
            ).toJson(),
            'courseDiagnostic': allowed,
          },
        ]),
      });
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await queue.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadQueueView(queue: queue)),
        ),
      );
      final copy = find.byTooltip('复制故障编号');
      expect(queue.tasks, hasLength(3));
      expect(
        queue.tasks.where((task) => task.courseDiagnostic != null),
        hasLength(1),
      );
      expect(copy, findsOneWidget);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(clipboard, [allowed]);
      expect(find.text('已复制故障编号，不含账号或下载地址。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await queue.close();
      courses.dispose();
    },
  );

  testWidgets(
    'mixed inventory shares search, size, delete and expiring course status',
    (tester) async {
      final a = Access();
      final courses = _CourseFixtures(a)..now = DateTime.utc(2026, 11, 19);
      final entry = _record(courses.now);
      courses.rows = [entry];
      final videos = QueueLibrary()..ready.add(ReviewOfflineLibrary.record);
      final queue = OfflineDownloadQueue(
        library: videos,
        courseLibrary: courses,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineVideosPage(
            downloadQueue: queue,
            offlineVideoService: videos,
            includeCourses: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final course = find.byKey(Key('offline-video-course-${entry.id}'));
      expect(course, findsOneWidget);
      expect(find.text(ReviewOfflineLibrary.record.title), findsWidgets);
      expect(find.byTooltip('课程缓存'), findsNothing);
      final search = find.byKey(const Key('offline-search'));
      await tester.enterText(search, part.title);
      await tester.pumpAndSettle();
      expect(course, findsOneWidget);
      expect(find.text(ReviewOfflineLibrary.record.title), findsNothing);
      courses.now = courses.now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('需联网复核'), findsOneWidget);

      await tester.tap(
        find.byKey(Key('delete-offline-video-course-${entry.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(courses.removed, same(entry));
      expect(course, findsNothing);
      expect(videos.ready, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await queue.close();
      courses.dispose();
    },
  );

  testWidgets('account switch ignores old private inventory results', (
    tester,
  ) async {
    final access = Access();
    final courses = _CourseFixtures(access)..now = DateTime.utc(2026, 11, 19);
    final stale = Completer<List<CourseCacheEntry>>();
    courses.gate = stale;
    final videos = QueueLibrary();
    final queue = OfflineDownloadQueue(library: videos, courseLibrary: courses);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineVideosPage(
          downloadQueue: queue,
          offlineVideoService: videos,
          includeCourses: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    courses.gate = null;
    access.mid = 99;
    CacheLifecycle.accountChanged();
    stale.complete([_record(courses.now)]);
    await tester.pumpAndSettle();
    expect(find.text(video.title), findsNothing);
    expect(find.byKey(const Key('offline-videos-empty')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await queue.close();
    courses.dispose();
  });
}
