import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_download_queue_test.dart' show QueueLibrary;
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;

class _Library extends QueueLibrary {
  final checked = <int>[];

  @override
  Future<List<PreferredPlaybackQuality>> availableQualities(
    VideoPreview video,
    VideoPart part,
  ) async {
    checked.add(part.cid);
    return switch (part.pageNumber) {
      1 => [PreferredPlaybackQuality.p1080, PreferredPlaybackQuality.p720],
      4 => [PreferredPlaybackQuality.p360, PreferredPlaybackQuality.p480],
      5 => [PreferredPlaybackQuality.p4k],
      _ => throw const OfflineVideoException('Unavailable synthetic source'),
    };
  }
}

VideoPreview _video({int partCount = 6, bool course = false}) => VideoPreview(
  bvid: course ? 'cheese:ss2' : 'BV1GJ411x7h7',
  cid: 101,
  title: 'Offline selection',
  ownerName: 'Teacher',
  courseSeasonId: course ? 2 : null,
  parts: [
    for (var i = 1; i <= partCount; i++)
      VideoPart(
        pageNumber: i,
        cid: 100 + i,
        title: 'Section $i',
        duration: const Duration(minutes: 1),
        courseEpisodeId: course ? i + 1000 : null,
        courseAid: course ? i + 2000 : null,
      ),
  ],
);

OfflineVideoDownload _completed(int cid) => OfflineVideoDownload(
  bvid: _video().bvid,
  cid: cid,
  title: 'Cached section',
  coverUrl: '',
  ownerName: 'Teacher',
  filePath: 'memory-only',
  sizeBytes: 1,
  qualityId: 32,
  qualityLabel: '480P',
  duration: const Duration(minutes: 1),
  downloadedAt: DateTime(2026),
  status: OfflineDownloadStatus.ready,
);

final _button = find.byKey(const Key('current-video-offline-download-button'));
final _next = find.byKey(const Key('confirm-offline-parts'));

Finder _checkbox(int cid) => find.descendant(
  of: find.byKey(Key('offline-part-$cid')),
  matching: find.byType(Checkbox),
);

bool _checked(WidgetTester t, int cid) =>
    t.widget<Checkbox>(_checkbox(cid)).value!;

// Player shows an indeterminate busy indicator behind the chooser.
Future<void> _frame(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 420));
  await t.pump();
}

Future<void> _sweep(WidgetTester t, int start, int end) async {
  final gesture = await t.startGesture(t.getCenter(_checkbox(start)));
  await t.pump(kLongPressTimeout + const Duration(milliseconds: 20));
  await gesture.moveTo(t.getCenter(_checkbox(end)));
  await t.pump();
  await gesture.up();
  await _frame(t);
}

Future<void> _show(
  WidgetTester t,
  VideoPreview video,
  _Library library,
  OfflineDownloadQueue queue, {
  Size size = const Size(410, 895),
  AppPlatform appPlatform = AppPlatform.android,
  double textScale = 1,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PlayerPage(
        video: video,
        appPlatform: appPlatform,
        playbackService: FeedbackPlayback(),
        offlineVideoService: library,
        downloadQueue: queue,
      ),
    ),
  );
  await _frame(t);
}

Future<void> _close(WidgetTester t, OfflineDownloadQueue queue) async {
  await t.pumpWidget(const SizedBox.shrink());
  await queue.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('wide cache dialog shortcuts change eligible parts only', (
    t,
  ) async {
    final video = _video(partCount: 16);
    final library = _Library()..ready.add(_completed(102));
    final queue = OfflineDownloadQueue(library: library);
    final queued = await queue.enqueue(
      video,
      part: video.parts[2],
      quality: 32,
    );
    await queue.pause(queued.id);
    await _show(
      t,
      video,
      library,
      queue,
      size: const Size(1280, 800),
      appPlatform: AppPlatform.windows,
    );
    await t.tap(_button);
    await _frame(t);
    final dialog = find.byKey(const Key('offline-part-dialog'));
    expect(t.getSize(find.byKey(const Key('offline-part-options'))).width, 800);
    expect(
      find.descendant(of: dialog, matching: find.text(video.title)),
      findsOneWidget,
    );
    expect(find.text('已选择 1 个分 P'), findsOneWidget);
    expect(find.text('剩余容量'), findsNothing);

    await t.tap(find.byKey(const Key('offline-part-select-all')));
    await _frame(t);
    expect(find.text('已选择 14 个分 P'), findsOneWidget);
    expect(t.widget<Checkbox>(_checkbox(102)).value, isTrue);
    expect(t.widget<Checkbox>(_checkbox(102)).onChanged, isNull);
    expect(t.widget<Checkbox>(_checkbox(103)).value, isFalse);
    expect(t.widget<Checkbox>(_checkbox(103)).onChanged, isNull);

    await t.tap(find.byKey(const Key('offline-part-select-current')));
    await _frame(t);
    expect(find.text('已选择 1 个分 P'), findsOneWidget);
    expect(_checked(t, 104), isFalse);

    await t.tap(find.byKey(const Key('offline-part-clear-selection')));
    await _frame(t);
    expect(find.text('已选择 0 个分 P'), findsOneWidget);
    expect(t.widget<FilledButton>(_next).onPressed, isNull);
    expect(_checked(t, 102), isTrue);
    expect(queue.tasks.single.id, queued.id);
    await _close(t, queue);
  });

  testWidgets('wide picker sweeps through edge scroll with footer pinned', (
    t,
  ) async {
    final video = _video(partCount: 30);
    final library = _Library()..ready.add(_completed(102));
    final queue = OfflineDownloadQueue(library: library);
    await _show(
      t,
      video,
      library,
      queue,
      size: const Size(1280, 760),
      appPlatform: AppPlatform.windows,
    );
    await t.tap(_button);
    await _frame(t);
    final options = find.byKey(const Key('offline-part-options'));
    final footer = t.getCenter(_next);
    final start = t.getCenter(_checkbox(103));
    final g = await t.startGesture(start);
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await g.moveTo(Offset(start.dx, t.getBottomLeft(options).dy - 3));
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await _frame(t);
    expect(t.widget<ListView>(options).controller!.offset, greaterThan(250));
    expect(t.getCenter(_next), footer);
    expect(t.widget<FilledButton>(_next).onPressed, isNotNull);
    expect(t.takeException(), isNull);
    await _close(t, queue);
  });

  testWidgets(
    'short phone keeps scrolling list and sticky action at large text',
    (t) async {
      final video = _video(partCount: 24);
      final library = _Library();
      final queue = OfflineDownloadQueue(library: library);
      await _show(
        t,
        video,
        library,
        queue,
        size: const Size(330, 475),
        textScale: 1.65,
      );
      await t.ensureVisible(_button);
      await t.tap(_button);
      await _frame(t);
      expect(find.byKey(const Key('offline-part-dialog')), findsNothing);
      final options = find.byKey(const Key('offline-part-options'));
      expect(options, findsOneWidget);
      final footer = t.getCenter(_next);
      await t.drag(options, const Offset(0, -250));
      await _frame(t);
      expect(t.widget<ListView>(options).controller!.offset, greaterThan(60));
      expect(t.getCenter(_next), footer);
      expect(find.text('选择清晰度'), findsOneWidget);
      expect(t.takeException(), isNull);
      await _close(t, queue);
    },
  );

  testWidgets(
    'multi-P checkbox sweep selects only eligible CIDs and reports lower quality',
    (t) async {
      final video = _video();
      final library = _Library()..ready.add(_completed(102));
      final queue = OfflineDownloadQueue(library: library);
      final queued = await queue.enqueue(
        video,
        part: video.parts[2],
        quality: 32,
      );
      await queue.pause(queued.id);
      await _show(t, video, library, queue);
      await t.tap(_button);
      await _frame(t);
      expect(find.text('选择缓存分P'), findsOneWidget);
      expect(_checked(t, 101), isTrue);
      expect(find.text('已缓存'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(t.widget<Checkbox>(_checkbox(102)).onChanged, isNull);
      expect(t.widget<Checkbox>(_checkbox(103)).onChanged, isNull);

      await t.tap(_checkbox(104));
      await _frame(t);
      expect(_checked(t, 104), isTrue);
      await t.tap(_checkbox(104));
      await _frame(t);
      expect(_checked(t, 104), isFalse);

      await _sweep(t, 104, 106);
      expect(
        [for (var cid = 104; cid <= 106; cid++) _checked(t, cid)],
        [true, true, true],
      );
      await _sweep(t, 104, 105);
      expect(_checked(t, 104), isFalse);
      expect(_checked(t, 105), isFalse);
      expect(_checked(t, 106), isTrue);
      await _sweep(t, 104, 105);
      await t.tap(_next);
      await _frame(t);
      expect(find.text('下载清晰度'), findsOneWidget);
      expect(library.checked, [101, 104, 105, 106]);
      await t.tap(find.byKey(const Key('download-quality-64')));
      await _frame(t);
      expect(
        [for (final task in queue.tasks) (task.part.cid, task.quality)],
        [(103, 32), (101, 64), (104, 32)],
      );
      expect(queue.tasks.where((task) => task.requireExactQuality).length, 2);
      expect(find.textContaining('P4 → 清晰 480P'), findsOneWidget);
      expect(find.textContaining('未加入 2 个'), findsOneWidget);
      await t.tap(find.text('查看详情'));
      await _frame(t);
      expect(find.text('P4 · 改为 清晰 480P 加入队列'), findsOneWidget);
      expect(find.textContaining('P5 · 所选和更低档位均不可用'), findsOneWidget);
      expect(find.textContaining('P6 · 无法读取下载清晰度'), findsOneWidget);
      expect(find.text('删除离线缓存'), findsNothing);
      await _close(t, queue);
    },
  );

  testWidgets(
    'cached current part opens selector with no new part selected; cancel never deletes',
    (t) async {
      final library = _Library()..ready.add(_completed(101));
      final queue = OfflineDownloadQueue(library: library);
      await _show(t, _video(), library, queue);
      await t.tap(_button);
      await _frame(t);
      expect(find.text('选择缓存分P'), findsOneWidget);
      expect(t.widget<Checkbox>(_checkbox(101)).onChanged, isNull);
      expect(t.widget<FilledButton>(_next).onPressed, isNull);
      await t.tap(find.text('取消'));
      await _frame(t);
      expect(queue.tasks, isEmpty);
      expect(library.ready.single.cid, 101);
      expect(library.checked, isEmpty);
      await _close(t, queue);
    },
  );

  testWidgets(
    'single part keeps direct quality selection; course has no ordinary button',
    (t) async {
      final library = _Library();
      final queue = OfflineDownloadQueue(library: library);
      await _show(t, _video(partCount: 1), library, queue);
      await t.tap(_button);
      await _frame(t);
      expect(find.text('选择缓存分P'), findsNothing);
      expect(find.text('下载清晰度'), findsOneWidget);
      await t.tap(find.byKey(const Key('download-quality-64')));
      await _frame(t);
      expect(queue.tasks.single.part.cid, 101);
      expect(queue.tasks.single.requireExactQuality, isFalse);
      await t.pumpWidget(const SizedBox.shrink());
      await _show(t, _video(course: true), library, queue);
      expect(_button, findsNothing);
      expect(queue.tasks.length, 1);
      await _close(t, queue);
    },
  );

  test(
    'batch queue suppresses concurrent duplicates and cached work; persisted quality remains exact',
    () async {
      final library = _Library()..ready.add(_completed(102));
      final queue = OfflineDownloadQueue(library: library);
      addTearDown(queue.close);
      final video = _video();
      final results = await Future.wait([
        queue.enqueueOrdinaryIfMissing(
          video,
          part: video.parts.first,
          quality: 32,
        ),
        queue.enqueueOrdinaryIfMissing(
          video,
          part: video.parts.first,
          quality: 64,
        ),
        queue.enqueueOrdinaryIfMissing(
          video,
          part: video.parts[1],
          quality: 32,
        ),
      ]);
      expect(results.whereType<OfflineDownloadTask>().length, 1);
      expect(queue.tasks.single.quality, 32);
      final persisted = OfflineDownloadTask.fromJson(
        queue.tasks.single.toJson(),
      );
      expect(persisted.requireExactQuality, isTrue);
      expect(
        persisted
            .copyWith(status: DownloadTaskStatus.paused)
            .requireExactQuality,
        isTrue,
      );
    },
  );
}
