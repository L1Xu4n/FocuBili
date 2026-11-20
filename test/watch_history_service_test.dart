import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/watch_history_service.dart';

/// 创建带缩略图和观看位置的测试观看记录，便于聚焦验证本地存储行为。
WatchHistoryEntry _entry({
  required String bvid,
  String title = '测试视频',
  int pageNumber = 1,
  DateTime? watchedAt,
  String thumbnailUrl = 'https://i0.hdslb.com/bfs/archive/test-cover.jpg',
  Duration lastPosition = const Duration(minutes: 1, seconds: 23),
}) {
  return WatchHistoryEntry(
    bvid: bvid,
    title: title,
    ownerName: '测试 UP 主',
    lastPartTitle: '第 $pageNumber P',
    lastPartPageNumber: pageNumber,
    watchedAt: watchedAt ?? DateTime(2026, 7, 15, 12),
    thumbnailUrl: thumbnailUrl,
    lastPosition: lastPosition,
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
        thumbnailUrl: 'https://i0.hdslb.com/bfs/archive/new-cover.jpg',
        lastPosition: const Duration(hours: 1, minutes: 2, seconds: 3),
      ),
    );

    expect(history, hasLength(1));
    expect(history.single.title, '新标题');
    expect(history.single.lastPartPageNumber, 2);
    expect(
      history.single.thumbnailUrl,
      'https://i0.hdslb.com/bfs/archive/new-cover.jpg',
    );
    expect(
      history.single.lastPosition,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );

    final List<Object?> saved =
        jsonDecode(preferences.getString('focubili_watch_history')!)
            as List<Object?>;
    final Map<String, dynamic> item = Map<String, dynamic>.from(
      saved.single! as Map<String, dynamic>,
    );
    expect(item.keys.toSet(), <String>{
      'bvid',
      'title',
      'ownerName',
      'lastPartTitle',
      'lastPartPageNumber',
      'watchedAt',
      'thumbnailUrl',
      'lastPositionMs',
    });
    expect(
      item['thumbnailUrl'],
      'https://i0.hdslb.com/bfs/archive/new-cover.jpg',
    );
    expect(item['lastPositionMs'], 3723000);
  });

  /// 验证旧版 JSON 没有新字段时仍可读取，并使用空封面和零进度兼容展示。
  test('旧版记录缺少缩略图和观看位置时会安全回退', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_watch_history': jsonEncode(<Object?>[
        <String, Object>{
          'bvid': 'BVlegacy',
          'title': '旧版记录',
          'ownerName': '旧版 UP 主',
          'lastPartTitle': '旧分P',
          'lastPartPageNumber': 1,
          'watchedAt': '2026-07-15T12:00:00.000Z',
        },
      ]),
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);

    final List<WatchHistoryEntry> history = await service.loadHistory();

    expect(history, hasLength(1));
    expect(history.single.thumbnailUrl, isEmpty);
    expect(history.single.lastPosition, Duration.zero);
  });

  /// 验证补封面只修改目标空字段，不移动记录或覆盖原观看日期与进度。
  test('批量补齐旧记录封面会保留顺序和观看状态', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WatchHistoryService service = _service(preferences);
    final WatchHistoryEntry oldEntry = _entry(
      bvid: 'BVold',
      thumbnailUrl: '',
      watchedAt: DateTime(2026, 7, 15, 8),
      lastPosition: const Duration(minutes: 12),
    );
    final WatchHistoryEntry completeEntry = _entry(
      bvid: 'BVcomplete',
      thumbnailUrl: 'https://i0.hdslb.com/bfs/archive/complete.jpg',
      watchedAt: DateTime(2026, 7, 15, 7),
    );
    await service.record(completeEntry);
    await service.record(oldEntry);

    final List<WatchHistoryEntry> updated = await service
        .backfillThumbnails(<String, String>{
          'BVold': 'https://i0.hdslb.com/bfs/archive/backfilled.jpg',
          'BVcomplete': 'https://i0.hdslb.com/bfs/archive/replacement.jpg',
        });

    expect(updated.map((WatchHistoryEntry entry) => entry.bvid), <String>[
      'BVold',
      'BVcomplete',
    ]);
    expect(
      updated.first.thumbnailUrl,
      'https://i0.hdslb.com/bfs/archive/backfilled.jpg',
    );
    expect(updated.first.watchedAt, oldEntry.watchedAt);
    expect(updated.first.lastPosition, const Duration(minutes: 12));
    expect(updated.last.thumbnailUrl, completeEntry.thumbnailUrl);
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

    final List<WatchHistoryEntry> afterRemove = await service.remove(
      'BVsecond',
    );

    expect(afterRemove.map((WatchHistoryEntry item) => item.bvid), <String>[
      'BVfirst',
    ]);
    expect(await service.clear(), isEmpty);
    expect(await service.loadHistory(), isEmpty);
    expect(preferences.containsKey('focubili_watch_history'), isFalse);
  });

  test('批量移除保留不相关记录，且不会被并发封面补写覆盖', () async {
    const key = 'focubili_watch_history';
    final retained = _entry(
      bvid: 'BVkeep',
      thumbnailUrl: '',
      pageNumber: 3,
      lastPosition: const Duration(minutes: 25),
    );
    final retainedRaw = {...retained.toJson(), 'legacyField': 'keep'};
    final elsewhere = _entry(bvid: 'BVnotSelected');
    SharedPreferences.setMockInitialValues({
      key: jsonEncode([
        _entry(bvid: 'BVfirst').toJson(),
        retainedRaw,
        _entry(bvid: 'BVsecond').toJson(),
        'unexpected legacy row',
        elsewhere.toJson(),
      ]),
      'playback.progress.unrelated': 'native/learning data untouched',
    });
    final preferences = await SharedPreferences.getInstance();
    final pendingRemoval = Completer<SharedPreferences>();
    final removing = WatchHistoryService(
      preferencesLoader: () => pendingRemoval.future,
    );
    final player = _service(preferences);
    final deletion = removing.removeMany(['BVfirst', 'BVsecond', 'BVfirst']);
    final backfill = player.backfillThumbnails({
      'BVfirst': 'would reappear if stale',
      'BVkeep': 'new-cover',
    });
    pendingRemoval.complete(preferences);

    final removed = await deletion;
    expect(removed, [retained, elsewhere]);
    final updated = await backfill;
    expect(updated, [retained.copyWith(thumbnailUrl: 'new-cover'), elsewhere]);
    expect(await player.loadHistory(), updated);
    expect(
      preferences.getString('playback.progress.unrelated'),
      'native/learning data untouched',
    );
  });

  test('批量移除仅改写匹配的本机历史行，损坏的 JSON 保持原样', () async {
    const key = 'focubili_watch_history';
    final keep = {..._entry(bvid: 'BVkeep').toJson(), 'legacyField': true};
    const unsupportedRow = 'legacy';
    SharedPreferences.setMockInitialValues({
      key: jsonEncode([
        keep,
        _entry(bvid: 'BVtarget').toJson(),
        unsupportedRow,
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final service = _service(prefs);
    expect(await service.removeMany(['BVtarget']), hasLength(1));
    expect(jsonDecode(prefs.getString(key)!), [keep, unsupportedRow]);

    const malformed = '[{';
    await prefs.setString(key, malformed);
    await expectLater(service.removeMany(['BVtarget']), throwsFormatException);
    expect(prefs.getString(key), malformed);
    expect(await service.clear(), isEmpty);
  });

  /// 验证关闭观看记录后播放器不会新增或更新记录，但已有记录仍能读取。
  test('关闭观看记录后不再写入新进度', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppBehaviorPreferencesService behaviorService =
        AppBehaviorPreferencesService(
          preferencesLoader: () async => preferences,
        );
    final WatchHistoryService service = WatchHistoryService(
      preferencesLoader: () async => preferences,
      behaviorPreferencesService: behaviorService,
    );
    await service.record(_entry(bvid: 'BVexisting'));
    await behaviorService.saveWatchHistoryEnabled(false);

    final List<WatchHistoryEntry> history = await service.record(
      _entry(bvid: 'BVblocked'),
    );

    expect(history.map((WatchHistoryEntry item) => item.bvid), <String>[
      'BVexisting',
    ]);
    expect(await service.loadHistory(), hasLength(1));
  });
}
