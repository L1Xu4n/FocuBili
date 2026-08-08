import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/danmaku_presentation_window.dart';
import 'package:focubili/models/player_overlay_data.dart';

/// 创建指定秒数的滚动弹幕，便于测试呈现窗口对时间点的筛选。
DanmakuEntry _entry(int seconds, String content) {
  return DanmakuEntry(
    position: Duration(seconds: seconds),
    content: content,
    color: 0xFFFFFF,
    mode: 1,
  );
}

/// 验证晚到片段、重新开启和进度跳转都只让后续弹幕从右侧完整进入。
void main() {
  test('当前片段晚到时丢弃已经错过的历史弹幕', () {
    final DanmakuPresentationWindow window = DanmakuPresentationWindow();
    final List<DanmakuEntry> entries = <DanmakuEntry>[
      _entry(205, '历史一'),
      _entry(211, '历史二'),
      _entry(212, '当前边界'),
      _entry(213, '未来弹幕'),
    ];

    window.prepareSegment(
      segmentIndex: 1,
      currentPosition: const Duration(seconds: 212),
    );
    final List<DanmakuEntry> visible = window.filterEntries(
      segmentIndex: 1,
      entries: entries,
    );

    expect(visible.map((DanmakuEntry entry) => entry.content), <String>[
      '当前边界',
      '未来弹幕',
    ]);
    expect(
      DanmakuTimeline.horizontalOffset(
        elapsed: Duration.zero,
        canvasWidth: 1200,
        textWidth: 180,
      ),
      1200,
    );
  });

  test('提前下载的下一片段仍保留片段开头弹幕', () {
    final DanmakuPresentationWindow window = DanmakuPresentationWindow();
    final List<DanmakuEntry> entries = <DanmakuEntry>[
      _entry(360, '六分钟边界'),
      _entry(361, '下一秒'),
    ];

    window.prepareSegment(
      segmentIndex: 2,
      currentPosition: const Duration(minutes: 5, seconds: 50),
    );

    expect(
      window.filterEntries(segmentIndex: 2, entries: entries),
      same(entries),
    );
    expect(window.floorForSegment(2), DanmakuSegmentLoadResult.segmentDuration);
  });

  test('跳转或重新开启后用新位置替换旧呈现起点', () {
    final DanmakuPresentationWindow window = DanmakuPresentationWindow();
    final List<DanmakuEntry> entries = <DanmakuEntry>[
      _entry(30, '三十秒'),
      _entry(60, '一分钟'),
      _entry(90, '一分半'),
      _entry(120, '两分钟'),
    ];
    window.restartFrom(const Duration(seconds: 90));
    expect(
      window
          .filterEntries(segmentIndex: 1, entries: entries)
          .map((DanmakuEntry entry) => entry.content),
      <String>['一分半', '两分钟'],
    );

    window.restartFrom(const Duration(seconds: 60));
    expect(
      window
          .filterEntries(segmentIndex: 1, entries: entries)
          .map((DanmakuEntry entry) => entry.content),
      <String>['一分钟', '一分半', '两分钟'],
    );
  });

  test('淘汰片段和切换分P会释放呈现起点', () {
    final DanmakuPresentationWindow window = DanmakuPresentationWindow();
    window.restartFrom(const Duration(minutes: 7));
    expect(window.floorForSegment(2), const Duration(minutes: 7));

    window.forgetSegment(2);
    expect(window.floorForSegment(2), const Duration(minutes: 6));

    window.restartFrom(const Duration(minutes: 8));
    window.clear();
    expect(window.floorForSegment(2), const Duration(minutes: 6));
  });
}
