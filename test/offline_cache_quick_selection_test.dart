import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_cache_locations.dart';
import 'package:focubili/services/offline_download_queue.dart';

import 'course_cache_library_test.dart' show Access;
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;

class _VideoFixtures extends QueueLibrary {
  _VideoFixtures({super.cacheLocations});
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

VideoPreview _clip(int cid, {String? bvid}) {
  final source = fixture(cid);
  return VideoPreview(
    bvid: bvid ?? 'BV1GJ411x7h$cid',
    cid: cid,
    title: source.title,
    ownerName: source.ownerName,
    parts: source.parts,
  );
}

const _groupBvid = 'BV1GJ411x7h7';
const _partMetadata = [
  VideoPart(
    pageNumber: 2,
    cid: 88,
    title: '微分基础',
    duration: Duration(minutes: 1),
  ),
  VideoPart(
    pageNumber: 3,
    cid: 31,
    title: '未缓存环节',
    duration: Duration(minutes: 1),
  ),
  VideoPart(
    pageNumber: 4,
    cid: 10,
    title: '积分练习',
    duration: Duration(minutes: 1),
  ),
];

OfflineVideoDownload _video(int cid, {bool grouped = false}) {
  final clip = _clip(cid, bvid: grouped ? _groupBvid : null);
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
    originalTitle: grouped ? '数学专题' : '',
    parts: grouped ? _partMetadata : clip.parts,
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
    find.byKey(Key('offline-video-${_clip(cid).bvid}-$cid'));
Finder _courseCard(CourseCacheEntry row) =>
    find.byKey(Key('offline-video-course-${row.id}'));
Finder _checkbox(Finder card) =>
    find.descendant(of: card, matching: find.byType(Checkbox));
Finder get _location => find.byKey(const Key('offline-cache-location'));
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
  Widget Function(PlayerPage player)? playerBuilder,
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
        playerBuilder: playerBuilder,
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
    'completed same-BV saved Ps group and exact search opens an offline CID',
    (tester) async {
      final videos = _VideoFixtures()
        ..ready.addAll([
          _video(10, grouped: true),
          _video(2),
          _video(88, grouped: true),
        ]);
      final queue = OfflineDownloadQueue(library: videos);
      PlayerPage? opened;
      await _showPage(
        tester,
        videos,
        queue,
        playerBuilder: (player) {
          opened = player;
          return const Scaffold(body: Text('本地播放器测试替身'));
        },
      );
      final group = find.byKey(const Key('offline-video-group-$_groupBvid'));
      expect(group, findsOneWidget);
      expect(_videoCard(2), findsOneWidget);
      expect(find.text('数学专题'), findsOneWidget);
      expect(find.text('2 P 已缓存 · 84 B'), findsOneWidget);
      expect(
        find.descendant(of: group, matching: find.byTooltip('删除')),
        findsNothing,
      );

      await tester.enterText(_search, '积分');
      await tester.pumpAndSettle();
      expect(group, findsOneWidget);
      expect(_videoCard(2), findsNothing);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(find.text('下载队列'), findsNothing);
      expect(find.byTooltip('清空全部'), findsNothing);
      expect(
        tester.getTopLeft(find.text('微分基础')).dy,
        lessThan(tester.getTopLeft(find.text('积分练习')).dy),
      );
      expect(find.text('未缓存环节'), findsNothing);
      await tester.enterText(_search, 'P03');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的离线视频'), findsOneWidget);
      await tester.enterText(_search, 'p 04');
      await tester.pumpAndSettle();
      expect(find.text('积分练习'), findsOneWidget);
      expect(find.text('微分基础'), findsNothing);
      await tester.tap(find.text('积分练习'));
      await tester.pump();
      final player = opened!;
      expect(player.video.bvid, _groupBvid);
      expect(player.initialPartCid, 10);
      expect(player.forceOffline, isTrue);
      await _close(tester, queue);
    },
  );

  testWidgets(
    'child sweep toggles and deletes only explicitly selected cached P',
    (tester) async {
      final videos = _VideoFixtures()
        ..ready.addAll([
          _video(10, grouped: true),
          _video(88, grouped: true),
          _video(2),
        ]);
      final queue = OfflineDownloadQueue(library: videos);
      PlayerPage? opened;
      await _showPage(
        tester,
        videos,
        queue,
        playerBuilder: (player) {
          opened = player;
          return const Scaffold(body: Text('本地播放器测试替身'));
        },
      );
      final group = find.byKey(const Key('offline-video-group-$_groupBvid'));
      await tester.tap(group);
      await tester.pumpAndSettle();
      final p2 = find.byKey(const Key('offline-video-$_groupBvid-88'));
      final p4 = find.byKey(const Key('offline-video-$_groupBvid-10'));
      await tester.longPress(p2);
      await tester.pumpAndSettle();
      await _sweep(tester, _checkbox(p4), _checkbox(p2));
      expect(find.text('已选 2'), findsOneWidget);
      await _sweep(tester, _checkbox(p4), _checkbox(p4));
      expect(find.text('已选 1'), findsOneWidget);
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除本机的 1 条'), findsOneWidget);
      expect(videos.attempts, isEmpty);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(videos.attempts, [88]);
      expect(p2, findsNothing);
      expect(p4, findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(group, findsNothing);
      // The root singleton now goes straight to the offline player, not a second list.
      await tester.tap(p4);
      await tester.pump();
      expect(opened!.initialPartCid, 10);
      await _close(tester, queue);
    },
  );

  testWidgets(
    'child per-part delete confirms its P and keeps a paused same-CID task',
    (tester) async {
      final videos = _VideoFixtures()..ready.add(_video(10, grouped: true));
      final paused = OfflineDownloadTask(
        video: _clip(88, bvid: _groupBvid),
        part: _partMetadata.first,
        quality: 64,
        createdAt: DateTime(2026),
        status: DownloadTaskStatus.paused,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode([paused.toJson()]),
      );
      final queue = OfflineDownloadQueue(library: videos);
      await queue.initialize();
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      // A ready record becomes readable after the paused queue was restored.
      videos.ready.add(_video(88, grouped: true));
      await _showPage(tester, videos, queue);
      await tester.tap(
        find.byKey(const Key('offline-video-group-$_groupBvid')),
      );
      await tester.pumpAndSettle();
      final delete = find.byKey(
        const Key('delete-offline-video-$_groupBvid-88'),
      );
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.textContaining('P2 微分基础'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(videos.attempts, isEmpty);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(videos.attempts, [88]);
      expect(videos.ready.map((video) => video.cid), [10]);
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      expect(videos.discarded, isEmpty);
      await _close(tester, queue);
    },
  );

  testWidgets(
    'root sweep and confirmation capture exact group members before newly cached P appears',
    (tester) async {
      final videos = _VideoFixtures()
        ..ready.addAll([
          _video(10, grouped: true),
          _video(88, grouped: true),
          _video(2),
        ]);
      final queue = OfflineDownloadQueue(library: videos);
      await _showPage(tester, videos, queue);
      final group = find.byKey(const Key('offline-video-group-$_groupBvid'));
      await tester.tap(find.byTooltip('多选管理'));
      await tester.pumpAndSettle();
      await _sweep(tester, _checkbox(group), _checkbox(_videoCard(2)));
      expect(find.text('已选 2'), findsOneWidget);
      await _sweep(tester, _checkbox(_videoCard(2)), _checkbox(group));
      expect(find.text('已选 0'), findsOneWidget);
      await _sweep(tester, _checkbox(group), _checkbox(_videoCard(2)));

      await tester.enterText(_search, '学习视频 2');
      await tester.pumpAndSettle();
      expect(find.text('所选中有 2 条不在搜索结果中'), findsOneWidget);
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除本机的 3 条'), findsOneWidget);
      expect(find.textContaining('包括 1 个分P组'), findsOneWidget);
      expect(videos.attempts, isEmpty);
      videos.ready.add(_video(31, grouped: true));
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除本机的 3 条'), findsOneWidget);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(videos.attempts, [88, 10, 2]);
      expect(videos.ready.map((video) => video.cid), [31]);
      await _close(tester, queue);
    },
  );

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
        find.byKey(Key('delete-offline-video-${_clip(2).bvid}-2')),
        findsOneWidget,
      );
      await _close(tester, queue);
    },
  );

  testWidgets(
    'desktop preserves exact hidden selection across queue tab; only successful parts disappear',
    (tester) async {
      final videos =
          _VideoFixtures(
              cacheLocations: OfflineCacheLocations(
                platform: AppPlatform.windows,
              ),
            )
            ..ready.addAll([_video(1), _video(2), _video(3)])
            ..failures.add(2);
      final ready = [1, 2, 3].map((cid) {
        final v = _clip(cid);
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
      final queue = OfflineDownloadQueue(
        library: videos,
        clock: () => DateTime(2026, 1, 2),
      );
      await _showPage(tester, videos, queue, size: const Size(1130, 680));
      // A different part of the same BV is actively downloading.
      final active = await queue.enqueue(_clip(8, bvid: _clip(1).bvid));
      // Make the real queue progress bar determinate on the task tab.
      await tester.pump();
      expect(videos.progress, isNotNull);
      videos.progress!(10, 100);
      await tester.pumpAndSettle();

      expect(_location, findsOneWidget);
      await tester.tap(find.byKey(const Key('start-offline-selection')));
      await tester.pumpAndSettle();
      expect(_location, findsNothing);
      await _sweep(tester, _checkbox(_videoCard(1)), _checkbox(_videoCard(2)));
      expect(find.text('已选 2'), findsOneWidget);

      await tester.tap(find.text('下载队列'));
      await tester.pumpAndSettle();
      expect(_delete, findsNothing);
      expect(_location, findsOneWidget);
      expect(find.byKey(Key('download-task-${active.id}')), findsOneWidget);
      await tester.tap(find.text('已缓存'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);
      expect(_location, findsNothing);

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
