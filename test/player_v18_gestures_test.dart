import 'dart:async';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_control_widgets.dart';
import 'package:focubili/features/player/widgets/player_action_feedback.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'player_action_feedback_test.dart' show GesturePlayback, doubleTap;
import 'refactor_r3_feedback_test.dart' show video;

class _LevelsPlayback extends GesturePlayback {
  final levels = <double>[];
  @override
  Future<void> setScreenBrightness(double value) async => levels.add(value);
  @override
  Future<void> setMediaVolume(double value) async => levels.add(value);
}

class _DelayedSpeedPlayback extends _LevelsPlayback {
  final pendingSpeed = Completer<void>();
  @override
  Future<void> setPlaybackSpeed(double value) =>
      value == 3 ? pendingSpeed.future : Future.value();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('松开长按后迟到的倍速回包不能把UI改回三倍速', (tester) async {
    final playback = _DelayedSpeedPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: playback),
      ),
    );
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byKey(const Key('player-surface')));
    final hold = await tester.startGesture(surface.center);
    await tester.pump(const Duration(milliseconds: 650));
    await hold.up();
    await tester.pump();
    playback.pendingSpeed.complete();
    await tester.pumpAndSettle();
    expect(find.text('1x'), findsOneWidget);
    expect(find.text('3x'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final size in [const Size(360, 800), const Size(1280, 900)]) {
    testWidgets('真实PlayerPage双击暂停保持隐藏控制栏 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playback = _LevelsPlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(video: video, playbackService: playback),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byKey(const Key('player-surface')));
      await tester.tapAt(surface.center);
      await tester.pump(const Duration(milliseconds: 550));
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
            .opacity,
        0,
      );
      await doubleTap(tester, surface.center);
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(PlayerActionFeedback), findsOneWidget);
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
            .opacity,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('实际播放器侧滑音量亮度不呼出控制栏，缓存段到达实际滑块', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _LevelsPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: playback),
      ),
    );
    await tester.pumpAndSettle();
    playback.controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
        bufferedRanges: [
          PlaybackBufferRange(
            start: Duration(seconds: 20),
            end: Duration(seconds: 45),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .bufferedRanges
          .single
          .end,
      const Duration(seconds: 45),
    );
    final surface = tester.getRect(find.byKey(const Key('player-surface')));
    await tester.tapAt(surface.center);
    await tester.pump(const Duration(milliseconds: 550));
    for (final side in [.2, .8]) {
      final gesture = await tester.startGesture(
        Offset(surface.left + surface.width * side, surface.center.dy),
      );
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
            .opacity,
        0,
      );
    }
    expect(playback.levels.length, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('原生跳转进入缓冲时加载提示不覆盖方向动画', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _LevelsPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: playback),
      ),
    );
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byKey(const Key('player-surface')));
    await doubleTap(
      tester,
      Offset(surface.left + surface.width * .8, surface.center.dy),
    );
    playback.controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.loading,
        duration: Duration(minutes: 2),
        message: '缓冲回归测试',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final seek = tester.getRect(
      find.descendant(
        of: find.byType(PlayerSeekFeedback),
        matching: find.byType(DecoratedBox),
      ),
    );
    final hint = tester.getRect(find.text('缓冲回归测试'));
    expect(seek.bottom, lessThanOrEqualTo(hint.top));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('长按读取已保存自定义倍速并在松手恢复原速度', (tester) async {
    await const PlaybackPreferencesService().saveLongPressPlaybackSpeed(2.5);
    final playback = _LevelsPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: playback),
      ),
    );
    await tester.pumpAndSettle();
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('player-surface'))),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(playback.rate, 2.5);
    expect(find.text('2.5倍速中>>'), findsOneWidget);
    await hold.up();
    await tester.pumpAndSettle();
    expect(playback.rate, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final initiallyHidden in [true, false]) {
    testWidgets('系统取消侧滑后清除提示并恢复自动隐藏：hidden=$initiallyHidden', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playback = _LevelsPlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(video: video, playbackService: playback),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byKey(const Key('player-surface')));
      if (initiallyHidden) {
        await tester.tapAt(surface.center);
        await tester.pump(const Duration(milliseconds: 550));
      }
      final gesture = await tester.startGesture(
        Offset(surface.left + surface.width * .2, surface.center.dy),
      );
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(find.textContaining(RegExp(r'亮度 \d+%')), findsOneWidget);
      await gesture.cancel();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'亮度 \d+%')), findsNothing);
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
            .opacity,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
