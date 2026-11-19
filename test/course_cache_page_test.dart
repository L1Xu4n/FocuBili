import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'course_cache_library_test.dart' show Access, part, video;
import 'offline_download_queue_test.dart' show QueueLibrary;
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
