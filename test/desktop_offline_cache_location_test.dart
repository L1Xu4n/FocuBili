import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_cache_locations.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'course_cache_library_test.dart' as course;
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;

class _Cookies implements BilibiliCookieStore {
  @override
  Future<void> clearBilibiliCookies() async {}
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String cookieHeader) async {}
}

class _DialogLocations extends OfflineCacheLocations {
  _DialogLocations() : super(platform: AppPlatform.windows);

  String? path;
  bool cancel = false, reject = false;

  @override
  Future<({String? path, bool available})> status() async =>
      (path: path, available: true);

  @override
  Future<bool> choose() async {
    if (reject) throw const OfflineCacheLocationException('此文件夹不可写。');
    if (cancel) return false;
    path = 'D:/视频/FocuBili-Offline-xyz';
    return true;
  }

  @override
  Future<void> reset() async => path = null;
}

Future<void> _waitFor(bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready() && clock.elapsed < const Duration(seconds: 4)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

Future<void> _status(
  OfflineDownloadQueue queue,
  OfflineDownloadTask task,
  DownloadTaskStatus status,
) => _waitFor(
  () => queue.tasks.any((e) => e.id == task.id && e.status == status),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp, system, selected;
  late OfflineCacheLocations locations;
  OfflineCacheSelection? choice;

  OfflineCacheLocations makeLocations() => OfflineCacheLocations(
    platform: AppPlatform.windows,
    pickDirectory: () async => choice,
  );

  OfflineVideoService library({
    Future<int> Function(File output)? transfer,
    OfflineCacheLocations? registry,
  }) => OfflineVideoService(
    directoryLoader: () async => system,
    cacheLocations: registry ?? locations,
    cookieStore: _Cookies(),
    requestText: (_, _) async => jsonEncode({
      'code': 0,
      'data': {
        'quality': 32,
        'durl': [
          {'url': 'https://cdn.bilivideo.com/synthetic.mp4'},
        ],
      },
    }),
    downloadFile: (_, _, output, report) async {
      final bytes = transfer == null
          ? await output.writeAsBytes([1, 2, 3]).then((_) => 3)
          : await transfer(output);
      report(bytes, bytes);
      return bytes;
    },
  );

  Future<void> chooseSelected() async {
    choice = (path: selected.path, bookmark: null);
    expect(await locations.choose(), isTrue);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final tmpDir = await Directory.systemTemp.createTemp('focubili_locations_');
    tmp = Directory(await tmpDir.resolveSymbolicLinks());
    system = await Directory.fromUri(tmp.uri.resolve('system/')).create();
    selected = await Directory.fromUri(tmp.uri.resolve('picked/')).create();
    choice = null;
    locations = makeLocations();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test(
    'choose, cancel, reselect and reset preserve the old registered root',
    () async {
      final userDir = await Directory.fromUri(
        selected.uri.resolve('FocuBili-Offline-existing/'),
      ).create();
      final note = await File.fromUri(
        userDir.uri.resolve('keep.txt'),
      ).writeAsString('user file');
      expect(await locations.activeId(), isNull);
      expect(await locations.choose(), isFalse);
      expect(await locations.registeredIds(), isEmpty);
      await chooseSelected();
      final active = (await locations.activeId())!;
      final root = await locations.requireRoot(active);
      expect(root.parent.uri, selected.uri);
      expect(root.uri, isNot(userDir.uri));

      choice = null;
      expect(await locations.choose(), isFalse);
      expect(await makeLocations().activeId(), active);
      choice = (path: note.path, bookmark: null);
      await expectLater(
        locations.choose(),
        throwsA(isA<OfflineCacheLocationException>()),
      );
      expect(await locations.activeId(), active);
      await locations.reset();
      final restarted = makeLocations();
      expect(await restarted.activeId(), isNull);
      expect(await restarted.registeredIds(), [active]);
      expect((await restarted.requireRoot(active)).path, root.path);
      expect(await note.readAsString(), 'user file');
      await chooseSelected();
      expect(await locations.activeId(), active);
      expect(await locations.registeredIds(), [active]);
    },
  );

  test(
    'macOS restores selected folder access and never falls back if revoked',
    () async {
      final canonical = await selected.resolveSymbolicLinks();
      var authorized = true;
      OfflineCacheLocations makeMac() => OfflineCacheLocations(
        platform: AppPlatform.macos,
        pickDirectory: () async =>
            (path: canonical, bookmark: 'opaque-bookmark'),
        restoreDirectory: (bookmark) async {
          expect(bookmark, 'opaque-bookmark');
          return authorized ? canonical : null;
        },
      );
      final mac = makeMac();
      expect(await mac.choose(), isTrue);
      final active = (await mac.activeId())!;
      expect((await makeMac().status()).available, isTrue);
      authorized = false;
      expect((await makeMac().status()).available, isFalse);
      await expectLater(
        makeMac().requireRoot(active),
        throwsA(isA<OfflineCacheLocationException>()),
      );
      expect(await makeMac().activeId(), active);
    },
  );

  test('only desktop platforms read this setting or open a picker', () async {
    await chooseSelected();
    for (final platform in [
      AppPlatform.android,
      AppPlatform.ios,
      AppPlatform.unsupported,
    ]) {
      final mobile = OfflineCacheLocations(
        platform: platform,
        pickDirectory: () async => throw StateError('no picker on mobile'),
      );
      expect(mobile.supported, isFalse);
      expect(await mobile.choose(), isFalse);
      expect(await mobile.activeId(), isNull);
      expect(await mobile.registeredIds(), isEmpty);
      await mobile.reset();
    }
    expect(await locations.activeId(), isNotNull);
    for (final platform in [
      AppPlatform.windows,
      AppPlatform.macos,
      AppPlatform.linux,
    ]) {
      expect(OfflineCacheLocations(platform: platform).supported, isTrue);
    }
  });

  test(
    'finished, running and queued video jobs stay in their original root',
    () async {
      final running = Completer<void>(), release = Completer<void>();
      final offline = library(
        transfer: (output) async {
          if (output.uri.pathSegments.last.startsWith('2-')) {
            running.complete();
            await release.future;
          }
          await output.writeAsBytes([1, 2, 3]);
          return 3;
        },
      );
      final queue = OfflineDownloadQueue(library: offline);
      try {
        final initial = await queue.enqueue(fixture(1));
        await _status(queue, initial, DownloadTaskStatus.completed);
        final active = await queue.enqueue(fixture(2));
        await running.future.timeout(const Duration(seconds: 3));
        final pending = await queue.enqueue(fixture(3));
        expect(queue.tasks.last.status, DownloadTaskStatus.queued);
        await chooseSelected();
        final custom = (await locations.activeId())!;
        final newTask = await queue.enqueue(fixture(4));
        expect(newTask.cacheLocationId, custom);
        expect([initial, active, pending].map((e) => e.cacheLocationId), [
          null,
          null,
          null,
        ]);
        release.complete();
        for (final task in [active, pending, newTask]) {
          await _status(queue, task, DownloadTaskStatus.completed);
        }
        final items = await offline.loadDownloads();
        expect(items.map((e) => e.cid), unorderedEquals([1, 2, 3, 4]));
        for (final record in items) {
          expect(await File(record.filePath).readAsBytes(), [1, 2, 3]);
          final path = record.cid == 4
              ? (await locations.requireRoot(custom)).uri
              : system.uri;
          expect(File(record.filePath).parent.parent.parent.uri, path);
        }
        await locations.reset();
        expect(await offline.isDownloaded(fixture(4).bvid, cid: 4), isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        await queue.close();
      }
    },
  );

  test(
    'resume after restart uses saved location and includes legacy jobs',
    () async {
      await chooseSelected();
      final custom = (await locations.activeId())!;
      final root = await locations.requireRoot(custom);
      final customTask = OfflineDownloadTask(
        video: fixture(8),
        part: fixture(8).initialPart,
        quality: 32,
        cacheLocationId: custom,
        status: DownloadTaskStatus.downloading,
        createdAt: DateTime.now(),
      );
      final legacy = OfflineDownloadTask(
        video: fixture(9),
        part: fixture(9).initialPart,
        quality: 32,
        createdAt: DateTime.now(),
      );
      final partial = File.fromUri(
        root.uri.resolve(
          'offline_videos/${customTask.video.bvid}/8-32-video.part',
        ),
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes([1]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode([customTask.toJson(), legacy.toJson()]),
      );
      await locations.reset();
      final offline = library(
        registry: makeLocations(),
        transfer: (output) async {
          if (output.uri.pathSegments.last.startsWith('8-')) {
            expect(output.path, partial.path);
            expect(await output.readAsBytes(), [1]);
          } else {
            expect(output.parent.parent.parent.uri, system.uri);
          }
          await output.writeAsBytes([1, 2, 3]);
          return 3;
        },
      );
      final queue = OfflineDownloadQueue(library: offline);
      try {
        await queue.initialize();
        expect(
          queue.tasks.map((e) => e.status),
          everyElement(DownloadTaskStatus.paused),
        );
        for (final task in [customTask, legacy]) {
          await queue.resume(task.id);
          await _status(queue, task, DownloadTaskStatus.completed);
        }
        expect(await partial.exists(), isFalse);
        expect((await offline.loadDownloads()).length, 2);
      } finally {
        await queue.close();
      }
    },
  );

  test(
    'unplugged storage does not erase records or silently reroute transfers',
    () async {
      final offline = library();
      final firstQueue = OfflineDownloadQueue(library: offline);
      try {
        final one = await firstQueue.enqueue(fixture(1));
        await _status(firstQueue, one, DownloadTaskStatus.completed);
        await chooseSelected();
        final two = await firstQueue.enqueue(fixture(2));
        await _status(firstQueue, two, DownloadTaskStatus.completed);
      } finally {
        await firstQueue.close();
      }
      final original = await selected.resolveSymbolicLinks();
      final moved = await selected.rename('$original-detached');
      final queue = OfflineDownloadQueue(library: offline);
      try {
        await queue.initialize();
        expect(queue.tasks.length, 2);
        expect((await offline.loadDownloads()).single.cid, 1);
        await queue.reconcileCompleted();
        expect(queue.tasks.length, 2);

        final three = await queue.enqueue(fixture(3));
        await _status(queue, three, DownloadTaskStatus.failed);
        expect(queue.tasks.last.error, contains('目录不可用'));
        expect(await Directory(original).exists(), isFalse);
        expect(await offline.clearAll(), isTrue);
        expect(await offline.loadDownloads(), isEmpty);

        await moved.rename(original);
        expect((await offline.loadDownloads()).single.cid, 2);
        await queue.resume(three.id);
        await _status(queue, three, DownloadTaskStatus.completed);
        expect(
          (await offline.loadDownloads()).map((e) => e.cid),
          unorderedEquals([2, 3]),
        );
      } finally {
        await queue.close();
      }
    },
  );

  test(
    'rejects a cache subdirectory redirected at unrelated files',
    () async {
      await chooseSelected();
      final root = await locations.requireRoot((await locations.activeId())!);
      final userFiles = await Directory.fromUri(
        tmp.uri.resolve('unrelated/'),
      ).create();
      final userFile = await File.fromUri(
        userFiles.uri.resolve('2-32-video.part'),
      ).writeAsString('user file');
      await Link.fromUri(
        root.uri.resolve('offline_videos'),
      ).create(userFiles.path);
      final offline = library();
      final queue = OfflineDownloadQueue(library: offline);
      try {
        final task = await queue.enqueue(fixture(2));
        await _status(queue, task, DownloadTaskStatus.failed);
        await expectLater(
          queue.remove(task.id),
          throwsA(isA<OfflineCacheLocationException>()),
        );
        expect(await userFile.readAsString(), 'user file');
      } finally {
        await queue.close();
      }
    },
    skip: Platform.isWindows
        ? 'Creating symlinks can require Developer Mode.'
        : false,
  );

  test(
    'course roots keep account scope, original receipts and safe deletion',
    () async {
      final transfer = course.FixtureTransfer();
      final access = course.Access()
        ..now = DateTime.utc(2026, 11, 19)
        ..media = OfflineMediaPlan(
          video: OfflineMediaTrack(
            id: 64,
            urls: ['https://cdn.bilivideo.com/synthetic-course.mp4'],
            expectedBytes: transfer.payload.length,
          ),
        );
      final courses = CourseCacheLibrary(
        access: access,
        root: () async => system,
        cacheLocations: locations,
        clock: () => access.now,
        downloader: transfer,
      );
      final queue = OfflineDownloadQueue(
        library: library(),
        courseLibrary: courses,
      );
      const part2 = VideoPart(
        pageNumber: 2,
        cid: 32,
        title: '第二节',
        duration: Duration(minutes: 4),
        courseEpisodeId: 22,
        courseAid: 56,
      );
      const course2 = VideoPreview(
        bvid: 'cheese:ss11',
        courseSeasonId: 11,
        cid: 32,
        title: '合成物理课堂',
        ownerName: '测试',
        parts: [part2],
      );
      try {
        final old = await queue.enqueue(course.video, quality: 64);
        await _status(queue, old, DownloadTaskStatus.completed);
        final oldEntry = (await courses.entries()).single;
        await chooseSelected();
        final custom = (await locations.activeId())!;
        final newTask = await queue.enqueue(course2, quality: 64);
        await _status(queue, newTask, DownloadTaskStatus.completed);
        final entries = await courses.entries();
        expect(entries.map((e) => e.cacheLocationId), [null, custom]);
        final oldPlayer = await courses.open(oldEntry);
        final customPlayer = await courses.open(entries.last);
        expect(await File(oldPlayer.video).readAsBytes(), transfer.payload);
        expect(await File(customPlayer.video).readAsBytes(), transfer.payload);

        final extra = await File.fromUri(
          File(customPlayer.video).parent.uri.resolve('notes.txt'),
        ).writeAsString('keep');
        access.mid = 92;
        CacheLifecycle.accountChanged();
        expect(await courses.entries(), isEmpty);
        await expectLater(
          courses.open(entries.last),
          throwsA(isA<CourseCacheFailure>()),
        );
        await expectLater(
          courses.remove(entries.last),
          throwsA(isA<CourseCacheFailure>()),
        );
        access.mid = 51;
        CacheLifecycle.accountChanged();

        access.denied = true;
        final recheck = await queue.enqueue(
          course.video,
          quality: 64,
          revalidateCourse: true,
        );
        expect(recheck.cacheLocationId, isNull);
        await _status(queue, recheck, DownloadTaskStatus.failed);
        await expectLater(
          courses.open(oldEntry),
          throwsA(isA<CourseCacheFailure>()),
        );
        await courses.remove(entries.last);
        expect(await extra.readAsString(), 'keep');
        expect(await File(customPlayer.video).exists(), isFalse);
      } finally {
        await queue.close();
        courses.dispose();
      }
    },
  );

  testWidgets('offline settings choose, cancel, report error and reset', (
    tester,
  ) async {
    final dialog = _DialogLocations();
    final offline = QueueLibrary(cacheLocations: dialog);
    final queue = OfflineDownloadQueue(library: offline);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineVideosPage(
          downloadQueue: queue,
          offlineVideoService: offline,
          includeCourses: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('离线缓存位置'));
    await tester.pumpAndSettle();
    expect(find.text('系统默认位置'), findsOneWidget);
    dialog.cancel = true;
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('系统默认位置'), findsOneWidget);
    dialog.cancel = false;
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();
    expect(find.text(dialog.path!), findsOneWidget);
    dialog.reject = true;
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('此文件夹不可写。'), findsOneWidget);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(find.text('系统默认位置'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await queue.close();
  });

  testWidgets('offline page has no settings entry on mobile', (tester) async {
    final offline = QueueLibrary(
      cacheLocations: OfflineCacheLocations(platform: AppPlatform.android),
    );
    final queue = OfflineDownloadQueue(library: offline);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineVideosPage(
          downloadQueue: queue,
          offlineVideoService: offline,
          includeCourses: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('离线缓存位置'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await queue.close();
  });
}
