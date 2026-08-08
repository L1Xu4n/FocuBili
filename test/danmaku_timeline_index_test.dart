import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/danmaku_preferences.dart';
import 'package:focubili/models/danmaku_timeline_index.dart';
import 'package:focubili/models/player_overlay_data.dart';

/// 创建指定时间、文字和模式的测试弹幕，颜色固定为白色。
DanmakuEntry _entry(int milliseconds, String content, {int mode = 1}) {
  return DanmakuEntry(
    position: Duration(milliseconds: milliseconds),
    content: content,
    color: 0xFFFFFF,
    mode: mode,
  );
}

/// 验证 100ms 时间索引的排序、合并、类型筛选和关键词过滤规则。
void main() {
  /// 同一时间桶中的同文字滚动弹幕合并，不同时间桶仍保留原时间点。
  test('相同弹幕只在同一百毫秒时间桶合并', () {
    final DanmakuTimelineIndex index = DanmakuTimelineIndex.fromEntries(
      <DanmakuEntry>[
        _entry(1090, '同一句话'),
        _entry(1010, '同一句话'),
        _entry(1150, '同一句话'),
      ],
      DanmakuPreferences(mergeRepeated: true),
    );

    expect(index.entries, hasLength(2));
    expect(index.entries.first.position, const Duration(milliseconds: 1010));
    expect(index.entries.first.repeatCount, 2);
    expect(index.entries.last.repeatCount, 1);
    expect(index.entriesAt(const Duration(milliseconds: 1050)), hasLength(1));
  });

  /// 类型关闭、屏蔽词和高级弹幕在进入绘制层之前即被过滤，不占用车道。
  test('类型和关键词过滤在时间索引阶段完成', () {
    final DanmakuTimelineIndex index = DanmakuTimelineIndex.fromEntries(
      <DanmakuEntry>[
        _entry(1000, '普通滚动'),
        _entry(1000, '顶部内容', mode: 5),
        _entry(1000, '广告内容', mode: 4),
        _entry(1000, '[高级弹幕数据]', mode: 7),
      ],
      DanmakuPreferences(showTop: false, blockedKeywords: const <String>['广告']),
    );

    expect(index.entries.map((DanmakuEntry entry) => entry.content), <String>[
      '普通滚动',
    ]);
  });

  /// 关闭合并时所有合法弹幕按原时间顺序保留。
  test('关闭合并后保留重复弹幕', () {
    final DanmakuTimelineIndex index = DanmakuTimelineIndex.fromEntries(
      <DanmakuEntry>[_entry(1000, '重复'), _entry(1001, '重复')],
      DanmakuPreferences(mergeRepeated: false),
    );

    expect(index.entries, hasLength(2));
    expect(index.entries, everyElement(isA<DanmakuEntry>()));
  });

  /// 验证统一滚动后，同一时刻的同文字不会因原始模式不同而重复占用车道。
  test('同桶同文字可跨原始显示类型合并', () {
    final DanmakuTimelineIndex index = DanmakuTimelineIndex.fromEntries(
      <DanmakuEntry>[
        _entry(1000, '同一条', mode: 1),
        _entry(1040, '同一条', mode: 4),
        _entry(1080, '同一条', mode: 6),
      ],
      DanmakuPreferences(mergeRepeated: true),
    );

    expect(index.entries, hasLength(1));
    expect(index.entries.single.repeatCount, 3);
  });
}
