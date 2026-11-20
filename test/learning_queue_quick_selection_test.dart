import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'learning_batch_test.dart' show video;

Finder _row(int id) => find.byKey(Key('learning-list-BV$id:$id'));

Finder _checkbox(int id) =>
    find.descendant(of: _row(id), matching: find.byType(Checkbox));

bool _checked(WidgetTester tester, int id) =>
    tester.widget<Checkbox>(_checkbox(id)).value!;

Future<TestGesture> _holdCheckbox(WidgetTester tester, int id) async {
  final gesture = await tester.startGesture(tester.getCenter(_checkbox(id)));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
  return gesture;
}

Future<void> _showQueue(
  WidgetTester tester,
  LearningListService service,
  Size size,
) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: LearningListPage(learningListService: service)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'long press enters selection; sweep paints through completed rows',
    (tester) async {
      final service = LearningListService();
      for (var i = 1; i <= 4; i++) {
        await service.addVideo(video(i));
      }
      await service.updateStatus(
        'BV4',
        LearningListStatus.completed,
        partCid: 4,
      );
      await _showQueue(tester, service, const Size(480, 1100));

      await tester.longPress(find.text('课程1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      expect(_checked(tester, 1), isTrue);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

      final select = await _holdCheckbox(tester, 2);
      await select.moveTo(tester.getCenter(_checkbox(4)));
      await tester.pump();
      expect(
        [for (var id = 1; id <= 4; id++) _checked(tester, id)],
        [true, true, true, true],
      );
      // Reversing the sweep does not undo items already traversed.
      await select.moveTo(tester.getCenter(_checkbox(3)));
      await select.up();
      await tester.pumpAndSettle();
      expect(find.text('已选 4'), findsOneWidget);

      final clear = await _holdCheckbox(tester, 4);
      await clear.moveTo(tester.getCenter(_checkbox(2)));
      await clear.up();
      await tester.pumpAndSettle();
      expect(
        [for (var id = 1; id <= 4; id++) _checked(tester, id)],
        [true, false, false, false],
      );
      expect((await service.loadEntries()).map((entry) => entry.partCid), [
        1,
        2,
        3,
        4,
      ]);

      // Ordinary row taps toggle the checkbox, never open a video in this mode.
      await tester.tap(find.text('课程1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0'), findsOneWidget);
      await tester.tap(find.text('课程1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);

      for (final action in ['取消', '移除']) {
        final removeSelected = find.text('移除所选（1）');
        await tester.ensureVisible(removeSelected);
        await tester.tap(removeSelected);
        await tester.pumpAndSettle();
        expect(find.text('移除 1 条任务？观看记录和笔记保留。'), findsOneWidget);
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }
      expect((await service.loadEntries()).map((entry) => entry.partCid), [
        2,
        3,
        4,
      ]);
      await tester.tap(find.byTooltip('结束多选'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_handle_rounded), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing a same-length folder result cancels the old drag', (
    tester,
  ) async {
    final service = LearningListService();
    final first = (await service.createFolder('甲组')).folders.single;
    final second = (await service.createFolder('乙组')).folders.last;
    for (final (id, folder) in [
      (1, first),
      (2, first),
      (3, second),
      (4, second),
    ]) {
      final lesson = video(id);
      await service.addBatch([
        LearningPartSelection(lesson, lesson.initialPart),
      ], folderId: folder.id);
    }
    await _showQueue(tester, service, const Size(760, 920));
    await tester.tap(find.byKey(Key('learning-folder-${first.id}')));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('课程1'));
    await tester.pumpAndSettle();
    final gesture = await _holdCheckbox(tester, 2);
    await tester.pump();
    expect(find.text('已选 2'), findsOneWidget);

    // A second pointer changes the filter without changing the result length.
    await tester.tap(find.byKey(Key('learning-folder-${second.id}')));
    await gesture.moveTo(tester.getCenter(_checkbox(1)));
    await tester.pumpAndSettle();
    expect(_row(1), findsNothing);
    await gesture.moveTo(tester.getCenter(_checkbox(3)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('已选 0'), findsOneWidget);
    expect(_checked(tester, 3), isFalse);
    expect(_checked(tester, 4), isFalse);
    expect((await service.loadEntries()).length, 4);
  });

  testWidgets(
    'quick swipes still scroll and the reorder handle still reorders',
    (tester) async {
      final service = LearningListService();
      for (var i = 1; i <= 8; i++) {
        await service.addVideo(video(i));
      }
      await _showQueue(tester, service, const Size(420, 800));
      final controller = tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .scrollController!;
      await tester.drag(find.text('课程1'), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(find.byTooltip('多选管理'), findsOneWidget);
      controller.jumpTo(0);
      await tester.pumpAndSettle();

      final reorder = find.descendant(
        of: _row(1),
        matching: find.byType(ReorderableDragStartListener),
      );
      final drag = await tester.startGesture(tester.getCenter(reorder));
      for (var step = 0; step < 8; step++) {
        await drag.moveBy(const Offset(0, 25));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect((await service.loadEntries()).first.partCid, 2);
      expect(find.byTooltip('多选管理'), findsOneWidget);

      await tester.tap(find.byTooltip('多选管理'));
      await tester.pumpAndSettle();
      await tester.drag(_checkbox(2), const Offset(0, -110));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(find.text('已选 0'), findsOneWidget);
      controller.jumpTo(0);
      await tester.pumpAndSettle();

      final bounds = tester.getRect(find.byType(ReorderableListView));
      final handle = tester.getCenter(_checkbox(2));
      final sweep = await _holdCheckbox(tester, 2);
      await sweep.moveTo(Offset(handle.dx, bounds.bottom - 2));
      for (var frame = 0; frame < 58; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, greaterThan(450));
      expect(_checkbox(2).hitTestable(), findsNothing);
      expect([
        for (var id = 5; id <= 8; id++)
          if (_checkbox(id).hitTestable().evaluate().isNotEmpty)
            _checked(tester, id),
      ], contains(true));
      await sweep.cancel();
      await tester.pump();
      final canceledAt = controller.offset;
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.offset, canceledAt);
      expect(tester.takeException(), isNull);
    },
  );
}
