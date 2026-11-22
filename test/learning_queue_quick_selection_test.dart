import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<void> _shiftTap(
  WidgetTester tester,
  Finder target, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.tap(target, kind: kind);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'desktop Shift-click adds a range via title or checkbox, but touch toggles one',
    (tester) async {
      final service = LearningListService();
      for (var i = 1; i <= 5; i++) {
        await service.addVideo(video(i));
      }
      await service.updateStatus(
        'BV5',
        LearningListStatus.completed,
        partCid: 5,
      );
      await _showQueue(tester, service, const Size(960, 1200));

      List<bool> selection() => [
        for (var id = 1; id <= 5; id++) _checked(tester, id),
      ];
      await tester.longPress(find.text('课程1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Shift'), findsOneWidget);
      expect(selection(), [true, false, false, false, false]);

      await tester.tap(_checkbox(4), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(selection(), [true, false, false, true, false]);
      await _shiftTap(tester, find.text('课程2'));
      expect(selection(), [true, true, true, true, false]);

      // A shifted touch on a desktop with a touchscreen is still one tap.
      await _shiftTap(tester, find.text('课程2'), kind: PointerDeviceKind.touch);
      expect(selection(), [true, false, true, true, false]);

      // Shift-click targets the current display, crossing the completed header.
      // The independent selection of row 1 stays checked.
      await _shiftTap(tester, _checkbox(5));
      expect(selection(), [true, true, true, true, true]);
      expect(find.text('已选 5'), findsOneWidget);

      await tester.tap(find.byTooltip('结束多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('多选管理'));
      await tester.pumpAndSettle();
      await _shiftTap(tester, _checkbox(3));
      expect(selection(), [false, false, true, false, false]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets(
    'Shift-click respects sorting, filters, and cleared anchors',
    (tester) async {
      final service = LearningListService();
      final folder = (await service.createFolder('数学')).folders.single;
      for (var i = 1; i <= 5; i++) {
        await service.addVideo(video(i));
      }
      await service.moveEntries({
        'BV2:2',
        'BV3:3',
        'BV4:4',
        'BV5:5',
      }, folder.id);
      await service.updateStatus(
        'BV5',
        LearningListStatus.completed,
        partCid: 5,
      );

      // Manual order is 1, 2, 3, 4, 5; newest-first shows 3, 1, 4, 2, 5.
      // Even though 5 is newest, completed tasks stay in their own section.
      final prefs = await SharedPreferences.getInstance();
      const key = 'focubili_learning_list_v2';
      final saved = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      const days = [3, 1, 4, 2, 5];
      saved['entries'] = [
        for (final entry in await service.loadEntries())
          entry
              .copyWith(addedAt: DateTime(2026, 11, days[entry.partCid - 1]))
              .toJson(),
      ];
      await prefs.setString(key, jsonEncode(saved));
      await service.saveNewestFirst(true);

      await _showQueue(tester, service, const Size(960, 1200));
      await tester.tap(find.byTooltip('多选管理'));
      await tester.pumpAndSettle();
      List<bool> selection() => [
        for (var id = 1; id <= 5; id++) _checked(tester, id),
      ];
      await tester.tap(find.text('课程3'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await _shiftTap(tester, _checkbox(4));
      expect(selection(), [true, false, true, true, false]);

      await tester.tap(find.widgetWithText(ChoiceChip, '已完成'));
      await tester.pumpAndSettle();
      expect(_row(3), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      await _shiftTap(tester, _checkbox(2));
      expect(selection(), [false, true, false, false, false]);

      // Row 2 is still in the new folder, but switching folders clears selection
      // and its anchor. The next range must exclude the ungrouped row 1.
      await tester.tap(find.byKey(Key('learning-folder-${folder.id}')));
      await tester.pumpAndSettle();
      expect(_row(1), findsNothing);
      await _shiftTap(tester, _checkbox(3));
      expect(find.text('已选 1'), findsOneWidget);
      await _shiftTap(tester, _checkbox(2));
      expect(
        [for (var id = 2; id <= 5; id++) _checked(tester, id)],
        [true, true, true, false],
      );
      expect(find.text('已选 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
