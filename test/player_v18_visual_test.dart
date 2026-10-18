import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback, video;
import 'player_action_feedback_test.dart' show doubleTap;

const _captureDir = String.fromEnvironment('PLAYER_CAPTURE_DIR');

Future<void> _fonts(WidgetTester tester) async {
  if (_captureDir.isEmpty) return;
  final font = Platform.isWindows
      ? 'C:/Windows/Fonts/msyh.ttc'
      : '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
  await tester.runAsync(() async {
    final material =
        '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    for (final entry in {
      'PlayerReview': font,
      'MaterialIcons': material,
    }.entries) {
      if (await File(entry.value).exists()) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(await File(entry.value).readAsBytes()),
              ),
            ))
            .load();
      }
    }
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDir.isEmpty) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_captureDir).create(recursive: true);
    await File(
      '$_captureDir/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _SurfacePlayback extends FeedbackPlayback
    implements PlaybackVideoSurface {
  @override
  Widget buildVideoSurface() => const ColoredBox(
    color: Color(0xff193b46),
    child: Center(
      child: Text(
        'SYNTHETIC VIDEO FIXTURE',
        style: TextStyle(color: Colors.white24),
      ),
    ),
  );
  @override
  Future<void> seekBy(Duration offset) async {}
  @override
  Future<void> setMediaVolume(double volume) async {}
}

void main() {
  for (final portrait in [true, false]) {
    testWidgets('截图预览保留${portrait ? '竖屏' : '横屏'}全部画面', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _fonts(tester);
      late Directory temporary;
      late File file;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp(
          'focubili_frame_ratio_',
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final width = portrait ? 90 : 160;
        final height = portrait ? 160 : 90;
        canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height / 2),
          Paint()..color = const Color(0xffe19975),
        );
        canvas.drawRect(
          Rect.fromLTWH(0, height / 2, width.toDouble(), height / 2),
          Paint()..color = const Color(0xff70c9aa),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(width, height);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        file = File('${temporary.path}/frame.png');
        await file.writeAsBytes(png!.buffer.asUint8List());
        picture.dispose();
        image.dispose();
      });
      await tester.runAsync(() async {
        final ready = Completer<void>();
        final stream = FileImage(file).resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (_, _) {
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace? stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      });
      final title = TextEditingController(text: '画面比例检查');
      final body = TextEditingController(text: '完整保留上半部和下半部画面。');
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: _captureDir.isEmpty ? null : 'PlayerReview',
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: Colors.white,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: VideoNoteComposer(
                      titleController: title,
                      bodyController: body,
                      position: const Duration(seconds: 20),
                      includeFrame: true,
                      framePath: file.path,
                      saving: false,
                      compact: true,
                      borderless: true,
                      onIncludeFrameChanged: (_) {},
                      onSave: () {},
                      onNew: () {},
                      onClose: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final imageWidget = tester.widget<Image>(
        find.byKey(const Key('note-frame-preview')),
      );
      expect(imageWidget.fit, BoxFit.contain);
      final render = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect(render.image, isNotNull);
      final source = Size(
        render.image!.width.toDouble(),
        render.image!.height.toDouble(),
      );
      expect(applyBoxFit(imageWidget.fit!, source, render.size).source, source);
      expect(render.size.height, lessThanOrEqualTo(280));
      await _capture(
        tester,
        capture,
        portrait ? 'note-portrait' : 'note-landscape',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      title.dispose();
      body.dispose();
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
  }
  for (final size in [const Size(320, 760), const Size(1280, 900)]) {
    testWidgets('真实页面在 $size 双击反馈截图（替身解码器）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _fonts(tester);
      final capture = GlobalKey();
      final playback = _SurfacePlayback();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: _captureDir.isEmpty ? null : 'PlayerReview',
          ),
          home: RepaintBoundary(
            key: capture,
            child: PlayerPage(video: video, playbackService: playback),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byKey(const Key('player-surface')));
      await doubleTap(
        tester,
        Offset(surface.left + surface.width * .8, surface.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('快进 5 秒'), findsOneWidget);
      await _capture(
        tester,
        capture,
        size.width < 500 ? 'player-mobile-seek' : 'player-desktop-seek',
      );
      if (size.width > 500) {
        await tester.pump(const Duration(milliseconds: 1400));
        final hold = await tester.startGesture(surface.center);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        final speed = tester.getRect(
          find.byKey(const Key('temporary-triple-speed')),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.getRect(find.byKey(const Key('temporary-triple-speed'))),
          speed,
        );
        await _capture(tester, capture, 'player-speed-and-volume');
        await hold.up();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
