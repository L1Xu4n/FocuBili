import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_download_queue.dart';

import 'course_cache_library_test.dart' show Access;
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;

class _VideoFixtures extends QueueLibrary {
  final attempts = <int>[];
  final failures = <int>{};

  @override
  Future<bool> delete(String bvid, {int? cid}) async {
    expect(cid, isNotNull, reason: 'never delete an entire BV');
    attempts.add(cid!);
    if (failures.contains(cid)) return false;
    final before = ready.length;
    ready.removeWhere((row) => row.bvid == bvid && row.cid == cid);
    return before != ready.length;
  }
}

class _CourseFixtures extends CourseCacheLibrary {
  _CourseFixtures(this.account) : super(access: account);
  final Access account;
  final rows = <CourseCacheEntry>[];
  final attempts = <(int, int)>[];
  bool isBusy = false;

  @override
  bool get busy => isBusy;

  @override
  Future<List<CourseCacheEntry>> entries() async =>
      rows.where((row) => row.mid == account.mid).toList();

  @override
  Future<void> remove(CourseCacheEntry row) async {
    expect(row.mid, account.mid);
    attempts.add((row.mid, row.ep));
    if (busy) throw const CourseCacheFailure('请先暂停进行中的缓存，再删除章节。');
    rows.remove(row);
  }
}

OfflineVideoDownload _video(int cid) {
  final clip = fixture(cid);
  return OfflineVideoDownload(
    bvid: clip.bvid,
    cid: cid,
    title: clip.title,
    coverUrl: '',
    ownerName: clip.ownerName,
    filePath: 'test-$cid.mp4',
    sizeBytes: 42,
    qualityId: 32,
    qualityLabel: '480P',
    duration: clip.duration,
    downloadedAt: DateTime(2026),
    status: OfflineDownloadStatus.ready,
    parts: clip.parts,
  );
}

CourseCacheEntry _course(int episode, {int mid = 51}) => CourseCacheEntry(
  mid: mid,
  season: 11,
  ep: episode,
  aid: 55,
  cid: 31 + episode,
  courseTitle: '实验课程 $mid',
  chapterTitle: '第 $episode 章',
  duration: const Duration(minutes: 1),
  quality: 32,
  videoBytes: 42,
);

OfflineDownloadTask _complete(CourseCacheEntry row) => OfflineDownloadTask(
  video: row.video,
  part: row.part,
  quality: row.quality,
  createdAt: DateTime(2026),
  courseMid: row.mid,
  status: DownloadTaskStatus.completed,
);

Finder _videoCard(int cid) =>
    find.byKey(Key('offline-video-${fixture(cid).bvid}-$cid'));
Finder _courseCard(CourseCacheEntry row) =>
    find.byKey(Key('offline-video-course-${row.id}'));
Finder _checkbox(Finder card) =>
    find.descendant(of: card, matching: find.byType(Checkbox));
Finder get _search => find.byKey(const Key('offline-search'));
Finder get _delete => find.byKey(const Key('delete-selected-offline-videos'));
Finder get _confirm =>
    find.byKey(const Key('confirm-delete-offline-selection'));

Future<void> _sweep(WidgetTester tester, Finder from, Finder to) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.moveTo(tester.getCenter(to));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _showPage(
  WidgetTester tester,
  _VideoFixtures videos,
  OfflineDownloadQueue queue, {
  bool courses = false,
  Size size = const Size(420, 880),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: OfflineVideosPage(
        offlineVideoService: videos,
        downloadQueue: queue,
        includeCourses: courses,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, OfflineDownloadQueue queue) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await queue.close();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'phone checkbox sweep paints and unpaints exact parts without deleting',
    (tester) async {
      final videos = _VideoFixtures()
        ..ready.addAll([for (var i = 1; i <= 4; i++) _video(i)]);
      final queue = OfflineDownloadQueue(library: videos);
      await _showPage(tester, videos, queue);

      await tester.longPress(_videoCard(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(1))).value, isTrue);

      await _sweep(tester, _checkbox(_videoCard(2)), _checkbox(_videoCard(4)));
      expect(find.text('已选 4'), findsOneWidget);
      await _sweep(tester, _checkbox(_videoCard(2)), _checkbox(_videoCard(3)));
      expect(find.text('已选 2'), findsOneWidget);
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(2))).value, isFalse);
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(4))).value, isTrue);
      expect(videos.attempts, isEmpty);

      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(_confirm, findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(videos.attempts, isEmpty);
      expect(find.text('已选 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exit-offline-selection')));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(Key('delete-offline-video-${fixture(2).bvid}-2')),
        findsOneWidget,
      );
      await _close(tester, queue);
    },
  );

  testWidgets(
    'desktop preserves exact hidden selection across queue tab; only successful parts disappear',
    (tester) async {
      final videos = _VideoFixtures()
        ..ready.addAll([_video(1), _video(2), _video(3)])
        ..failures.add(2);
      final ready = [1, 2, 3].map((cid) {
        final v = fixture(cid);
        return OfflineDownloadTask(
          video: v,
          part: v.initialPart,
          quality: 32,
          createdAt: DateTime(2026),
          status: DownloadTaskStatus.completed,
        );
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode(ready.map((task) => task.toJson()).toList()),
      );
      final queue = OfflineDownloadQueue(library: videos);
      await _showPage(tester, videos, queue, size: const Size(1130, 680));
      // A different part of the same BV is actively downloading.
      final active = await queue.enqueue(fixture(8));
      // Make the real queue progress bar determinate on the task tab.
      await tester.pump();
      expect(videos.progress, isNotNull);
      videos.progress!(10, 100);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start-offline-selection')));
      await tester.pumpAndSettle();
      await _sweep(tester, _checkbox(_videoCard(1)), _checkbox(_videoCard(2)));
      expect(find.text('已选 2'), findsOneWidget);

      await tester.tap(find.text('下载队列'));
      await tester.pumpAndSettle();
      expect(_delete, findsNothing);
      expect(find.byKey(Key('download-task-${active.id}')), findsOneWidget);
      await tester.tap(find.text('已缓存'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);

      await tester.enterText(_search, '学习视频 3');
      await tester.pumpAndSettle();
      expect(find.text('所选中有 2 条不在搜索结果中'), findsOneWidget);
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(3))).value, isFalse);
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(find.textContaining('其中 2 条不在当前搜索结果中'), findsOneWidget);
      expect(videos.attempts, isEmpty);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(videos.attempts, [1, 2]);
      expect(videos.ready.map((row) => row.cid), [2, 3]);
      expect(videos.discarded, isEmpty);
      expect(queue.tasks.map((row) => row.part.cid), [2, 3, 8]);
      expect(queue.tasks.last.status, DownloadTaskStatus.downloading);
      expect(find.textContaining('已删除 1 条离线缓存，1 条未删除'), findsOneWidget);

      await tester.enterText(_search, '');
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(2))).value, isTrue);
      expect(tester.widget<Checkbox>(_checkbox(_videoCard(3))).value, isFalse);
      await _close(tester, queue);
    },
  );

  testWidgets(
    'course account switch after confirmation appears never deletes the matching new account lesson',
    (tester) async {
      final ordinary = _VideoFixtures()..ready.add(_video(1));
      final oldCourse = _course(1);
      final newCourse = _course(1, mid: 99);
      final courses = _CourseFixtures(Access())
        ..rows.addAll([oldCourse, newCourse]);
      final queue = OfflineDownloadQueue(
        library: ordinary,
        courseLibrary: courses,
      );
      addTearDown(courses.dispose);
      await _showPage(tester, ordinary, queue, courses: true);

      await tester.longPress(_courseCard(oldCourse));
      await tester.pumpAndSettle();
      await tester.tap(_checkbox(_videoCard(1)));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      courses.account.mid = 99;
      CacheLifecycle.accountChanged();
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();

      expect(ordinary.attempts, [1]);
      expect(courses.attempts, isEmpty);
      expect(courses.rows, [oldCourse, newCourse]);
      expect(find.text('实验课程 99'), findsOneWidget);
      expect(find.textContaining('账号或页面状态已变化'), findsOneWidget);
      await _close(tester, queue);
    },
  );

  testWidgets(
    'course bulk uses busy gate and removes only explicitly selected local lesson and its completed task',
    (tester) async {
      final ordinary = _VideoFixtures();
      final first = _course(1),
          second = _course(2),
          otherAccount = _course(1, mid: 99);
      final courses = _CourseFixtures(Access())
        ..rows.addAll([first, second, otherAccount])
        ..isBusy = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode([for (final row in courses.rows) _complete(row).toJson()]),
      );
      final queue = OfflineDownloadQueue(
        library: ordinary,
        courseLibrary: courses,
      );
      addTearDown(courses.dispose);
      await _showPage(tester, ordinary, queue, courses: true);

      await tester.longPress(_courseCard(first));
      await tester.pumpAndSettle();
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(courses.rows, [first, second, otherAccount]);
      expect(find.textContaining('请先暂停进行中的缓存'), findsOneWidget);
      expect(find.text('已选 1'), findsOneWidget);

      courses.isBusy = false;
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(courses.attempts, [(51, 1), (51, 1)]);
      expect(courses.rows, [second, otherAccount]);
      expect(queue.tasks.map((task) => task.id), [_complete(second).id]);
      final persisted =
          jsonDecode(prefs.getString(OfflineDownloadQueue.storageKey)!)
              as List<dynamic>;
      expect(
        persisted.map(
          (row) => OfflineDownloadTask.fromJson(row as Map<String, dynamic>).id,
        ),
        [_complete(second).id, _complete(otherAccount).id],
      );
      await _close(tester, queue);
    },
  );
}
