import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_access.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'course_cache_library_test.dart'
    show Access, FixtureTransfer, part, video;
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 500 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Access access;
  late FixtureTransfer transfer;
  late CourseCacheLibrary courses;
  late QueueLibrary ordinary;
  late OfflineDownloadQueue queue;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('unified-course-queue');
    transfer = FixtureTransfer();
    access = Access()..now = DateTime.now();
    access.media = OfflineMediaPlan(
      video: OfflineMediaTrack(
        id: 64,
        urls: ['https://cdn.bilivideo.com/synthetic'],
        expectedBytes: transfer.payload.length,
      ),
    );
    courses = CourseCacheLibrary(
      access: access,
      root: () async => root,
      downloader: transfer,
      clock: () => access.now,
    );
    ordinary = QueueLibrary();
    queue = OfflineDownloadQueue(library: ordinary, courseLibrary: courses);
  });
  tearDown(() async {
    await queue.close();
    courses.dispose();
    await root.delete(recursive: true);
  });

  test(
    'old ordinary queue migrates with no private metadata in the old key',
    () async {
      final regular = fixture(part.cid);
      final task = OfflineDownloadTask(
        video: regular,
        part: regular.initialPart,
        quality: 32,
        createdAt: DateTime.utc(2026),
      );
      final legacy = jsonEncode([task.toJson()]);
      SharedPreferences.setMockInitialValues({
        'focubili_download_queue_v2': legacy,
      });
      await queue.initialize();
      expect(queue.tasks.single.id, task.id);
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('focubili_download_queue_v2'), legacy);
      expect(prefs.getString(OfflineDownloadQueue.storageKey), isNotNull);
    },
  );

  test(
    'private receipt and its completed task are restored only for its owner',
    () async {
      final lesson = await queue.enqueue(video, part: part, quality: 64);
      await _waitFor(
        () => queue.tasks.single.status == DownloadTaskStatus.completed,
      );
      await queue.close();
      access.mid = 99;
      queue = OfflineDownloadQueue(library: ordinary, courseLibrary: courses);
      await queue.initialize();
      expect(queue.tasks, isEmpty);

      access.mid = 51;
      CacheLifecycle.accountChanged();
      await _waitFor(
        () => queue.tasks.singleOrNull?.status == DownloadTaskStatus.completed,
      );
      expect(queue.tasks.single.id, lesson.id);
      expect((await courses.entries()).single.hasMedia, isTrue);
    },
  );

  test(
    'legacy course history uses first observation, not authorization age',
    () async {
      final downloaded = access.now;
      await queue.enqueue(video, part: part, quality: 64);
      await _waitFor(
        () => queue.tasks.single.status == DownloadTaskStatus.completed,
      );
      await queue.close();

      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(OfflineDownloadQueue.storageKey)!) as List;
      (stored.single as Map).remove('completedAt');
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode(stored),
      );
      final firstSeen = downloaded.add(const Duration(days: 21));
      var now = firstSeen;
      queue = OfflineDownloadQueue(
        library: ordinary,
        courseLibrary: courses,
        clock: () => now,
      );
      await queue.initialize();
      expect(queue.tasks.single.completedAt, firstSeen);
      expect((await courses.entries()).single.hasMedia, isTrue);

      await queue.close();
      now = firstSeen.add(const Duration(days: 14));
      queue = OfflineDownloadQueue(
        library: ordinary,
        courseLibrary: courses,
        clock: () => now,
      );
      await queue.initialize();
      expect(queue.tasks, isEmpty);
      final receipt = (await courses.entries()).single;
      final playback = await courses.open(receipt);
      expect(await File(playback.video).readAsBytes(), transfer.payload);
    },
  );

  test(
    'same CID uses isolated identity, shares FIFO, retains guarded receipt on task deletion',
    () async {
      final regular = await queue.enqueue(fixture(part.cid));
      final lesson = await queue.enqueue(video, part: part, quality: 64);
      expect(lesson.id, 'course:51:11-21-55-31');
      expect(regular.id, isNot(lesson.id));
      expect(OfflineDownloadTask.fromJson(lesson.toJson()).id, lesson.id);
      expect(transfer.starts, isEmpty);
      await queue.pause(regular.id);
      await _waitFor(
        () => queue.tasks.last.status == DownloadTaskStatus.completed,
      );
      final receipt = (await courses.entries()).single;
      final playback = await courses.open(receipt);
      expect(await File(playback.video).readAsBytes(), transfer.payload);
      await queue.remove(lesson.id);
      expect((await courses.entries()).single.id, receipt.id);
      expect(ordinary.discarded, isEmpty);
    },
  );

  test(
    'explicitly denied course fails without network media; retry re-authorizes',
    () async {
      access.failure = const CourseCacheAccessException(
        '无法验证购买。',
        stage: CourseCacheStage.purchase,
        reason: CourseCacheReason.entitlementNotConfirmed,
      );
      final lesson = await queue.enqueue(video, part: part, quality: 64);
      await _waitFor(
        () => queue.tasks.single.status == DownloadTaskStatus.failed,
      );
      expect(queue.tasks.single.error, '无法验证购买。');
      const code = 'course-cache/v1/purchase/entitlementNotConfirmed';
      expect(queue.tasks.single.courseDiagnostic?.code, code);
      expect(transfer.starts, isEmpty);
      await queue.close();
      access.mid = 99;
      queue = OfflineDownloadQueue(library: ordinary, courseLibrary: courses);
      await queue.initialize();
      expect(queue.tasks, isEmpty);
      access.mid = 51;
      CacheLifecycle.accountChanged();
      await _waitFor(
        () => queue.tasks.singleOrNull?.status == DownloadTaskStatus.failed,
      );
      expect(queue.tasks.single.courseDiagnostic?.code, code);
      access.failure = null;
      await queue.resume(lesson.id);
      await _waitFor(
        () => queue.tasks.single.status == DownloadTaskStatus.completed,
      );
      expect(queue.tasks.single.error, isNull);
      expect(queue.tasks.single.courseDiagnostic, isNull);
      expect(access.calls, 2);
    },
  );

  test(
    'account switch interrupts and hides a private task until its owner returns',
    () async {
      transfer.pausePoint = Completer<void>();
      transfer.allow = Completer<void>();
      final lesson = await queue.enqueue(video, part: part, quality: 64);
      await transfer.pausePoint!.future;
      access.mid = 99;
      CacheLifecycle.accountChanged();
      await courses.settled.catchError((Object _) {});
      expect(queue.tasks, isEmpty);
      await queue.resume(lesson.id);
      expect(transfer.starts, hasLength(1));
      access.mid = 51;
      CacheLifecycle.accountChanged();
      await _waitFor(
        () => queue.tasks.singleOrNull?.status == DownloadTaskStatus.paused,
      );
      await queue.remove(lesson.id);
      final partials = await root
          .list(recursive: true)
          .where(
            (file) =>
                file.path.endsWith('.part') || file.path.endsWith('.resume'),
          )
          .toList();
      expect(partials, isEmpty);
    },
  );
}
