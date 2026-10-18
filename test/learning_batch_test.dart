import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/services/learning_list_service.dart';

VideoPreview video(int id) => VideoPreview(
  bvid: 'BV$id',
  cid: id,
  title: '课程$id',
  ownerName: '作者',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: id,
      title: '第一节',
      duration: const Duration(minutes: 3),
    ),
  ],
);

class RejectingPreferences implements SharedPreferences {
  RejectingPreferences(this.base, this.key);
  final SharedPreferences base;
  final String key;
  @override
  String? getString(String key) => base.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      key == this.key ? Future.value(false) : base.setString(key, value);
  @override
  Future<void> reload() => base.reload();
  @override
  Future<bool> remove(String key) => base.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    '98 + 5 is atomic: no clipping, then duplicate keeps progress',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = LearningListService(preferencesLoader: () async => prefs);
      final initial = [
        for (var i = 1; i <= 98; i++)
          LearningPartSelection(video(i), video(i).initialPart),
      ];
      expect((await service.addBatch(initial)).addedIds.length, 98);
      final before = prefs.getString('focubili_learning_list_v2');
      final rejected = await service.addBatch([
        for (var i = 99; i <= 103; i++)
          LearningPartSelection(video(i), video(i).initialPart),
      ]);
      expect(rejected.capacityExceeded, true);
      expect(rejected.addedIds, isEmpty);
      expect(prefs.getString('focubili_learning_list_v2'), before);
      await service.updateProgress(
        'BV1',
        part: video(1).initialPart,
        position: const Duration(seconds: 33),
        status: LearningListStatus.learning,
      );
      final repeat = await service.addBatch(initial);
      expect(repeat.addedIds, isEmpty);
      expect(repeat.existingIds.length, 98);
      expect(repeat.entries.first.position.inSeconds, 33);
      expect(repeat.entries.first.status, LearningListStatus.learning);
    },
  );
  test(
    'multiple instances serialize batch and progress, preserve selection order',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final a = LearningListService(preferencesLoader: () async => prefs);
      final b = LearningListService(preferencesLoader: () async => prefs);
      await a.addVideo(video(1));
      await Future.wait([
        a.updateProgress(
          'BV1',
          part: video(1).initialPart,
          position: const Duration(seconds: 44),
        ),
        b.addBatch([
          LearningPartSelection(video(3), video(3).initialPart),
          LearningPartSelection(video(2), video(2).initialPart),
        ]),
      ]);
      final entries = await a.loadEntries();
      expect(entries.map((e) => e.bvid), ['BV1', 'BV3', 'BV2']);
      expect(entries.first.position.inSeconds, 44);
    },
  );
  test('rejected v2 migration keeps original v1 and backup', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LearningListService(preferencesLoader: () async => prefs);
    await service.addVideo(video(1));
    final legacy = prefs.getString('focubili_learning_list_v2')!;
    await prefs.remove('focubili_learning_list_v2');
    await prefs.setString('focubili_learning_list_v1', legacy);
    final reject = LearningListService(
      preferencesLoader: () async =>
          RejectingPreferences(prefs, 'focubili_learning_list_v2'),
    );
    final result = await reject.addParts(video(2), video(2).parts);
    expect(result.persisted, false);
    expect(prefs.getString('focubili_learning_list_v1'), legacy);
    expect(prefs.getString('focubili_learning_list_v1_backup'), legacy);
    expect(prefs.getString('focubili_learning_list_v2'), null);
  });
  test(
    'write false and corrupt read cannot replace original tasks with empty',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final a = LearningListService(preferencesLoader: () async => prefs);
      await a.addVideo(video(1));
      final before = prefs.getString('focubili_learning_list_v2');
      final reject = LearningListService(
        preferencesLoader: () async =>
            RejectingPreferences(prefs, 'focubili_learning_list_v2'),
      );
      expect(
        (await reject.addParts(video(2), video(2).parts)).persisted,
        false,
      );
      expect(prefs.getString('focubili_learning_list_v2'), before);
      await prefs.setString('focubili_learning_list_v2', '{broken');
      expect((await a.addParts(video(2), video(2).parts)).persisted, false);
      expect(prefs.getString('focubili_learning_list_v2'), '{broken');
      expect(() => jsonDecode(before!), returnsNormally);
    },
  );
}
