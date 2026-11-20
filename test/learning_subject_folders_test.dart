import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/features/learning/learning_folder_appearance.dart';
import 'package:focubili/models/learning_subject_folder.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'learning_batch_test.dart' show video, RejectingPreferences;

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('v2旧数组迁移后保留任务身份、进度、状态、顺序与备份', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    await service.updateProgress(
      'BV1',
      part: video(1).initialPart,
      position: const Duration(seconds: 44),
      status: LearningListStatus.learning,
    );
    final before = (await service.loadEntries()).single;
    final legacy = jsonEncode([before.toJson()]);
    await prefs.setString('focubili_learning_list_v2', legacy);
    final state = await service.loadState();
    expect(state.entries.single, before);
    expect(state.folders, isEmpty);
    expect(state.entries.single.folderId, null);
    expect(prefs.getString('focubili_learning_list_v2_backup'), legacy);
    final encoded =
        jsonDecode(prefs.getString('focubili_learning_list_v2')!) as Map;
    expect(encoded['schemaVersion'], 3);
    await service.createFolder('数学');
    expect(
      prefs.getString('focubili_learning_list_v2_migration_backup'),
      legacy,
    );
  });

  test('新建、移动、重命名与删除分组保留学习记录，跨服务写入进度不丢分组', () async {
    final prefs = await SharedPreferences.getInstance();
    final a = LearningListService(preferencesLoader: () async => prefs);
    final b = LearningListService(preferencesLoader: () async => prefs);
    await a.addVideo(video(1));
    await a.addVideo(video(2));
    final initial = await a.loadEntries();
    final folder = (await a.createFolder('数学')).folders.single;
    await Future.wait([
      a.moveEntries({initial.first.stableId}, folder.id),
      b.updateProgress(
        'BV1',
        part: video(1).initialPart,
        position: const Duration(seconds: 50),
        status: LearningListStatus.learning,
      ),
    ]);
    final renamed = await b.renameFolder(folder.id, '高等数学');
    final moved = renamed.entries.first;
    expect(renamed.folders.single.id, folder.id);
    expect(renamed.folders.single.name, '高等数学');
    expect(moved.stableId, initial.first.stableId);
    expect(moved.position, const Duration(seconds: 50));
    expect(moved.status, LearningListStatus.learning);
    expect(moved.sortOrder, initial.first.sortOrder);
    expect(moved.folderId, folder.id);
    final removed = await a.deleteFolder(folder.id);
    expect(removed.folders, isEmpty);
    expect(removed.entries.first.folderId, null);
    expect(removed.entries.first.position, moved.position);
    expect(removed.entries.first.status, moved.status);
    expect(removed.entries.first.stableId, moved.stableId);
    expect(removed.entries, hasLength(2));
    expect((await b.loadState()).entries, removed.entries);
  });

  test('分组删除写入失败不会先移除条目或分组，未知版本/损坏值不被覆盖', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final folder = (await service.createFolder('英语')).folders.single;
    await service.moveEntries({'BV1:1'}, folder.id);
    final before = prefs.getString('focubili_learning_list_v2');
    final rejected = LearningListService(
      preferencesLoader: () async =>
          RejectingPreferences(prefs, 'focubili_learning_list_v2'),
    );
    await expectLater(
      rejected.deleteFolder(folder.id),
      throwsA(isA<LearningListStorageException>()),
    );
    expect(prefs.getString('focubili_learning_list_v2'), before);
    await prefs.setString(
      'focubili_learning_list_v2',
      '{"schemaVersion":99,"entries":[],"folders":[]}',
    );
    await expectLater(
      service.createFolder('新学科'),
      throwsA(isA<LearningListStorageException>()),
    );
    expect(prefs.getString('focubili_learning_list_v2'), contains('99'));
  });

  test('空名、重名、超长与不存在目的地被拒绝，批量新增保留旧任务归属', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    final folder = (await service.createFolder('数学')).folders.single;
    await expectLater(service.createFolder(' 数学 '), throwsArgumentError);
    await expectLater(service.createFolder('  '), throwsArgumentError);
    await expectLater(
      service.renameFolder(folder.id, '学' * 31),
      throwsArgumentError,
    );
    await service.addVideo(video(1));
    await expectLater(
      service.moveEntries({'BV1:1'}, 'missing'),
      throwsArgumentError,
    );
    final result = await service.addBatch([
      LearningPartSelection(video(1), video(1).initialPart),
      LearningPartSelection(video(2), video(2).initialPart),
    ], folderId: folder.id);
    expect(result.entries.first.folderId, null);
    expect(result.entries.last.folderId, folder.id);
  });

  test('分组内拖动不改其他学科的排序槽位；孤立分组恢复为未分组', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    for (var index = 1; index <= 3; index++) {
      await service.addVideo(video(index));
    }
    final folder = (await service.createFolder('数学')).folders.single;
    await service.moveEntries({'BV1:1', 'BV3:3'}, folder.id);
    final ordered = await service.reorderIncomplete(
      ['BV3:3', 'BV1:1'],
      folderId: folder.id,
      withinFolder: true,
    );
    expect(ordered.map((entry) => entry.bvid), ['BV3', 'BV2', 'BV1']);
    expect(ordered[1].sortOrder, 1);
    final state =
        jsonDecode(prefs.getString('focubili_learning_list_v2')!) as Map;
    for (final entry in state['entries'] as List) {
      entry['sortOrder'] = 0;
    }
    await prefs.setString('focubili_learning_list_v2', jsonEncode(state));
    final tied = await service.reorderIncomplete(
      ['BV3:3', 'BV1:1'],
      folderId: folder.id,
      withinFolder: true,
    );
    expect(tied.map((entry) => entry.bvid), ['BV3', 'BV2', 'BV1']);
    state['entries'] = tied.map((entry) => entry.toJson()).toList();
    state['folders'] = [];
    await prefs.setString('focubili_learning_list_v2', jsonEncode(state));
    final recovered = await service.loadEntries();
    expect(recovered, hasLength(3));
    expect(recovered.every((entry) => entry.folderId == null), true);
  });

  test('分组外观兼容旧数据和未知值，重命名保留元数据', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await prefs.setString(
      'focubili_learning_list_v2',
      jsonEncode({
        'schemaVersion': 3,
        'entries': [],
        'folders': [
          {'id': 'old', 'name': '旧分组'},
          {'id': 'bad', 'name': '损坏外观', 'iconId': 17, 'colorId': null},
          {
            'id': 'future',
            'name': '未来外观',
            'iconId': 'future-icon',
            'colorId': 'future-color',
          },
        ],
      }),
    );
    final loaded = await service.loadState();
    expect(loaded.folders[0].iconId, LearningSubjectFolder.defaultIconId);
    expect(loaded.folders[1].colorId, LearningSubjectFolder.defaultColorId);
    expect(learningFolderIcon(loaded.folders[2].iconId).id, 'folder');
    expect(learningFolderColor(loaded.folders[2].colorId).id, 'blue');
    await service.renameFolder('future', '重命名');
    final restarted = LearningListService(preferencesLoader: () async => prefs);
    final future = (await restarted.loadState()).folders.last;
    expect(future.iconId, 'future-icon');
    expect(future.colorId, 'future-color');
  });

  testWidgets('分组外观创建、编辑、取消和重启持久化，并跟随主题', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder: (context, value, _) => MaterialApp(
          theme: ThemeData(brightness: value, useMaterial3: true),
          home: LearningListPage(learningListService: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-learning-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('learning-folder-name')), '物理');
    await tapVisible(
      tester,
      find.byKey(const Key('learning-folder-icon-atom')),
    );
    await tapVisible(
      tester,
      find.byKey(const Key('learning-folder-color-pink')),
    );
    await tester.pumpAndSettle();
    var preview = tester.widget<LearningFolderBadge>(
      find.byKey(const Key('learning-folder-preview')),
    );
    expect(preview.iconId, 'atom');
    expect(preview.colorId, 'pink');
    final previewContainer = find
        .descendant(
          of: find.byKey(const Key('learning-folder-preview')),
          matching: find.byType(Container),
        )
        .first;
    final lightColor =
        (tester.widget<Container>(previewContainer).decoration!
                as BoxDecoration)
            .color;
    brightness.value = Brightness.dark;
    await tester.pumpAndSettle();
    final darkColor =
        (tester.widget<Container>(previewContainer).decoration!
                as BoxDecoration)
            .color;
    expect(
      darkColor!.computeLuminance(),
      lessThan(lightColor!.computeLuminance()),
    );
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    final folder = (await service.loadState()).folders.single;
    expect(folder.iconId, 'atom');
    expect(folder.colorId, 'pink');
    expect(
      (await LearningListService(
        preferencesLoader: () async => prefs,
      ).loadState()).folders.single.iconId,
      'atom',
    );
    await tapVisible(
      tester,
      find.byKey(Key('manage-learning-folder-${folder.id}')),
    );
    preview = tester.widget<LearningFolderBadge>(
      find.byKey(const Key('learning-folder-preview')),
    );
    expect(preview.iconId, 'atom');
    expect(preview.colorId, 'pink');
    await tapVisible(
      tester,
      find.byKey(const Key('learning-folder-icon-book')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect((await service.loadState()).folders.single.iconId, 'atom');
    await tapVisible(
      tester,
      find.byKey(Key('manage-learning-folder-${folder.id}')),
    );
    await tapVisible(
      tester,
      find.byKey(const Key('learning-folder-icon-book')),
    );
    await tapVisible(
      tester,
      find.byKey(const Key('learning-folder-color-green')),
    );
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    final saved = (await service.loadState()).folders.single;
    expect(saved.iconId, 'book');
    expect(saved.colorId, 'green');
    expect((await service.loadEntries()).single.folderId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清单支持新建、移动、筛选、重命名与删除分组保留任务', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-learning-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('learning-folder-name')), '数学');
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    final folder = (await service.loadState()).folders.single;
    await tester.tap(find.byKey(const Key('learning-status-BV1:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-learning-BV1:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-folder-${folder.id}')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(Key('learning-folder-${folder.id}')));
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    await tapVisible(
      tester,
      find.byKey(Key('manage-learning-folder-${folder.id}')),
    );
    await tester.enterText(
      find.byKey(const Key('learning-folder-name')),
      '高等数学',
    );
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    expect(find.bySemanticsLabel('高等数学（1）'), findsOneWidget);
    await tapVisible(
      tester,
      find.byKey(Key('manage-learning-folder-${folder.id}')),
    );
    await tapVisible(tester, find.byKey(const Key('delete-learning-folder')));
    await tester.tap(find.byKey(const Key('confirm-delete-learning-folder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    expect((await service.loadState()).folders, isEmpty);
    expect((await service.loadEntries()).single.folderId, null);
    expect(tester.takeException(), null);
  });
  testWidgets('未选中分组的菜单操作该分组且不改变当前筛选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final first = (await service.createFolder('数学')).folders.single;
    final second = (await service.createFolder('英语')).folders.last;
    await service.moveEntries({'BV1:1'}, second.id);
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();

    for (final key in ['learning-folder-all', 'learning-folder-ungrouped']) {
      expect(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );
    }
    await tapVisible(tester, find.byKey(Key('learning-folder-${first.id}')));
    final secondMenu = find.byKey(Key('manage-learning-folder-${second.id}'));
    await tapVisible(tester, secondMenu);
    await tester.enterText(find.byKey(const Key('learning-folder-name')), '物理');
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    expect((await service.loadState()).folders.last.name, '物理');
    expect(
      tester
          .getSemantics(find.byKey(Key('learning-folder-${first.id}')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(find.byKey(const Key('learning-list-BV1:1')), findsNothing);

    await tapVisible(tester, secondMenu);
    await tapVisible(tester, find.byKey(const Key('delete-learning-folder')));
    expect(find.textContaining('删除“物理”'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await service.loadState()).folders, hasLength(2));
    await tapVisible(tester, find.byKey(const Key('delete-learning-folder')));
    await tester.tap(find.byKey(const Key('confirm-delete-learning-folder')));
    await tester.pumpAndSettle();
    expect((await service.loadState()).folders.single.id, first.id);
    expect((await service.loadEntries()).single.folderId, isNull);
    expect(
      tester
          .getSemantics(find.byKey(Key('learning-folder-${first.id}')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.tap(find.byKey(const Key('learning-folder-ungrouped')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('learning-folder-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('自定义分组的边框、基线和选中底色与内置分组一致 ($brightness)', (tester) async {
      final service = LearningListService();
      final folder = (await service.createFolder(
        '数学',
        iconId: 'book',
      )).folders.single;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: LearningListPage(learningListService: service),
        ),
      );
      await tester.pumpAndSettle();

      final all = find.byKey(const Key('learning-folder-all'));
      final ungrouped = find.byKey(const Key('learning-folder-ungrouped'));
      final custom = find.byKey(Key('learning-folder-${folder.id}'));
      final menu = find.byKey(Key('manage-learning-folder-${folder.id}'));
      Finder surface(Finder chip) =>
          find.descendant(of: chip, matching: find.byType(Material));
      ShapeBorder? shape(Finder chip) =>
          tester.widget<Material>(surface(chip)).shape;
      ShapeDecoration decoration(Finder chip) =>
          tester
                  .widget<Ink>(
                    find.descendant(of: chip, matching: find.byType(Ink)),
                  )
                  .decoration!
              as ShapeDecoration;

      expect(shape(custom), shape(ungrouped));
      expect(decoration(custom).color, decoration(ungrouped).color);
      expect(
        tester.getRect(surface(custom)).height,
        tester.getRect(surface(all)).height,
      );
      expect(
        tester.getRect(surface(custom)).center.dy,
        tester.getRect(surface(all)).center.dy,
      );
      expect(tester.getCenter(menu).dy, tester.getCenter(surface(custom)).dy);
      expect(tester.getSize(custom).height, greaterThanOrEqualTo(48));
      expect(
        tester.getTopLeft(find.widgetWithText(ChoiceChip, '全部')).dy,
        greaterThan(tester.getBottomLeft(custom).dy),
      );

      final selectedShape = shape(all);
      final selectedFill = decoration(all).color;
      await tapVisible(tester, custom);
      expect(shape(custom), selectedShape);
      expect(decoration(custom).color, selectedFill);
      expect(find.byType(LearningFolderBadge), findsOneWidget);

      // The upper edge of the padded chip is still tappable for the menu.
      await tester.tapAt(
        Offset(tester.getCenter(menu).dx, tester.getTopLeft(custom).dy + 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑分组'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.widget<InputChip>(custom).selected, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄屏大字下长名称分组的独立菜单可点击', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = LearningListService();
    final selected = (await service.createFolder('数学')).folders.single;
    final target = (await service.createFolder(
      '高等数学函数与极限线性代数概率论综合复习资料',
    )).folders.last;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LearningListPage(learningListService: service),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(Key('learning-folder-${selected.id}')));
    final targetSelection = find.byKey(Key('learning-folder-${target.id}'));
    final flags = tester
        .getSemantics(targetSelection)
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isButton, isTrue);
    expect(flags.isSelected, Tristate.isFalse);
    final menu = find.byKey(Key('manage-learning-folder-${target.id}'));
    final scroll = find.ancestor(
      of: targetSelection,
      matching: find.byType(SingleChildScrollView),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    await tester.drag(scroll, const Offset(-420, 0));
    await tester.pumpAndSettle();
    final scrolledOffset = position.pixels;
    expect(scrolledOffset, greaterThan(0));
    expect(
      tester.getSize(targetSelection).width,
      lessThanOrEqualTo(tester.getSize(scroll).width),
    );
    final count = tester.getRect(
      find.descendant(of: targetSelection, matching: find.text('（0）')),
    );
    expect(count.width, greaterThan(0));
    expect(tester.getRect(scroll).contains(count.center), isTrue);
    expect(menu.hitTestable(), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(position.pixels, scrolledOffset);
    expect(find.text('编辑分组'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('learning-folder-name')), '物理');
    await tapVisible(tester, find.byKey(const Key('save-learning-folder')));
    final state = await service.loadState();
    expect(state.folders.first.name, '数学');
    expect(state.folders.last.name, '物理');
    expect(
      tester
          .getSemantics(find.byKey(Key('learning-folder-${selected.id}')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('视频菜单保留状态操作并提供移动和确认移除，多选仍可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final folder = (await service.createFolder('数学')).folders.single;
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('learning-list-BV1:1'));
    expect(find.byKey(const Key('continue-learning-BV1:1')), findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.drag_handle_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.drive_file_move_outline),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsNothing,
    );

    Future<void> openMenu() async {
      await tester.tap(find.byKey(const Key('learning-status-BV1:1')));
      await tester.pumpAndSettle();
    }

    await openMenu();
    expect(find.text('学习中'), findsWidgets);
    await tester.tap(find.byKey(const Key('move-learning-BV1:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect((await service.loadEntries()).single.folderId, folder.id);
    await tester.tap(find.byTooltip('多选管理'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    await openMenu();
    await tester.tap(find.byKey(const Key('remove-learning-BV1:1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('观看记录和笔记不会被删除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await service.loadEntries(), hasLength(1));
    await openMenu();
    await tester.tap(find.byKey(const Key('remove-learning-BV1:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(await service.loadEntries(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('批量操作面板在 $brightness 下保持三列与文字对比', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = LearningListService();
      await service.addVideo(video(1));
      final theme = ThemeData(brightness: brightness, useMaterial3: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: LearningListPage(learningListService: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('多选管理'));
      await tester.pumpAndSettle();
      final panel = find.byKey(const Key('learning-bulk-actions'));
      final decoration =
          tester.widget<Container>(panel).decoration! as BoxDecoration;
      expect(
        decoration.color!.computeLuminance(),
        lessThan(theme.colorScheme.surface.computeLuminance()),
      );
      final foreground = theme.colorScheme.onSurface.computeLuminance();
      final background = decoration.color!.computeLuminance();
      final contrast = (foreground > background)
          ? (foreground + 0.05) / (background + 0.05)
          : (background + 0.05) / (foreground + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      final labels = ['选择当前结果', '移除所选（0）', '移动所选', '标为未开始', '标为学习中', '标为已完成'];
      final buttons = labels
          .map(
            (label) => find.ancestor(
              of: find.text(label),
              matching: find.byType(TextButton),
            ),
          )
          .toList();
      final rects = buttons.map(tester.getRect).toList();
      expect(rects[0].center.dy, rects[1].center.dy);
      expect(rects[1].center.dy, rects[2].center.dy);
      expect(rects[3].center.dy, rects[4].center.dy);
      expect(rects[4].center.dy, rects[5].center.dy);
      expect(rects[0].left, rects[3].left);
      expect(rects[1].center.dx, rects[4].center.dx);
      expect(rects[2].right, rects[5].right);
      expect(rects.every((rect) => rect.height >= 48), isTrue);
      expect(tester.widget<TextButton>(buttons[1]).onPressed, isNull);
      await tester.tap(buttons[0]);
      await tester.pumpAndSettle();
      expect(find.text('移除所选（1）'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('move-selected-learning')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('批量操作面板在窄屏大字下自适应', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = LearningListService();
    await service.addVideo(video(1));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: LearningListPage(learningListService: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('多选管理'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('learning-bulk-actions'));
    expect(panel, findsOneWidget);
    final panelRect = tester.getRect(panel);
    for (final label in [
      '选择当前结果',
      '移除所选（0）',
      '移动所选',
      '标为未开始',
      '标为学习中',
      '标为已完成',
    ]) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextButton),
      );
      final rect = tester.getRect(button);
      expect(rect.left, greaterThanOrEqualTo(panelRect.left));
      expect(rect.right, lessThanOrEqualTo(panelRect.right));
      expect(rect.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选移动到分组并可批量退回未分组', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    await service.addVideo(video(2));
    final folder = (await service.createFolder('数学')).folders.single;
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('多选管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择当前结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-selected-learning')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(
      (await service.loadEntries()).every(
        (entry) => entry.folderId == folder.id,
      ),
      true,
    );
    await tester.tap(find.text('选择当前结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-selected-learning')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-folder-ungrouped')));
    await tester.pumpAndSettle();
    expect(
      (await service.loadEntries()).every((entry) => entry.folderId == null),
      true,
    );
  });

  testWidgets('加入清单面板能直接选择学科分组', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    final folder = (await service.createFolder('数学')).folders.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => LearningAddSheet.show(
                context,
                video: video(1),
                service: service,
              ),
              child: const Text('加入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-learning-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认加入'));
    await tester.pumpAndSettle();
    expect((await service.loadEntries()).single.folderId, folder.id);
    expect(tester.takeException(), null);
  });
  test('迁移和分组操作保留非BV课程身份及未知合法JSON元数据', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final record = (await service.loadEntries()).single.toJson();
    record['bvid'] = 'classroom:fixture-course';
    record['futureCourseMetadata'] = {
      'courseId': 'fixture-course',
      'chapter': [1, 2],
      'optional': null,
    };
    await prefs.setString('focubili_learning_list_v2', jsonEncode([record]));
    final migrated = await service.loadEntries();
    expect(migrated.single.bvid, 'classroom:fixture-course');
    final folder = (await service.createFolder('课程')).folders.single;
    await service.moveEntries({migrated.single.stableId}, folder.id);
    await service.updateProgress(
      'classroom:fixture-course',
      part: video(1).initialPart,
      position: const Duration(seconds: 40),
    );
    final removed = await service.deleteFolder(folder.id);
    expect(removed.entries.single.stableId, 'classroom:fixture-course:1');
    expect(
      removed.entries.single.toJson()['futureCourseMetadata'],
      record['futureCourseMetadata'],
    );
    expect(removed.entries.single.position, const Duration(seconds: 40));
    final roundTrip = LearningListEntry.tryParse(
      removed.entries.single.toJson(),
    );
    expect(roundTrip, removed.entries.single);
    expect(roundTrip.hashCode, removed.entries.single.hashCode);
  });
}
