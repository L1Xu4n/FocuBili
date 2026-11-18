import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/features/learning/learning_video_launcher.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/models/public_profile.dart';
import 'learning_batch_test.dart' show video;

VideoPreview partsVideo([int count = 5]) => VideoPreview(
  bvid: 'BVparts',
  cid: 101,
  title: '完整课程',
  ownerName: '作者',
  parts: [
    for (var i = 1; i <= count; i++)
      VideoPart(
        pageNumber: i,
        cid: 100 + i,
        title: '第$i课',
        duration: const Duration(minutes: 2),
      ),
  ],
);

class CollectionContent implements BilibiliPublicContentService {
  const CollectionContent({this.paged = false});

  final bool paged;

  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  }) async => CreatorContentPage(
    items: [
      for (final i in paged ? [page] : [1, 2])
        CreatorVideo(
          bvid: 'BV$i',
          title: '课程$i',
          coverUrl: '',
          duration: const Duration(minutes: 1),
        ),
    ],
    page: page,
    hasMore: paged && page == 1,
    totalCount: 2,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CollectionDetails implements BilibiliService {
  final hold = Completer<VideoPreview>();
  final calls = <String>[];
  bool failSecond = false, blocked = true, distinct = false;
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    calls.add(input);
    if (blocked) return hold.future;
    if (failSecond && input == 'BV2') throw StateError('network');
    final lesson = partsVideo();
    if (!distinct) return lesson;
    return VideoPreview(
      bvid: input,
      cid: lesson.cid,
      title: '完整课程 $input',
      ownerName: lesson.ownerName,
      parts: lesson.parts,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<LearningListService> service() async {
    final prefs = await SharedPreferences.getInstance();
    return LearningListService(preferencesLoader: () async => prefs);
  }

  Widget host(LearningListService service, {double scale = 1, int count = 5}) =>
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => LearningAddSheet.show(
                context,
                video: partsVideo(count),
                service: service,
              ),
              child: const Text('选择 P'),
            ),
          ),
        ),
      );
  testWidgets('98 tasks + all5 disabled, cancel unchanged, large text fits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = await service();
    await s.addBatch([
      for (var i = 1; i <= 98; i++)
        LearningPartSelection(video(i), video(i).initialPart),
    ]);
    await tester.pumpWidget(host(s, scale: 1.6));
    await tester.tap(find.text('选择 P'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部 P'));
    await tester.pumpAndSettle();
    expect(find.text('剩余容量 2'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '超过100条上限'),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect((await s.loadEntries()).length, 98);
  });
  testWidgets(
    'all P appends in page order; repeating preserves existing state',
    (tester) async {
      final s = await service();
      await s.addParts(partsVideo(), [partsVideo().parts[1]]);
      await tester.pumpWidget(host(s));
      await tester.tap(find.text('选择 P'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部 P'));
      await tester.pumpAndSettle();
      expect(find.text('剩余容量 99'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
      await tester.pumpAndSettle();
      expect((await s.loadEntries()).map((e) => e.partCid), [
        102,
        101,
        103,
        104,
        105,
      ]);
    },
  );
  Finder optionCheckbox(int page) => find.descendant(
    of: find.widgetWithText(ListTile, 'P$page 第$page课'),
    matching: find.byType(Checkbox),
  );

  bool checked(WidgetTester tester, int page) =>
      tester.widget<Checkbox>(optionCheckbox(page)).value!;

  Future<TestGesture> longPressCheckbox(WidgetTester tester, int page) async {
    final gesture = await tester.startGesture(
      tester.getCenter(optionCheckbox(page)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    return gesture;
  }

  Future<void> open(
    WidgetTester tester,
    LearningListService learning, {
    int count = 5,
  }) async {
    await tester.pumpWidget(host(learning, count: count));
    await tester.tap(find.text('选择 P'));
    await tester.pumpAndSettle();
  }

  testWidgets('prechecks prior P; deselecting it never deletes or updates it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = await service();
    final video = partsVideo();
    final state = await s.createFolder('复习');
    await s.addBatch([
      LearningPartSelection(
        video,
        video.parts[3],
        position: const Duration(seconds: 48),
        status: LearningListStatus.completed,
      ),
    ], folderId: state.folders.single.id);
    final existing = (await s.loadEntries()).single;
    await open(tester, s);

    expect(find.text('剩余容量 99'), findsOneWidget);
    expect(find.textContaining('已存在'), findsNothing);
    expect(find.textContaining('保留学习进度'), findsNothing);
    expect(checked(tester, 1), isTrue); // Keep the existing default-P behavior.
    expect(checked(tester, 2), isFalse);
    expect(checked(tester, 4), isTrue); // Not simply the default/current P.
    final Finder existingLabel = find.text('P4 第4课');
    final semantics = tester.ensureSemantics();
    try {
      await tester.pump();
      expect(
        tester.getSemantics(existingLabel),
        isSemantics(
          label: 'P4 第4课',
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
    } finally {
      semantics.dispose();
    }

    // Both title and checkbox remain ordinary tap targets.
    await tester.ensureVisible(existingLabel);
    await tester.pumpAndSettle();
    await tester.tap(existingLabel);
    await tester.pumpAndSettle();
    await tester.ensureVisible(optionCheckbox(2));
    await tester.pumpAndSettle();
    await tester.tap(optionCheckbox(2));
    await tester.pumpAndSettle();
    expect(checked(tester, 4), isFalse);
    expect(checked(tester, 2), isTrue);
    await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
    await tester.pumpAndSettle();

    final entries = await s.loadEntries();
    expect(entries.map((entry) => entry.partCid), [101, 102, 104]);
    expect(
      entries.singleWhere((entry) => entry.partCid == 104).toJson(),
      existing.toJson(),
    );
  });

  testWidgets('a skipped-row drag paints the whole range; reverse can clear', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = await service();
    await open(tester, s);
    TestGesture gesture = await longPressCheckbox(tester, 2);
    final p5 = tester.getCenter(optionCheckbox(5));
    final p3 = tester.getCenter(optionCheckbox(3));
    await gesture.moveTo(p5);
    await tester.pump();
    expect([
      for (var p = 1; p <= 5; p++) checked(tester, p),
    ], everyElement(true));
    await gesture.moveTo(p3);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(checked(tester, 5), isTrue);

    gesture = await longPressCheckbox(tester, 4);
    await gesture.moveTo(tester.getCenter(optionCheckbox(2)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      [for (var p = 1; p <= 5; p++) checked(tester, p)],
      [true, false, false, false, true],
    );
    await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
    await tester.pumpAndSettle();
    expect((await s.loadEntries()).map((entry) => entry.partCid), [101, 105]);
  });

  testWidgets('prechecked duplicates do not use the last available slot', (
    tester,
  ) async {
    final s = await service();
    final lesson = partsVideo();
    await s.addBatch([
      for (var i = 1; i <= 98; i++)
        LearningPartSelection(video(i), video(i).initialPart),
      LearningPartSelection(lesson, lesson.parts[3]),
    ]);
    await open(tester, s);
    expect(find.text('剩余容量 1'), findsOneWidget);
    expect(checked(tester, 4), isTrue);
    final confirm = find.widgetWithText(FilledButton, '确认加入');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(optionCheckbox(2));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '超过100条上限'))
          .onPressed,
      isNull,
    );

    await tester.tap(optionCheckbox(1));
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final entries = await s.loadEntries();
    expect(entries.length, 100);
    expect(
      entries
          .where((entry) => entry.bvid == lesson.bvid)
          .map((entry) => entry.partCid),
      [104, 102],
    );
  });

  testWidgets(
    'edge drag crosses recycled rows, scrolls back, and cancels cleanly',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = await service();
      await open(tester, s, count: 60);
      final Finder list = find.byKey(const Key('learning-part-options'));
      final ScrollController controller = tester
          .widget<ListView>(list)
          .controller!;
      final Rect viewport = tester.getRect(list);
      final point = tester.getCenter(optionCheckbox(2));

      // A quick swipe on a checkbox is scrolling, not a selection gesture.
      await tester.dragFrom(point, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(checked(tester, 2), isFalse);

      final down = await longPressCheckbox(tester, 2);
      await down.moveTo(Offset(point.dx, viewport.bottom - 2));
      for (var frame = 0; frame < 65; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, greaterThan(650));
      expect(optionCheckbox(2), findsNothing);
      final capped = [
        for (var p = 3; p <= 60; p++)
          if (optionCheckbox(p).hitTestable().evaluate().isNotEmpty &&
              checked(tester, p))
            p,
      ];
      expect(capped.last, greaterThanOrEqualTo(15));
      await down.up();
      await tester.pumpAndSettle();
      final double bottom = controller.offset;

      final up = await longPressCheckbox(tester, capped.first);
      await up.moveTo(Offset(point.dx, viewport.top + 2));
      for (var frame = 0; frame < 35; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, lessThan(bottom - 300));
      expect(checked(tester, 10), isFalse);
      await up.cancel();
      await tester.pump();
      final double canceled = controller.offset;
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.offset, canceled);
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(await s.loadEntries(), isEmpty);
    },
  );

  test(
    'invalid CID refuses saved position and leaves original task intact',
    () async {
      final s = await service();
      await s.addVideo(video(1), position: const Duration(seconds: 30));
      final entry = (await s.loadEntries()).single;
      expect(
        () => LearningVideoLauncher.buildPlayerPage(partsVideo(), entry),
        throwsException,
      );
      expect((await s.loadEntries()).single.position.inSeconds, 30);
    },
  );
  Future<void> openCollection(
    WidgetTester tester,
    LearningListService learning,
    CollectionDetails details, {
    bool paged = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => LearningAddSheet.showCollection(
                context,
                ownerMid: 1,
                collectionId: 1,
                contentService: CollectionContent(paged: paged),
                videoService: details,
                service: learning,
              ),
              child: const Text('批量'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('批量'));
    await tester.pumpAndSettle();
    if (paged) {
      expect(find.text('课程1'), findsOneWidget);
      expect(find.text('课程2'), findsNothing);
      await tester.tap(find.text('加载下一页'));
      await tester.pumpAndSettle();
      expect(find.text('课程2'), findsOneWidget);
    }
    await tester.tap(find.text('选择已加载视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步（2 支）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('all parts of a complete two-page collection commit together', (
    tester,
  ) async {
    final learning = await service();
    final details = CollectionDetails()
      ..blocked = false
      ..distinct = true;
    await openCollection(tester, learning, details, paged: true);
    await tester.pumpAndSettle();
    expect(details.calls, ['BV1', 'BV2']);
    expect(await learning.loadEntries(), isEmpty);
    await tester.tap(find.text('全部 P'));
    await tester.pumpAndSettle();
    expect(find.text('剩余容量 100'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
    await tester.pumpAndSettle();
    final entries = await learning.loadEntries();
    expect(entries.map((entry) => entry.stableId), [
      for (final bvid in ['BV1', 'BV2'])
        for (var cid = 101; cid <= 105; cid++) '$bvid:$cid',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancel collection detail loading discards result and stops next lookup',
    (tester) async {
      final learning = await service(), details = CollectionDetails();
      await openCollection(tester, learning, details);
      expect(find.text('读取所选视频分 P'), findsOneWidget);
      await tester.tap(find.text('取消'));
      // Complete before the reverse animation has disposed the dialog.
      details.hold.complete(partsVideo());
      await tester.pumpAndSettle();
      expect(details.calls, ['BV1']);
      expect(await learning.loadEntries(), isEmpty);
      expect(find.text('加入学习清单'), findsNothing);
      final retry = CollectionDetails()..blocked = false;
      await openCollection(tester, learning, retry);
      await tester.pumpAndSettle();
      expect(find.text('加入学习清单'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await learning.loadEntries(), isEmpty);
    },
  );
  testWidgets(
    'partial collection detail failure requires confirmation before selecting and saving',
    (tester) async {
      final learning = await service();
      final details = CollectionDetails()
        ..blocked = false
        ..failSecond = true;
      await openCollection(tester, learning, details);
      await tester.pumpAndSettle();
      expect(find.text('部分视频详情读取失败'), findsOneWidget);
      expect(await learning.loadEntries(), isEmpty);
      await tester.tap(find.text('继续选择成功项'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
      await tester.pumpAndSettle();
      expect((await learning.loadEntries()).length, 1);
    },
  );
}
