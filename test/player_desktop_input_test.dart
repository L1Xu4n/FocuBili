import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_timeline.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'package:focubili/services/video_shot_service.dart';

import 'player_ab_repeat_test.dart' show AbOverlay;
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _duration = Duration(minutes: 2);
const _video = VideoPreview(
  bvid: 'BV1000000000',
  cid: 5001,
  title: '鼠标播放器示例',
  ownerName: 'FocuBili',
  duration: _duration,
  parts: [
    VideoPart(pageNumber: 1, cid: 5001, title: '示例 P1', duration: _duration),
    VideoPart(pageNumber: 2, cid: 5002, title: '示例 P2', duration: _duration),
  ],
);

const _atlasUrl = 'https://i0.hdslb.com/synthetic-p1.jpg';
const _nextAtlasUrl = 'https://i0.hdslb.com/synthetic-p2.jpg';
VideoShotPreview _preview(int cid) => VideoShotPreview(
  imageUrls: [cid == 5001 ? _atlasUrl : _nextAtlasUrl],
  sampleSeconds: const [0, 30, 60, 90],
  columns: 2,
  rows: 2,
  frameWidth: 16,
  frameHeight: 9,
);

class _Playback extends FeedbackPlayback {
  final commands = <String>[];
  final seeks = <Duration>[];
  final offsets = <Duration>[];
  final openedParts = <int>[];

  void emit(
    bool playing, {
    bool? playRequested,
    PlaybackPhase phase = PlaybackPhase.ready,
    bool inPictureInPicture = false,
  }) => controller.add(
    PlaybackSnapshot(
      phase: phase,
      position: const Duration(seconds: 20),
      duration: _duration,
      isPlaying: playing,
      playRequested: playRequested,
      isInPictureInPicture: inPictureInPicture,
    ),
  );

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    openedParts.add((part ?? video.initialPart).cid);
    emit(true);
  }

  @override
  Future<void> play() async {
    commands.add('play');
    emit(true);
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    emit(false);
  }

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> seekBy(Duration offset) async => offsets.add(offset);
}

class _Metadata implements VideoShotService {
  _Metadata([this.handler = _preview]);
  final FutureOr<VideoShotPreview?> Function(int cid) handler;
  final calls = <int>[];

  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) async {
    expect(bvid, _video.bvid);
    calls.add(cid);
    return handler(cid);
  }
}

class _Atlases extends ImageResourceCache {
  final urls = <String>[];
  Uint8List? bytes;

  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    urls.add(url);
    final atlas = bytes;
    if (atlas == null) throw StateError('No test image');
    return CachedImageBytes(atlas, '$hashCode:$url');
  }

  @override
  Future<void> remove(
    String url, {
    Map<String, String> headers = const {},
  }) async {}
}

const _evidenceKey = Key('desktop-input-visual-boundary');

class _VisualPlayback extends _Playback implements PlaybackVideoSurface {
  @override
  Widget buildVideoSurface() =>
      const CustomPaint(painter: _SampleScene(), size: Size.infinite);
}

class _SampleScene extends CustomPainter {
  const _SampleScene();

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    canvas.drawRect(
      area,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF122336), Color(0xFF164644)],
        ).createShader(area),
    );
    for (var i = 0; i < 6; i++) {
      final x = size.width * (.58 + i * .061);
      final height = size.height * (.09 + i * .038);
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          size.height * .66 - height,
          x + size.width * .027,
          size.height * .66,
          const Radius.circular(3),
        ),
        Paint()
          ..color = const Color(0xFF78DCC7).withValues(alpha: .46 + i * .08),
      );
    }
    final label = TextPainter(
      text: TextSpan(
        style: const TextStyle(
          fontFamily: 'DesktopEvidence',
          fontSize: 16,
          color: Color(0xFFB8D4DB),
        ),
        children: [
          const TextSpan(text: 'FOCUBILI  /  SYNTHETIC LESSON\n\n'),
          TextSpan(
            text: '播放器交互示例',
            style: TextStyle(
              fontSize: (size.width * .04).clamp(20.0, 42.0),
              fontWeight: FontWeight.w700,
              color: const Color(0xFFF4FAFB),
            ),
          ),
          const TextSpan(text: '\n\n仅用于验证输入和时间轴'),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * .52);
    label.paint(canvas, Offset(size.width * .08, size.height * .26));
  }

  @override
  bool shouldRepaint(_SampleScene oldDelegate) => false;
}

final _surface = find.byKey(const Key('player-surface')).first;
final _slider = find.byKey(const Key('player-progress-slider'));
final _hover = find.byKey(const Key('timeline-hover-preview'));
final _dragCard = find.byKey(const Key('timeline-drag-preview'));
final _controls = find.byKey(const Key('player-controls'));
final _picture = find.byKey(const Key('video-shot-frame'));

Future<void> _mount(
  WidgetTester t,
  _Playback playback,
  _Metadata metadata, {
  _Atlases? cache,
  AppPlatform platform = AppPlatform.windows,
  Size size = const Size(1280, 720),
  String? fontFamily,
  TextScaler? textScaler,
}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  if (cache != null) addTearDown(cache.dispose);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: fontFamily),
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: RepaintBoundary(
        key: _evidenceKey,
        child: PlayerPage(
          video: _video,
          playbackService: playback,
          videoShotService: metadata,
          videoShotImageCache: cache,
          appPlatform: platform,
          playerOverlayService: AbOverlay(),
          offlineVideoService: ReviewOfflineLibrary(),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

double _controlOpacity(WidgetTester t) =>
    t.widget<AnimatedOpacity>(_controls).opacity;

Offset _trackAt(WidgetTester t, double value) {
  final slider = t.getRect(_slider);
  final track = PlayerTimelineGeometry.trackRect(
    slider.size,
    offset: slider.topLeft,
  );
  return Offset(track.left + track.width * value, track.center.dy);
}

Future<TestGesture> _mouse(WidgetTester t, Offset start) async {
  final pointer = await t.createGesture(kind: PointerDeviceKind.mouse);
  await pointer.addPointer(location: start);
  return pointer;
}

Future<void> _loadImages(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<Uint8List> _testAtlas(WidgetTester t) async =>
    (await t.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (final (row, col, color) in [
        (0, 0, Colors.red),
        (0, 1, Colors.blue),
        (1, 0, Colors.green),
        (1, 1, Colors.orange),
      ]) {
        canvas.drawRect(
          Rect.fromLTWH(col * 16.0, row * 9.0, 16, 9),
          Paint()..color = color,
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 18);
      picture.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

Future<Color> _previewPixel(WidgetTester t) async {
  final customPaint = find
      .descendant(of: _picture, matching: find.byType(CustomPaint))
      .first;
  final box = t.renderObject<RenderBox>(customPaint);
  final painter = t.widget<CustomPaint>(customPaint).painter!;
  return (await t.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), box.size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      box.size.width.toInt(),
      box.size.height.toInt(),
    );
    picture.dispose();
    final pixel = (await image.toByteData())!;
    final index = (image.width * (image.height ~/ 2) + image.width ~/ 2) * 4;
    image.dispose();
    return Color.fromARGB(
      pixel.getUint8(index + 3),
      pixel.getUint8(index),
      pixel.getUint8(index + 1),
      pixel.getUint8(index + 2),
    );
  }))!;
}

void main() {
  testWidgets('stationary mouse keeps toolbar visible after transport clicks', (
    t,
  ) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    final button = find.byKey(const Key('play-pause-button'));
    final mouse = await _mouse(t, t.getCenter(_surface));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(button));
    await t.pump();
    for (var i = 0; i < 2; i++) {
      await mouse.down(t.getCenter(button));
      await mouse.up();
      await t.pumpAndSettle();
    }
    expect(playback.commands, ['pause', 'play']);
    await t.pump(const Duration(seconds: 6));
    expect(_controlOpacity(t), 1);
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final outside in [false, true]) {
      testWidgets(
        'stationary ${kind.name} after timeline release outside=$outside',
        (t) async {
          final playback = _Playback();
          final metadata = _Metadata();
          await _mount(t, playback, metadata);
          final pointer = await t.createGesture(kind: kind);
          addTearDown(pointer.removePointer);
          await pointer.addPointer(location: t.getCenter(_surface));
          await pointer.down(_trackAt(t, .2));
          await pointer.moveTo(_trackAt(t, .8));
          await t.pump();
          if (outside) {
            await pointer.moveTo(
              t.getRect(_surface).bottomRight + const Offset(30, 30),
            );
            await t.pump();
          }
          await pointer.up();
          await t.pumpAndSettle();
          expect(playback.seeks, hasLength(1));
          expect(metadata.calls, [5001]);
          expect(_hover, findsNothing);
          expect(_dragCard, findsNothing);
          await t.pump(const Duration(seconds: 6));
          expect(
            _controlOpacity(t),
            kind == PointerDeviceKind.mouse && !outside ? 1 : 0,
          );
        },
      );
    }
  }

  for (final platform in [
    AppPlatform.windows,
    AppPlatform.macos,
    AppPlatform.linux,
  ]) {
    testWidgets(
      '${platform.name} mouse single toggles playback, double only fullscreen',
      (t) async {
        final playback = _Playback();
        final metadata = _Metadata();
        await _mount(t, playback, metadata, platform: platform);
        final mouse = await _mouse(t, t.getCenter(_surface));
        addTearDown(mouse.removePointer);

        final center = t.getRect(_surface).center;
        await t.pump(const Duration(seconds: 6));
        expect(_controlOpacity(t), 0);
        await mouse.down(center);
        await mouse.up();
        await t.pump(const Duration(milliseconds: 150));
        expect(_controlOpacity(t), 0);
        expect(playback.commands, isEmpty);
        await t.pump(const Duration(milliseconds: 160));
        expect(_controlOpacity(t), 1);
        expect(playback.commands, ['pause']);
        await t.pump(const Duration(seconds: 6));
        expect(_controlOpacity(t), 1);

        await mouse.down(center);
        await mouse.up();
        await t.pump(kDoubleTapTimeout);
        expect(_controlOpacity(t), 1);
        expect(playback.commands, ['pause', 'play']);
        await t.pump(const Duration(seconds: 6));
        expect(_controlOpacity(t), 0);

        final side = t.getRect(_surface).topLeft + const Offset(80, 220);
        await mouse.down(side);
        await mouse.up();
        await t.pump(const Duration(milliseconds: 65));
        expect(_controlOpacity(t), 0);
        expect(playback.commands, ['pause', 'play']);
        await mouse.down(side);
        await mouse.up();
        await t.pumpAndSettle();
        await t.pump(kDoubleTapTimeout);
        expect(find.byTooltip('退出全屏'), findsOneWidget);
        expect(_controlOpacity(t), 1);
        expect(playback.commands, ['pause', 'play']);
        expect(playback.seeks, isEmpty);
        expect(playback.offsets, isEmpty);
        expect(metadata.calls, isEmpty);

        final fullscreenSide =
            t.getRect(_surface).topLeft + const Offset(100, 200);
        await mouse.down(fullscreenSide);
        await mouse.up();
        await t.pump(const Duration(milliseconds: 65));
        await mouse.down(fullscreenSide);
        await mouse.up();
        await t.pumpAndSettle();
        await t.pump(kDoubleTapTimeout);
        expect(find.byTooltip('进入全屏'), findsOneWidget);
        expect(_controlOpacity(t), 1);
        expect(playback.commands, ['pause', 'play']);
      },
    );
  }

  testWidgets(
    'Space and Escape work when the active desktop player loses focus',
    (t) async {
      final playback = _Playback();
      await _mount(t, playback, _Metadata());
      final pageScope = FocusScope.of(t.element(_surface));
      pageScope.requestScopeFocus();
      await t.pump();
      expect(FocusManager.instance.primaryFocus, same(pageScope));
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      expect(playback.commands, ['pause']);

      final mouse = await _mouse(t, t.getCenter(_surface));
      addTearDown(mouse.removePointer);
      final fullscreenButton = find.byTooltip('进入全屏');
      await mouse.down(t.getCenter(fullscreenButton));
      await mouse.up();
      await t.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      expect(playback.commands, ['pause', 'play']);

      pageScope.requestScopeFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byTooltip('进入全屏'), findsOneWidget);
      expect(playback.commands, ['pause', 'play']);
    },
  );

  testWidgets(
    'desktop keyboard does not leak into a covering route or after player disposal',
    (t) async {
      final playback = _Playback();
      await _mount(t, playback, _Metadata());
      await t.tap(find.byTooltip('进入全屏'));
      await t.pumpAndSettle();
      final navigator = Navigator.of(t.element(_surface));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            requestFocus: false,
            builder: (_) => const Scaffold(body: Text('other page')),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(playback.commands, isEmpty);
      expect(find.text('other page'), findsOneWidget);
      navigator.pop();
      await t.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(playback.commands, isEmpty);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'an interrupted surface click cannot fire after a covering modal closes',
    (t) async {
      final playback = _Playback();
      await _mount(t, playback, _Metadata());
      final center = t.getCenter(_surface);
      final mouse = await _mouse(t, center);
      addTearDown(mouse.removePointer);
      await mouse.down(center);
      await mouse.up();
      await t.pump(const Duration(milliseconds: 25));

      final context = t.element(_surface);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('Covering player')),
        ),
      );
      await t.pump();
      expect(find.text('Covering player'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(playback.commands, isEmpty);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 175));
      expect(find.text('Covering player'), findsNothing);
      await t.pump(kDoubleTapTimeout);
      expect(playback.commands, isEmpty);

      await mouse.down(center);
      await mouse.up();
      await t.pump(kDoubleTapTimeout);
      expect(playback.commands, ['pause']);
    },
  );

  testWidgets('fullscreen lock and PiP block desktop transport', (t) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    await t.tap(find.byTooltip('进入全屏'));
    await t.pumpAndSettle();
    final center = t.getCenter(_surface);
    final mouse = await _mouse(t, center);
    addTearDown(mouse.removePointer);
    await mouse.down(center);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 25));

    await t.tap(find.byTooltip('锁定播放器'));
    await t.pump(kDoubleTapTimeout);
    expect(find.byTooltip('解锁播放器'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await mouse.down(center);
    await mouse.up();
    await t.pump(kDoubleTapTimeout);
    expect(playback.commands, isEmpty);
    expect(_controlOpacity(t), 0);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byTooltip('锁定播放器'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    await mouse.down(center);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 25));
    playback.emit(true, inPictureInPicture: true);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump(kDoubleTapTimeout);
    expect(playback.commands, isEmpty);
    expect(_controlOpacity(t), 0);
  });

  testWidgets('a hidden toolbar does not steal a bottom picture click', (
    t,
  ) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    final mouse = await _mouse(t, t.getCenter(_surface));
    addTearDown(mouse.removePointer);
    final bottom = t.getCenter(_slider);
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    expect(_controlOpacity(t), 0);
    await mouse.down(bottom);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 150));
    expect(
      _controlOpacity(t),
      0,
      reason: 'pointer-up alone cannot reveal hidden controls',
    );
    await t.pump(kDoubleTapTimeout);
    await t.pumpAndSettle();
    expect(_controlOpacity(t), 1);
    expect(playback.commands, ['pause']);
    expect(playback.seeks, isEmpty);
  });

  testWidgets('desktop top hover reveals and holds controls while playing', (
    t,
  ) async {
    final playback = _VisualPlayback();
    await _mount(t, playback, _Metadata(), textScaler: TextScaler.linear(1.5));
    final surface = t.getRect(_surface);
    final picture = t.getRect(find.byKey(const Key('video-fit-contain')));
    // This is a blank pixel in the toolbar padding, over the top letterbox.
    final top = surface.topCenter + const Offset(-60, 1);
    expect(top.dy, lessThan(picture.top));
    final mouse = await _mouse(t, surface.center);
    addTearDown(mouse.removePointer);
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    expect(_controlOpacity(t), 0);

    await mouse.moveTo(top);
    await t.pumpAndSettle();
    expect(_controlOpacity(t), 1);
    await t.pump(const Duration(seconds: 6));
    expect(_controlOpacity(t), 1);

    for (final expected in ['pause', 'play']) {
      await mouse.down(top);
      await mouse.up();
      await t.pump(kDoubleTapTimeout);
      await t.pumpAndSettle();
      expect(playback.commands.last, expected);
    }
    await t.pump(const Duration(seconds: 6));
    expect(_controlOpacity(t), 1, reason: 'stationary hover still holds');
    await mouse.moveTo(surface.center);
    await t.pump(const Duration(seconds: 6));
    expect(_controlOpacity(t), 0);
    expect(playback.commands, ['pause', 'play']);
  });

  testWidgets(
    'a backend pause reveals hidden desktop controls but buffering does not',
    (t) async {
      final playback = _Playback();
      await _mount(t, playback, _Metadata());
      await t.pump(const Duration(seconds: 6));
      expect(_controlOpacity(t), 0);

      playback.emit(false, playRequested: true, phase: PlaybackPhase.loading);
      await t.pump();
      expect(_controlOpacity(t), 0);
      playback.emit(false, playRequested: false);
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 6));
      expect(_controlOpacity(t), 1);

      playback.emit(true, playRequested: true);
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 6));
      expect(_controlOpacity(t), 0);
      expect(playback.commands, isEmpty);
    },
  );

  testWidgets('a mouse click pauses the intent to play through buffering', (
    t,
  ) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    playback.emit(false, playRequested: true, phase: PlaybackPhase.loading);
    await t.pump();

    final center = t.getCenter(_surface);
    final mouse = await _mouse(t, center);
    addTearDown(mouse.removePointer);
    await mouse.down(center);
    await mouse.up();
    await t.pump(kDoubleTapTimeout);
    expect(playback.commands, ['pause']);
    expect(_controlOpacity(t), 1);
  });

  for (final platform in [AppPlatform.android, AppPlatform.ios]) {
    testWidgets(
      '${platform.name} wide tablet keeps touch tap, double-tap and swipe gestures',
      (t) async {
        final playback = _Playback();
        await _mount(
          t,
          playback,
          _Metadata(),
          platform: platform,
          size: const Size(1280, 820),
        );
        expect(
          find.byKey(const Key('player-workspace-layout')),
          findsOneWidget,
        );
        final surface = t.getRect(_surface);
        expect(_controlOpacity(t), 1);
        await t.tapAt(surface.center);
        await t.pump(kDoubleTapTimeout);
        await t.pumpAndSettle();
        expect(_controlOpacity(t), 0);
        final mouse = await _mouse(t, surface.center);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(surface.topCenter + const Offset(0, 2));
        await t.pumpAndSettle();
        expect(
          _controlOpacity(t),
          0,
          reason: 'wide tablets do not inherit the desktop edge hotspot',
        );
        await t.tapAt(surface.center);
        await t.pump(kDoubleTapTimeout);
        await t.pumpAndSettle();
        expect(_controlOpacity(t), 1);
        expect(playback.commands, isEmpty);
        expect(playback.offsets, isEmpty);

        final side =
            surface.topLeft + Offset(surface.width * .12, surface.height * .45);
        await t.tapAt(side);
        await t.pump(const Duration(milliseconds: 60));
        await t.tapAt(side);
        await t.pumpAndSettle();
        expect(playback.offsets, [const Duration(seconds: -5)]);
        expect(find.byTooltip('退出全屏'), findsNothing);
        expect(playback.commands, isEmpty);

        final finger = await t.startGesture(surface.center);
        await finger.moveBy(Offset(surface.width * .16, 0));
        await t.pump();
        expect(find.textContaining('跳转至'), findsOneWidget);
        expect(playback.seeks, isEmpty);
        await finger.up();
        await t.pumpAndSettle();
        expect(playback.seeks, hasLength(1));
        expect(playback.commands, isEmpty);
      },
    );
  }

  testWidgets(
    'mouse near bottom restores and holds controls; target time and atlas cell agree',
    (t) async {
      final playback = _Playback();
      final metadata = _Metadata();
      final cache = _Atlases()..bytes = await _testAtlas(t);
      await _mount(t, playback, metadata, cache: cache);
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      expect(_controlOpacity(t), 0);
      final rect = t.getRect(_surface);
      final mouse = await _mouse(t, rect.center);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(rect.bottomCenter - const Offset(0, 4));
      await t.pumpAndSettle();
      expect(_controlOpacity(t), 1);
      expect(metadata.calls, isEmpty);

      await mouse.moveTo(_trackAt(t, .5));
      await t.pump();
      await _loadImages(t);
      expect(_hover, findsOneWidget);
      expect(
        find.descendant(of: _hover, matching: find.text('1:00')),
        findsOneWidget,
      );
      expect((await _previewPixel(t)).toARGB32(), Colors.green.toARGB32());
      expect(cache.urls, [_atlasUrl]);
      expect(metadata.calls, [5001]);
      expect(playback.commands, isEmpty);
      expect(playback.seeks, isEmpty);
      expect(
        t.getRect(_hover).bottom,
        lessThanOrEqualTo(t.getRect(_slider).top),
      );

      await t.pump(const Duration(seconds: 6));
      expect(_controlOpacity(t), 1);
      await mouse.moveTo(rect.center);
      await t.pumpAndSettle();
      expect(_hover, findsNothing);
      await t.pump(const Duration(seconds: 6));
      expect(_controlOpacity(t), 0);
    },
  );

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      'timeline drag with ${kind.name} previews and only seeks on release',
      (t) async {
        final playback = _Playback();
        final metadata = _Metadata();
        final cache = _Atlases()..bytes = await _testAtlas(t);
        await _mount(t, playback, metadata, cache: cache);
        final start = _trackAt(t, .2);
        final pointer = await t.startGesture(start, kind: kind);
        await pointer.moveTo(_trackAt(t, .8));
        await t.pump(const Duration(milliseconds: 500));
        expect(_hover, findsNothing);
        await _loadImages(t);
        expect(_dragCard, findsOneWidget);
        expect(
          find.descendant(of: _dragCard, matching: find.text('1:36')),
          findsOneWidget,
        );
        expect(_picture, findsOneWidget);
        expect((await _previewPixel(t)).toARGB32(), Colors.orange.toARGB32());
        expect(metadata.calls, [5001]);
        expect(cache.urls, [_atlasUrl]);
        expect(playback.seeks, isEmpty);
        await pointer.up();
        await t.pumpAndSettle();
        expect(playback.seeks, [const Duration(seconds: 96)]);
        expect(metadata.calls, [5001]);
        expect(_hover, findsNothing);
        expect(_dragCard, findsNothing);
      },
    );
  }

  testWidgets('desktop touch keeps tap controls and double-tap seek', (
    t,
  ) async {
    final playback = _Playback();
    final metadata = _Metadata();
    await _mount(t, playback, metadata);
    final rect = t.getRect(_surface);
    final side = rect.topLeft + Offset(rect.width * .1, rect.height * .45);
    await t.tapAt(rect.center);
    await t.pump(kDoubleTapTimeout);
    await t.pumpAndSettle();
    expect(_controlOpacity(t), 0);
    expect(playback.commands, isEmpty);

    await t.tapAt(side);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(side);
    await t.pumpAndSettle();
    expect(playback.offsets, [const Duration(seconds: -5)]);
    expect(playback.commands, isEmpty);
    expect(find.byTooltip('退出全屏'), findsNothing);
    expect(metadata.calls, isEmpty);
  });

  testWidgets('an immediate mouse double click never flushes a single click', (
    t,
  ) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    final center = t.getCenter(_surface);
    final mouse = await _mouse(t, center);
    addTearDown(mouse.removePointer);
    await mouse.down(center);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 25));
    expect(_controlOpacity(t), 1);
    await mouse.down(center);
    await mouse.up();
    await t.pumpAndSettle();
    await t.pump(kDoubleTapTimeout);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(_controlOpacity(t), 1);
    expect(playback.commands, isEmpty);
  });

  testWidgets('mouse and touch do not form a double click or seek together', (
    t,
  ) async {
    final playback = _Playback();
    await _mount(t, playback, _Metadata());
    final rect = t.getRect(_surface);
    final side = rect.topLeft + Offset(rect.width * .1, rect.height * .45);
    final mouse = await _mouse(t, side);
    addTearDown(mouse.removePointer);
    await mouse.down(side);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(side);
    await t.pump(kDoubleTapTimeout);
    await t.pumpAndSettle();
    expect(playback.commands, ['pause']);
    expect(playback.offsets, isEmpty);
    expect(find.byTooltip('退出全屏'), findsNothing);
    expect(_controlOpacity(t), 0); // Separate, later touch toggles controls.
  });

  testWidgets(
    'a second press becoming a mouse picture swipe cancels the waiting click',
    (t) async {
      final playback = _Playback();
      final metadata = _Metadata();
      await _mount(t, playback, metadata);
      final rect = t.getRect(_surface);
      final mouse = await _mouse(t, rect.center);
      addTearDown(mouse.removePointer);
      await mouse.down(rect.center);
      await mouse.up();
      await t.pump(const Duration(milliseconds: 65));
      await mouse.down(rect.center);
      await mouse.moveBy(Offset(rect.width * .1, 0));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('跳转至'), findsOneWidget);
      expect(metadata.calls, [5001]);
      expect(playback.seeks, isEmpty);
      expect(playback.commands, isEmpty);
      await mouse.up();
      await t.pumpAndSettle();
      expect(playback.seeks, hasLength(1));
      expect(playback.commands, isEmpty);
      expect(find.byTooltip('退出全屏'), findsNothing);
    },
  );

  testWidgets(
    'drag reuses pending hover metadata but late results cannot reopen its card',
    (t) async {
      final pending = Completer<VideoShotPreview?>();
      final playback = _Playback();
      final metadata = _Metadata((_) => pending.future);
      final cache = _Atlases()..bytes = await _testAtlas(t);
      await _mount(t, playback, metadata, cache: cache);
      final mouse = await _mouse(t, t.getCenter(_surface));
      addTearDown(mouse.removePointer);

      await mouse.moveTo(_trackAt(t, .2));
      await t.pump();
      expect(_hover, findsOneWidget);
      expect(metadata.calls, [5001]);
      expect(cache.urls, isEmpty);
      await mouse.down(_trackAt(t, .2));
      await mouse.moveTo(_trackAt(t, .8));
      await t.pump();
      expect(_hover, findsNothing);
      expect(_dragCard, findsOneWidget);
      expect(
        find.descendant(of: _dragCard, matching: find.text('1:36')),
        findsOneWidget,
      );
      expect(metadata.calls, [5001]);
      await mouse.up();
      pending.complete(_preview(5001));
      await t.pumpAndSettle();
      expect(playback.seeks, [const Duration(seconds: 96)]);
      expect(cache.urls, isEmpty);
      expect(_hover, findsNothing);
      expect(_dragCard, findsNothing);
      expect(_picture, findsNothing);

      await mouse.moveTo(_trackAt(t, .8) + const Offset(0, 1));
      await t.pump();
      await _loadImages(t);
      expect(_hover, findsOneWidget);
      expect((await _previewPixel(t)).toARGB32(), Colors.orange.toARGB32());
      expect(metadata.calls, [5001]);
    },
  );

  testWidgets('late old-P metadata cannot attach to a hover on the new part', (
    t,
  ) async {
    final pending = Completer<VideoShotPreview?>();
    final playback = _Playback();
    final metadata = _Metadata(
      (cid) => cid == 5001 ? pending.future : _preview(cid),
    );
    final cache = _Atlases()..bytes = await _testAtlas(t);
    await _mount(t, playback, metadata, cache: cache);
    final mouse = await _mouse(t, t.getCenter(_surface));
    addTearDown(mouse.removePointer);

    await mouse.moveTo(_trackAt(t, .3));
    await t.pump();
    expect(_hover, findsOneWidget);
    expect(cache.urls, isEmpty);
    await t.tap(find.byKey(const Key('next-part-button')));
    await t.pumpAndSettle();
    expect(playback.openedParts, [5001, 5002]);
    expect(_hover, findsNothing);
    await mouse.moveTo(_trackAt(t, .7));
    await t.pump();
    await _loadImages(t);
    expect(cache.urls, [_nextAtlasUrl]);
    expect((await _previewPixel(t)).toARGB32(), Colors.green.toARGB32());

    pending.complete(_preview(5001));
    await t.pumpAndSettle();
    expect(_hover, findsOneWidget);
    expect(cache.urls, [_nextAtlasUrl]);
    expect(metadata.calls, [5001, 5002]);
  });

  testWidgets(
    'missing frames show time without repeatedly contacting metadata',
    (t) async {
      final metadata = _Metadata((_) => null);
      final playback = _Playback();
      final cache = _Atlases();
      await _mount(t, playback, metadata, cache: cache);
      final mouse = await _mouse(t, t.getCenter(_surface));
      addTearDown(mouse.removePointer);
      for (final position in [.1, .2, .3, .4]) {
        await mouse.moveTo(_trackAt(t, position));
        await t.pumpAndSettle();
      }
      expect(_hover, findsOneWidget);
      expect(
        find.descendant(of: _hover, matching: find.text('0:48')),
        findsOneWidget,
      );
      expect(metadata.calls, [5001]);
      expect(cache.urls, isEmpty);
      await mouse.moveTo(t.getCenter(_surface));
      await t.pumpAndSettle();
      await mouse.moveTo(_trackAt(t, .4));
      await t.pumpAndSettle();
      expect(metadata.calls, [5001, 5001]);
    },
  );

  testWidgets(
    'pending surface click is discarded if the timeline or a new part is selected',
    (t) async {
      final playback = _Playback();
      final metadata = _Metadata();
      await _mount(t, playback, metadata);
      final center = t.getCenter(_surface);
      final mouse = await _mouse(t, center);
      addTearDown(mouse.removePointer);

      await mouse.down(center);
      await mouse.up();
      await t.pump(const Duration(milliseconds: 65));
      await mouse.down(_trackAt(t, .2));
      await mouse.moveTo(_trackAt(t, .8));
      await t.pump(const Duration(milliseconds: 400));
      await mouse.up();
      await t.pumpAndSettle();
      expect(playback.commands, isEmpty);
      expect(playback.seeks, [const Duration(seconds: 96)]);

      await mouse.down(center);
      await mouse.up();
      await t.pump(const Duration(milliseconds: 65));
      await t.tap(find.byKey(const Key('next-part-button')));
      await t.pump(kDoubleTapTimeout);
      await t.pumpAndSettle();
      expect(playback.openedParts, [5001, 5002]);
      expect(playback.commands, [
        'pause',
      ]); // Part transition, not a late click.
      expect(metadata.calls, [5001]);
    },
  );

  testWidgets(
    'thumbnail is kept inside a narrow large-text player at both endpoints',
    (t) async {
      final playback = _Playback();
      final metadata = _Metadata();
      final cache = _Atlases()..bytes = await _testAtlas(t);
      await _mount(
        t,
        playback,
        metadata,
        cache: cache,
        size: const Size(640, 500),
        textScaler: TextScaler.linear(1.6),
      );
      final mouse = await _mouse(t, t.getCenter(_surface));
      addTearDown(mouse.removePointer);
      final viewport = t.getRect(
        find.byKey(const Key('player-feedback-viewport')),
      );
      for (final (fraction, time) in [(0.0, '0:00'), (1.0, '2:00')]) {
        await mouse.moveTo(_trackAt(t, fraction));
        await t.pump();
        await _loadImages(t);
        expect(
          find.descendant(of: _hover, matching: find.text(time)),
          findsOneWidget,
        );
        expect(_picture, findsOneWidget);
        final card = t.getRect(_hover);
        expect(card.left, greaterThanOrEqualTo(viewport.left - .1));
        expect(card.right, lessThanOrEqualTo(viewport.right + .1));
        expect(card.top, greaterThanOrEqualTo(viewport.top - .1));
        expect(card.bottom, lessThanOrEqualTo(t.getRect(_slider).top));
        expect(t.takeException(), isNull);
      }
      expect(cache.urls, [_atlasUrl]);
    },
  );

  testWidgets('expanded fullscreen notebook masks the timeline under it', (
    t,
  ) async {
    final playback = _Playback();
    final metadata = _Metadata((_) => null);
    await _mount(t, playback, metadata);
    await t.tap(find.byTooltip('进入全屏'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('fullscreen-note-button')));
    await t.pumpAndSettle();
    final pane = find.byKey(const Key('fullscreen-video-notes-material'));
    expect(pane, findsOneWidget);
    final pointerPosition = _trackAt(t, .8);
    expect(t.getRect(pane).contains(pointerPosition), isTrue);
    final mouse = await _mouse(t, t.getCenter(_surface));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(pointerPosition);
    await t.pumpAndSettle();
    expect(_hover, findsNothing);
    expect(metadata.calls, isEmpty);

    final note = find.byKey(const Key('note-body-field'));
    await t.enterText(note, 'two words');
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    final field = t.widget<EditableText>(
      find.descendant(of: note, matching: find.byType(EditableText)),
    );
    expect(field.focusNode.hasFocus, isTrue);
    expect(field.controller.text, 'two words');
    expect(playback.commands, isEmpty);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await mouse.moveTo(_trackAt(t, .7));
    await t.pumpAndSettle();
    expect(_hover, findsOneWidget);
    expect(metadata.calls, [5001]);
    expect(playback.seeks, isEmpty);
  });

  final evidenceDirectory =
      Platform.environment['FOCUBILI_DESKTOP_INPUT_EVIDENCE'];
  testWidgets('desktop timeline raster evidence', (t) async {
    final font = Platform.environment['FOCUBILI_DESKTOP_INPUT_FONT'];
    final iconFont = Platform.environment['FOCUBILI_DESKTOP_INPUT_ICON_FONT'];
    await t.runAsync(() async {
      Future<void> loadFont(String? path, String family) async {
        if (path == null) return;
        final bytes = await File(path).readAsBytes();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }

      await loadFont(font, 'DesktopEvidence');
      await loadFont(iconFont, 'MaterialIcons');
    });

    Future<void> capture(String file) async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(_evidenceKey),
      );
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        await File(
          '$evidenceDirectory/$file.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
      });
    }

    final cache = _Atlases()..bytes = await _testAtlas(t);
    await _mount(
      t,
      _VisualPlayback(),
      _Metadata(),
      cache: cache,
      fontFamily: font == null ? null : 'DesktopEvidence',
    );
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    final rect = t.getRect(_surface);
    final mouse = await _mouse(t, rect.center);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(rect.bottomCenter - const Offset(0, 4));
    await t.pumpAndSettle();
    await capture('bottom');
    await mouse.moveTo(_trackAt(t, .50));
    await t.pump();
    await _loadImages(t);
    await capture('hover');
    await mouse.down(_trackAt(t, .50));
    await mouse.moveTo(_trackAt(t, .80));
    await t.pump();
    await _loadImages(t);
    expect(_dragCard, findsOneWidget);
    expect(_picture, findsOneWidget);
    await capture('drag');
    await mouse.up();
    await t.pumpAndSettle();
  }, skip: evidenceDirectory == null);
}
