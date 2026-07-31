import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/watch_history_service.dart';

/// 创建包含两个分P的测试视频，用来验证进度继承和播放器写回。
VideoPreview _video() {
  return const VideoPreview(
    bvid: 'BV1Learning1',
    cid: 1001,
    title: '学习清单测试视频',
    ownerName: '测试 UP 主',
    thumbnailUrl: 'https://example.com/cover.jpg',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 1001,
        title: '第一节',
        duration: Duration(minutes: 3),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 1002,
        title: '第二节',
        duration: Duration(minutes: 5),
      ),
    ],
  );
}

/// 创建使用同一内存偏好设置的学习清单服务，方便检查真实序列化结果。
LearningListService _service(SharedPreferences preferences) {
  final WatchHistoryService history = WatchHistoryService(
    preferencesLoader: () async => preferences,
  );
  return LearningListService(
    preferencesLoader: () async => preferences,
    watchHistoryService: history,
  );
}

/// 注册学习清单的进度继承、状态修改、存储容错和删除行为测试。
void main() {
  /// 每个测试前重置内存偏好设置，避免任务与观看记录相互污染。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('加入学习清单会自动继承已有分P和观看进度', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService history = WatchHistoryService(
      preferencesLoader: () async => preferences,
    );
    await history.record(
      WatchHistoryEntry(
        bvid: _video().bvid,
        title: _video().title,
        ownerName: _video().ownerName,
        lastPartTitle: '第二节',
        lastPartPageNumber: 2,
        watchedAt: DateTime(2026, 7, 26, 10),
        lastPosition: const Duration(minutes: 2, seconds: 15),
      ),
    );
    final LearningListService service = LearningListService(
      preferencesLoader: () async => preferences,
      watchHistoryService: history,
    );

    final List<LearningListEntry> entries = await service.addVideo(_video());

    expect(entries, hasLength(1));
    expect(entries.single.partCid, 1002);
    expect(entries.single.partPageNumber, 2);
    expect(entries.single.position, const Duration(minutes: 2, seconds: 15));
    expect(entries.single.status, LearningListStatus.learning);
    expect(service.currentTask(entries)?.bvid, _video().bvid);
  });

  test('播放进度、状态和重复加入会合并到同一条学习任务', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService service = _service(preferences);
    await service.addVideo(_video());

    await service.updateProgress(
      _video().bvid,
      part: _video().parts.last,
      position: const Duration(minutes: 4, seconds: 30),
      status: LearningListStatus.learning,
    );
    final List<LearningListEntry> completed = await service.updateStatus(
      _video().bvid,
      LearningListStatus.completed,
    );
    final List<LearningListEntry> merged = await service.addVideo(_video());

    expect(completed.single.status, LearningListStatus.completed);
    expect(merged, hasLength(1));
    expect(merged.single.partCid, 1002);
    expect(merged.single.position, const Duration(minutes: 4, seconds: 30));
    expect(merged.single.status, LearningListStatus.completed);
    expect(await service.loadCurrentTask(), isNull);
  });

  test('读取损坏数据会跳过问题条目，并可独立删除和清空学习清单', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_learning_list_v1': jsonEncode(<Object?>[
        <String, Object>{
          'bvid': 'BVvalid',
          'title': '有效任务',
          'ownerName': '测试 UP 主',
          'thumbnailUrl': '',
          'partCid': 1,
          'partPageNumber': 1,
          'partTitle': '第一节',
          'positionMs': 1000,
          'durationMs': 10000,
          'status': 'notStarted',
          'addedAt': '2026-07-26T00:00:00.000Z',
          'updatedAt': '2026-07-26T00:00:00.000Z',
        },
        <String, Object>{'bvid': 'BVbroken'},
        'not a map',
      ]),
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService service = _service(preferences);

    expect(await service.loadEntries(), hasLength(1));
    expect(await service.remove('BVvalid'), isEmpty);
    await service.addVideo(_video());
    expect(await service.clear(), isEmpty);
    expect(await service.loadEntries(), isEmpty);
    expect(preferences.containsKey('focubili_learning_list_v1'), isFalse);
  });
}
