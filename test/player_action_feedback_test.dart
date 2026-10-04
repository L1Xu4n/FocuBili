import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_action_feedback.dart';
import 'package:focubili/services/native_playback_service.dart';

import 'refactor_r3_feedback_test.dart' show FeedbackPlayback, video;

/// 记录真实双击派发的播放操作，不调用宿主原生播放器。
class GesturePlayback extends FeedbackPlayback {
  final offsets = <Duration>[];

  @override
  Future<void> seekBy(Duration offset) async => offsets.add(offset);

  @override
  Future<void> pause() async {
    controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: false,
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
      ),
    );
  }
}

/// 将绘制变换也算入边界，不能仅检查动画节点未缩放的布局大小。
Rect paintedRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

/// 同时检查两条边界，捕获缩放首帧越界和固定高度造成的裁切。
void fits(Rect child, Rect parent) {
  expect(child.left, greaterThanOrEqualTo(parent.left - 0.1));
  expect(child.top, greaterThanOrEqualTo(parent.top - 0.1));
  expect(child.right, lessThanOrEqualTo(parent.right + 0.1));
  expect(child.bottom, lessThanOrEqualTo(parent.bottom + 0.1));
}

/// 在指定分区完成一次双击，保持在系统允许的时间范围内。
Future<void> doubleTap(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(position);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final playing in [true, false]) {
    testWidgets('播放状态动画 $playing 的最大缩放帧适配短视口并透传触摸', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              key: const Key('bounds'),
              width: 96,
              height: 26,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const ColoredBox(color: Colors.black),
                  ),
                  PlayerActionFeedback(playing: playing),
                ],
              ),
            ),
          ),
        ),
      );
      final bounds = tester.getRect(find.byKey(const Key('bounds')));
      final circle = find.descendant(
        of: find.byType(PlayerActionFeedback),
        matching: find.byType(DecoratedBox),
      );
      fits(paintedRect(tester, circle), bounds);
      await tester.pump(const Duration(milliseconds: 180));
      fits(paintedRect(tester, circle), bounds);
      await tester.tapAt(bounds.center);
      expect(taps, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final seconds in [5, -15]) {
    for (final size in [
      const Size(130, 24),
      const Size(360, 180),
      const Size(1200, 650),
    ]) {
      testWidgets('快进快退 $seconds 在 $size 和大字体下保持方向且内容不越界', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
              child: Center(
                child: SizedBox(
                  key: const Key('bounds'),
                  width: size.width,
                  height: size.height,
                  child: PlayerSeekFeedback(seconds: seconds, compact: true),
                ),
              ),
            ),
          ),
        );
        final background = find.descendant(
          of: find.byType(PlayerSeekFeedback),
          matching: find.byType(DecoratedBox),
        );
        final bounds = tester.getRect(find.byKey(const Key('bounds')));
        final backgroundRect = paintedRect(tester, background);
        fits(backgroundRect, bounds);
        expect(backgroundRect.width, lessThanOrEqualTo(220));
        if (seconds > 0) {
          expect(backgroundRect.right, closeTo(bounds.right, .1));
        } else {
          expect(backgroundRect.left, closeTo(bounds.left, .1));
        }
        fits(
          paintedRect(
            tester,
            find.text('${seconds > 0 ? '快进' : '快退'} ${seconds.abs()} 秒'),
          ),
          backgroundRect,
        );
        fits(
          paintedRect(
            tester,
            find.descendant(
              of: find.byType(PlayerSeekFeedback),
              matching: find.byType(CustomPaint),
            ),
          ),
          backgroundRect,
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('真实窄屏播放器双击动画适配控制栏之间的空间，连续跳转仍累加', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = GesturePlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: playback),
      ),
    );
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byKey(const Key('player-surface')));
    final right = Offset(surface.left + surface.width * .8, surface.center.dy);
    await doubleTap(tester, right);
    expect(find.text('快进 5 秒'), findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const Key('player-feedback-viewport')),
    );
    final background = find.descendant(
      of: find.byType(PlayerSeekFeedback),
      matching: find.byType(DecoratedBox),
    );
    fits(paintedRect(tester, background), viewport);
    fits(paintedRect(tester, find.text('快进 5 秒')), viewport);
    await tester.pump(const Duration(milliseconds: 60));
    await doubleTap(tester, right);
    expect(find.text('快进 10 秒'), findsOneWidget);
    expect(playback.offsets, [
      const Duration(seconds: 5),
      const Duration(seconds: 5),
    ]);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byType(PlayerSeekFeedback), findsNothing);
    await doubleTap(tester, surface.center);
    expect(find.byType(PlayerActionFeedback), findsOneWidget);
    final circle = find.descendant(
      of: find.byType(PlayerActionFeedback),
      matching: find.byType(DecoratedBox),
    );
    fits(
      paintedRect(tester, circle),
      tester.getRect(find.byKey(const Key('player-feedback-viewport'))),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
