import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/features/learning/learning_video_launcher.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';
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
}
