import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'learning_batch_test.dart' show video, RejectingPreferences;

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
    await tester.tap(find.byKey(const Key('save-learning-folder')));
    await tester.pumpAndSettle();
    final folder = (await service.loadState()).folders.single;
    await tester.tap(find.byKey(const Key('move-learning-BV1:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-folder-${folder.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('learning-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('manage-learning-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名分组'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('learning-folder-name')),
      '高等数学',
    );
    await tester.tap(find.byKey(const Key('save-learning-folder')));
    await tester.pumpAndSettle();
    expect(find.text('高等数学（1）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('manage-learning-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-learning-folder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsOneWidget);
    expect((await service.loadState()).folders, isEmpty);
    expect((await service.loadEntries()).single.folderId, null);
    expect(tester.takeException(), null);
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
