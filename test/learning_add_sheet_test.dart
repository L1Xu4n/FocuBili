import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/features/learning/learning_video_launcher.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/models/public_profile.dart';
import 'learning_batch_test.dart' show video;

VideoPreview partsVideo() => VideoPreview(
  bvid: 'BVparts',
  cid: 101,
  title: '完整课程',
  ownerName: '作者',
  parts: [
    for (var i = 1; i <= 5; i++)
      VideoPart(
        pageNumber: i,
        cid: 100 + i,
        title: '第$i课',
        duration: const Duration(minutes: 2),
      ),
  ],
);

class CollectionContent implements BilibiliPublicContentService {
  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  }) async => CreatorContentPage(
    items: [
      for (var i = 1; i <= 2; i++)
        CreatorVideo(
          bvid: 'BV$i',
          title: '课程$i',
          coverUrl: '',
          duration: const Duration(minutes: 1),
        ),
    ],
    page: page,
    hasMore: false,
    totalCount: 2,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CollectionDetails implements BilibiliService {
  final hold = Completer<VideoPreview>();
  final calls = <String>[];
  bool failSecond = false, blocked = true;
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    calls.add(input);
    if (blocked) return hold.future;
    if (failSecond && input == 'BV2') throw StateError('network');
    return partsVideo();
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

  Widget host(LearningListService service, {double scale = 1}) => MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: TextButton(
            onPressed: () => LearningAddSheet.show(
              context,
              video: partsVideo(),
              service: service,
            ),
            child: const Text('选择 P'),
          ),
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
    expect(find.textContaining('新增 5 · 已存在 0 · 剩余容量 2'), findsOneWidget);
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
      expect(find.textContaining('新增 4 · 已存在 1'), findsOneWidget);
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
    CollectionDetails details,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => LearningAddSheet.showCollection(
                context,
                ownerMid: 1,
                collectionId: 1,
                contentService: CollectionContent(),
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
    await tester.tap(find.text('选择已加载视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步（2 支）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'cancel collection detail loading discards result and stops next lookup',
    (tester) async {
      final learning = await service(), details = CollectionDetails();
      await openCollection(tester, learning, details);
      expect(find.text('读取所选视频分 P'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      details.hold.complete(partsVideo());
      await tester.pumpAndSettle();
      expect(details.calls, ['BV1']);
      expect(await learning.loadEntries(), isEmpty);
      expect(find.text('选择加入的分 P'), findsNothing);
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
