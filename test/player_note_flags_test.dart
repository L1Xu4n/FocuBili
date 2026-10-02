import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/player/widgets/player_timeline.dart';
import 'package:focubili/models/video_note.dart';

/// 为旗标测试创建一个有稳定身份与时间的本机笔记。
VideoNote _note(
  String id,
  int milliseconds, {
  String bvid = 'BVtest',
  int cid = 1,
}) => VideoNote(
  id: id,
  bvid: bvid,
  partCid: cid,
  partPageNumber: 1,
  partTitle: '测试分 P',
  videoTitle: '测试视频',
  ownerName: '测试UP',
  title: id,
  body: '正文',
  position: Duration(milliseconds: milliseconds),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// 验证身份过滤、秒级合并、端点和密集区域的实际点击命中。
void main() {
  /// 同一秒的显示时间只有一个旗标，异视频、异分 P 和越界时间不出现。
  test('旗标按显示秒合并并过滤视频分P和时长', () {
    final grouped = groupPlayerNoteFlags(
      notes: [
        _note('a', 400),
        _note('b', 999),
        _note('end', 10000),
        _note('outside', 10001),
        _note('negative', -1),
        _note('other-bv', 1000, bvid: 'BVother'),
        _note('other-p', 1000, cid: 2),
      ],
      bvid: 'BVtest',
      cid: 1,
      duration: const Duration(seconds: 10),
    );
    expect(grouped.map((group) => group.length), [2, 1]);
    expect(grouped.last.single.id, 'end');
  });

  /// 曲线和旗标的实际位置共用安全区域及端距，两端均能独立点击。
  testWidgets('旗标与实际Slider轨道端点对齐且点击不改变进度', (tester) async {
    final clicked = <List<VideoNote>>[];
    var sliderChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(left: 32, right: 20),
          ),
          child: Scaffold(
            body: SafeArea(
              minimum: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: [
                  PlayerNoteFlags(
                    notes: [_note('start', 0), _note('end', 10000)],
                    bvid: 'BVtest',
                    cid: 1,
                    duration: const Duration(seconds: 10),
                    onOpen: clicked.add,
                  ),
                  SliderTheme(
                    data: const SliderThemeData(
                      trackShape: PlayerTimelineTrackShape(),
                    ),
                    child: Slider(
                      key: const Key('timeline-test-slider'),
                      padding: EdgeInsets.zero,
                      value: 0,
                      onChanged: (_) => sliderChanges++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final sliderBox = tester.renderObject<RenderBox>(
      find.byKey(const Key('timeline-test-slider')),
    );
    const shape = PlayerTimelineTrackShape();
    final track = shape.getPreferredRect(
      parentBox: sliderBox,
      offset: tester.getTopLeft(find.byKey(const Key('timeline-test-slider'))),
      sliderTheme: const SliderThemeData(),
    );
    final start = tester.getCenter(
      find.byKey(const ValueKey('player-note-flag-0')),
    );
    final end = tester.getCenter(
      find.byKey(const ValueKey('player-note-flag-10')),
    );
    expect(start.dx, closeTo(track.left, 0.01));
    expect(end.dx, closeTo(track.right, 0.01));
    await tester.tapAt(start);
    await tester.tapAt(end);
    expect(clicked.map((group) => group.single.id), ['start', 'end']);
    expect(sliderChanges, 0);
  });

  /// 密集不同时间点保留多个视觉旗标，点击区域列出全部笔记且不遮挡遗漏。
  testWidgets('密集时间点通过共享选择入口全部可达', (tester) async {
    List<VideoNote>? clicked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: PlayerNoteFlags(
              notes: [_note('a', 1000), _note('b', 2000), _note('c', 3000)],
              bvid: 'BVtest',
              cid: 1,
              duration: const Duration(seconds: 100),
              onOpen: (notes) => clicked = notes,
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.flag_rounded), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('player-note-flag-hit-0')));
    expect(clicked!.map((note) => note.id), ['a', 'b', 'c']);
  });
}
