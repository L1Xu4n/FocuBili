import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/watch_history_service.dart';

/// 创建测试专用的观看记录，便于聚焦验证本地存储行为。
WatchHistoryEntry _entry({
  required String bvid,
  String title = '测试视频',
  int pageNumber = 1,
  DateTime? watchedAt,
}) {
  return WatchHistoryEntry(
    bvid: bvid,
    title: title,
    ownerName: '测试 UP 主',
    lastPartTitle: '第 $pageNumber P',
    lastPartPageNumber: pageNumber,
    watchedAt: watchedAt ?? DateTime(2026, 7, 15, 12),
  );
}

/// 创建使用测试内存偏好设置的观看记录服务。
WatchHistoryService _service(SharedPreferences preferences) {
  return WatchHistoryService(preferencesLoader: () async => preferences);
}

/// 注册观看记录服务的本地存储、容错和删除行为测试。
void main() {
  /// 每个测试前重置内存偏好设置，避免测试之间共享记录。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('保存记录只写入允许字段，并以最新 BV 记录覆盖旧记录', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);

    await service.record(_entry(bvid: 'BV1old', title: '旧标题'));
    final List<WatchHistoryEntry> history = await service.record(
      _entry(
        bvid: 'BV1old',
        title: '新标题',
        pageNumber: 2,
        watchedAt: DateTime(2026, 7, 15, 13),
      ),
    );

    expect(history, hasLength(1));
    expect(history.single.title, '新标题');
    expect(history.single.lastPartPageNumber, 2);

    final List<Object?> saved =
        jsonDecode(preferences.getString('focubili_watch_history')!)
            as List<Object?>;
    final Map<String, dynamic> item =
        Map<String, dynamic>.from(saved.single! as Map<String, dynamic>);
    expect(
      item.keys.toSet(),
      <String>{
        'bvid',
        'title',
        'ownerName',
        'lastPartTitle',
        'lastPartPageNumber',
        'watchedAt',
      },
    );
  });

  test('记录数量最多 50 条，且最新记录排在最前面', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);

    for (int index = 0; index < 55; index += 1) {
      await service.record(
        _entry(
          bvid: 'BV$index',
          title: '视频 $index',
          watchedAt: DateTime(2026, 7, 15, 12, index),
        ),
      );
    }

    final List<WatchHistoryEntry> history = await service.loadHistory();

    expect(history, hasLength(WatchHistoryService.maximumEntries));
    expect(history.first.bvid, 'BV54');
    expect(history.last.bvid, 'BV5');
  });

  test('读取时忽略损坏 JSON 和单个不完整条目', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_watch_history': jsonEncode(<Object?>[
        _entry(bvid: 'BVvalid').toJson(),
        'not a map',
        <String, Object>{'bvid': 'BVmissing-fields'},
        <String, Object>{
          'bvid': 'BVbad-page',
          'title': '标题',
          'ownerName': '作者',
          'lastPartTitle': '分P',
          'lastPartPageNumber': 0,
          'watchedAt': 'not-a-date',
        },
        _entry(bvid: 'BVvalid', title: '重复项').toJson(),
      ]),
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);

    final List<WatchHistoryEntry> history = await service.loadHistory();

    expect(history, hasLength(1));
    expect(history.single.bvid, 'BVvalid');

    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_watch_history': '[{"bvid":',
    });
    final SharedPreferences malformedPreferences =
        await SharedPreferences.getInstance();
    final WatchHistoryService malformedService = _service(malformedPreferences);

    expect(await malformedService.loadHistory(), isEmpty);
  });

  test('移除和清空只影响本机观看记录', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);
    await service.record(_entry(bvid: 'BVfirst'));
    await service.record(_entry(bvid: 'BVsecond'));

    final List<WatchHistoryEntry> afterRemove =
        await service.remove('BVsecond');

    expect(afterRemove.map((WatchHistoryEntry item) => item.bvid), <String>[
      'BVfirst',
    ]);
    expect(await service.clear(), isEmpty);
    expect(await service.loadHistory(), isEmpty);
    expect(preferences.containsKey('focubili_watch_history'), isFalse);
  });
}
