import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/download_control.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/offline_video_service.dart';

/// Provides controllable transfers for testing queue lifecycle races.
class QueueLibrary extends OfflineVideoService {
  final started = <int>[];
  final discarded = <int>[];
  final ready = <OfflineVideoDownload>[];
  Completer<OfflineVideoDownload>? pending;
  void Function(int, int?)? progress;

  /// Returns only fixtures already committed by the test.
  @override
  Future<List<OfflineVideoDownload>> loadDownloads() async => ready;

  /// Waits until completion or real cancellation is requested by the queue.
  @override
  Future<OfflineVideoDownload> download(
    VideoPreview video, {
    VideoPart? part,
    int quality = 32,
    void Function(int, int?)? onProgress,
    DownloadControl? control,
  }) {
    started.add((part ?? video.initialPart).cid);
    progress = onProgress;
    final transfer = Completer<OfflineVideoDownload>();
    pending = transfer;
    control?.abort = () {
      if (!transfer.isCompleted) {
        transfer.completeError(const DownloadInterrupted());
      }
    };
    return transfer.future;
  }

  /// Records cleanup without touching real media files.
  @override
  Future<void> discardPartial(String bvid, int cid, int quality) async {
    discarded.add(cid);
  }
}

/// Models a platform preference store that rejects writes without throwing.
class RejectQueueWrites extends Fake implements SharedPreferences {
  /// Starts with no prior queue data.
  @override
  String? getString(String key) => null;

  /// Reports a rejected write, exercising false-success protection.
  @override
  Future<bool> setString(String key, String value) async => false;
}

/// Builds stable per-part identities for deduplication and queue ordering tests.
VideoPreview fixture(int cid) => VideoPreview(
  bvid: 'BV1GJ411x7h7',
  cid: cid,
  title: '学习视频 $cid',
  ownerName: 'UP',
  parts: [
    VideoPart(
      pageNumber: cid,
      cid: cid,
      title: '分P $cid',
      duration: const Duration(seconds: 30),
    ),
  ],
);

/// Flushes microtasks until a specific state becomes observable, with a finite bound.
Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

/// Verifies durable enqueue, cancellation, ordering, progress and corrupt-data handling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'speed excludes resumed bytes, decays on stalls and clears on pause',
    () async {
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(library: library);
      addTearDown(queue.close);
      final task = await queue.enqueue(fixture(1));
      await until(() => library.progress != null);
      library.progress!(1000000, 3000000);
      expect(queue.tasks.single.bytesPerSecond, 0);
      library.progress!(1100000, 3000000);
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(queue.tasks.single.bytesPerSecond, greaterThan(0));
      expect(queue.tasks.single.bytesPerSecond, lessThan(200000));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(queue.tasks.single.bytesPerSecond, 0);
      await queue.pause(task.id);
      expect(queue.tasks.single.bytesPerSecond, 0);
    },
  );

  test(
    'slow OS notifications coalesce to the latest state instead of replaying old downloads',
    () async {
      final firstPublish = Completer<void>();
      final seen = <List<OfflineDownloadTask>>[];
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(
        library: library,
        publishProgress: (snapshot) async {
          seen.add(snapshot);
          if (seen.length == 1) await firstPublish.future;
        },
      );
      await queue.initialize();
      final queued = await queue.enqueue(fixture(1));
      await until(() => library.started.isNotEmpty);
      library.progress!(30, 100);
      await queue.pause(queued.id);
      expect(seen, hasLength(1));
      firstPublish.complete();
      await queue.close();
      expect(seen, hasLength(2));
      expect(seen.last.single.status, DownloadTaskStatus.paused);
      expect(seen.last.single.receivedBytes, 30);
    },
  );

  test(
    'OS timeout pauses both active and queued work without starting the next item',
    () async {
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(library: library);
      addTearDown(queue.close);
      await queue.enqueue(fixture(1));
      await queue.enqueue(fixture(2));
      await until(() => library.started.isNotEmpty);
      await queue.pauseAll();
      expect(library.started, [1]);
      expect(
        queue.tasks.every((task) => task.status == DownloadTaskStatus.paused),
        isTrue,
      );
    },
  );

  test(
    'enqueue returns before transfer finishes and serializes duplicate submissions',
    () async {
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(library: library);
      addTearDown(queue.close);
      final result = await Future.wait([
        queue.enqueue(fixture(1)),
        queue.enqueue(fixture(1)),
        queue.enqueue(fixture(2)),
      ]);
      await until(() => library.started.isNotEmpty);
      expect(result[0].id, result[1].id);
      expect(queue.tasks, hasLength(2));
      expect(library.started, [1]);
      library.progress!(30, 100);
      expect(queue.tasks.first.progress, 0.3);
      await queue.pause(result.first.id);
      await until(() => library.started.length == 2);
      expect(queue.tasks.first.status, DownloadTaskStatus.paused);
      expect(library.started, [1, 2]);
      await queue.pause(result.last.id);
      await queue.resume(result.first.id);
      await until(() => library.started.length == 3);
      expect(library.started, [1, 2, 1]);
      await queue.remove(result.first.id);
      expect(library.discarded, [1]);
      expect(queue.tasks.map((e) => e.part.cid), [2]);
    },
  );

  test(
    'restart restores in-flight tasks paused and does not auto-download',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final video = fixture(1);
      final task = OfflineDownloadTask(
        video: video,
        part: video.initialPart,
        quality: 32,
        createdAt: DateTime(2026),
        status: DownloadTaskStatus.downloading,
        receivedBytes: 30,
        totalBytes: 100,
      );
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode([task.toJson()]),
      );
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(library: library);
      addTearDown(queue.close);
      await queue.initialize();
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      expect(queue.tasks.single.receivedBytes, 30);
      expect(library.started, isEmpty);
      expect(
        prefs.getString(OfflineDownloadQueue.storageKey),
        isNot(contains('Cookie')),
      );
    },
  );

  test('malformed queue is retained and refuses new writes', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(OfflineDownloadQueue.storageKey, 'broken');
    final queue = OfflineDownloadQueue(library: QueueLibrary());
    addTearDown(queue.close);
    await expectLater(queue.initialize(), throwsFormatException);
    await expectLater(queue.enqueue(fixture(1)), throwsFormatException);
    expect(prefs.getString(OfflineDownloadQueue.storageKey), 'broken');
    expect(queue.storageError, isNotNull);
  });

  test(
    'rejected enqueue never starts a transfer or leaves a ghost task',
    () async {
      final library = QueueLibrary();
      final queue = OfflineDownloadQueue(
        library: library,
        preferencesLoader: () async => RejectQueueWrites(),
      );
      addTearDown(queue.close);
      await expectLater(
        queue.enqueue(fixture(1)),
        throwsA(isA<OfflineVideoException>()),
      );
      expect(queue.tasks, isEmpty);
      expect(library.started, isEmpty);
      expect(queue.storageError, isNotNull);
    },
  );

  test(
    'clearing library reconciles completed tasks before downloading again',
    () async {
      final library = QueueLibrary();
      final snapshots = <List<OfflineDownloadTask>>[];
      final queue = OfflineDownloadQueue(
        library: library,
        publishProgress: (value) async {
          snapshots.add(value);
        },
      );
      final task = await queue.enqueue(fixture(1));
      await until(() => library.pending != null);
      final completed = <OfflineDownloadTask>[];
      final subscription = queue.completions.listen(completed.add);
      final file = OfflineVideoDownload(
        bvid: task.video.bvid,
        cid: 1,
        title: 'One',
        coverUrl: '',
        ownerName: 'UP',
        filePath: 'test.mp4',
        sizeBytes: 100,
        qualityId: 32,
        qualityLabel: '480P',
        duration: const Duration(seconds: 30),
        downloadedAt: DateTime(2026),
        status: OfflineDownloadStatus.ready,
      );
      library.ready.add(file);
      library.pending!.complete(file);
      await until(
        () => queue.tasks.single.status == DownloadTaskStatus.completed,
      );
      final prefs = await SharedPreferences.getInstance();
      await until(
        () => prefs
            .getString(OfflineDownloadQueue.storageKey)!
            .contains('completed'),
      );
      expect(
        (await queue.enqueue(fixture(1))).status,
        DownloadTaskStatus.completed,
      );
      library.ready.clear();
      await queue.reconcileCompleted();
      expect(queue.tasks, isEmpty);
      expect(
        jsonDecode(prefs.getString(OfflineDownloadQueue.storageKey)!),
        isEmpty,
      );
      await queue.enqueue(fixture(1));
      await until(() => library.started.length == 2);
      expect(queue.tasks, hasLength(1));
      await queue.close();
      expect(completed, hasLength(1));
      expect(completed.single.id, task.id);
      await subscription.cancel();
      expect(
        snapshots.any(
          (tasks) =>
              tasks.any((task) => task.status == DownloadTaskStatus.completed),
        ),
        isTrue,
      );
    },
  );
}
