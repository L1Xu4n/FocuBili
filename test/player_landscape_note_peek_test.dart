import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/fullscreen_video_transform.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:focubili/services/video_shot_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;

const _title = '三角形的面积';
const _draft = '同底同高时，三角形面积是平行四边形的一半。';
const _anchor = Duration(seconds: 20);
const _evidencePath = String.fromEnvironment('FOCUBILI_NOTE_PEEK_EVIDENCE');
const _before = bool.fromEnvironment('FOCUBILI_NOTE_PEEK_BASELINE');
const _video = VideoPreview(
  bvid: 'BVsample42',
  cid: 42,
  title: '几何入门 · 面积换算',
  ownerName: '合成课程示例',
  duration: Duration(minutes: 2),
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 42,
      title: '几何入门',
      duration: Duration(minutes: 2),
    ),
  ],
);

final _panel = find.byKey(const Key('fullscreen-video-notes-material'));
final _inlinePanel = find.byKey(const Key('portrait-video-notes-panel'));
final _workspacePane = find.byKey(const Key('player-workspace-side-pane'));
final _barrier = find.byKey(const Key('park-video-notes-barrier'));
final _handle = find.byKey(const Key('restore-parked-video-notes'));
final _titleField = find.byKey(const Key('note-title-field'));
final _bodyField = find.byKey(const Key('note-body-field'));
final _slider = find.byKey(const Key('player-progress-slider'));
final _surface = find.byKey(const Key('player-surface'));
final _playPause = find.byKey(const Key('play-pause-button'));
final _scroll = find.byKey(const Key('side-video-note-composer-scroll'));
final _position = find.byKey(const Key('note-position-label'));

class _PeekPlayback extends FeedbackPlayback implements PlaybackVideoSurface {
  _PeekPlayback({required this.startsPlaying});
  final bool startsPlaying;
  final seeks = <Duration>[];
  int pauses = 0;
  int plays = 0;
  PlaybackSnapshot current = const PlaybackSnapshot(phase: PlaybackPhase.idle);

  void emit(PlaybackSnapshot state) {
    current = state;
    controller.add(state);
  }

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    onlineOpens++;
    emit(
      PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: startsPlaying,
        position: _anchor,
        duration: _video.duration,
        videoAspectRatio: 16 / 9,
      ),
    );
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    emit(current.copyWith(position: position));
  }

  @override
  Future<void> play() async {
    plays++;
    emit(current.copyWith(isPlaying: true));
  }

  @override
  Future<void> pause() async {
    pauses++;
    emit(current.copyWith(isPlaying: false));
  }

  @override
  Widget buildVideoSurface() => const SizedBox.expand(
    key: Key('synthetic-note-preview'),
    child: CustomPaint(painter: _SyntheticLessonSlide()),
  );
}

/// Generated test-only media; no external thumbnail, account or video.
class _SyntheticLessonSlide extends CustomPainter {
  const _SyntheticLessonSlide();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 960, size.height / 540);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 960, 540),
      Paint()..color = const Color(0xff162b38),
    );
    final grid = Paint()
      ..color = const Color(0x305f9e9e)
      ..strokeWidth = 1;
    for (var i = 24.0; i < 960; i += 34) {
      canvas.drawLine(Offset(i, 0), Offset(i, 540), grid);
    }
    for (var i = 24.0; i < 540; i += 34) {
      canvas.drawLine(Offset(0, i), Offset(960, i), grid);
    }
    final triangle = Path()
      ..moveTo(85, 410)
      ..lineTo(355, 410)
      ..lineTo(180, 195)
      ..close();
    canvas.drawPath(triangle, Paint()..color = const Color(0xff274896));
    canvas.drawPath(
      triangle,
      Paint()
        ..color = const Color(0xffabc7ff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    final accent = Paint()
      ..color = const Color(0xff97e0c8)
      ..strokeWidth = 3;
    for (double y = 201; y < 400; y += 12) {
      canvas.drawLine(Offset(180, y), Offset(180, y + 7), accent);
    }

    void label(String value, Offset offset, double fontSize, Color color) {
      final text = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            fontFamily: 'NotePeekEvidenceCJK',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, offset);
      text.dispose();
    }

    label('几何入门', const Offset(64, 96), 38, const Color(0xffe3eded));
    label('b', const Offset(206, 421), 26, const Color(0xffc5dbfe));
    label('h', const Offset(190, 295), 26, const Color(0xff97e0c8));
    label('S = b × h ÷ 2', const Offset(500, 242), 38, const Color(0xffd9ecec));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SyntheticLessonSlide oldDelegate) => false;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_evidencePath.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = await Directory(_evidencePath).create(recursive: true);
    await File('${out.path}/$name.png').writeAsBytes(
      bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    image.dispose();
  });
}

Future<void> _loadEvidenceFonts() async {
  if (_evidencePath.isEmpty) return;
  const cjkFont = String.fromEnvironment(
    'FOCUBILI_NOTE_PEEK_CJK_FONT',
    defaultValue: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  );
  const iconsFont = String.fromEnvironment('FOCUBILI_NOTE_PEEK_ICONS_FONT');
  const iconsPath = 'material_fonts/MaterialIcons-Regular.otf';
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
    iconsFont.isNotEmpty
        ? iconsFont
        : flutterRoot != null
        ? '$flutterRoot/bin/cache/artifacts/$iconsPath'
        : File.fromUri(
            File(
              Platform.resolvedExecutable,
            ).absolute.uri.resolve('../../$iconsPath'),
          ).path,
  );
  for (final font in {
    'NotePeekEvidenceCJK': File(cjkFont),
    'MaterialIcons': icons,
  }.entries) {
    await (FontLoader(
      font.key,
    )..addFont(font.value.readAsBytes().then(ByteData.sublistView))).load();
  }
}

Future<GlobalKey> _mount(
  WidgetTester tester,
  _PeekPlayback playback,
  VideoNoteService noteService, {
  required Size landscape,
  bool fullscreen = true,
  AppPlatform appPlatform = AppPlatform.android,
  double scale = 1,
}) async {
  final boundary = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = fullscreen ? const Size(396, 700) : landscape;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xff9ba7ec),
          fontFamily: _evidencePath.isEmpty ? null : 'NotePeekEvidenceCJK',
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PlayerPage(
          video: _video,
          playbackService: playback,
          videoNoteService: noteService,
          videoShotService: const EmptyVideoShotService(),
          appPlatform: appPlatform,
        ),
      ),
    ),
  );
  await _paint(tester);
  if (fullscreen) {
    await tester.tap(find.byTooltip('进入全屏'));
    tester.view.physicalSize = landscape;
    await _paint(tester);
  }
  return boundary;
}

// Large-text metadata marquees and a focused caret can keep animating.
Future<void> _paint(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump();
}

Future<void> _open(WidgetTester tester, {bool fullscreen = true}) async {
  final entry = fullscreen
      ? find.byKey(const Key('fullscreen-note-button'))
      : find.byTooltip('记笔记');
  if (!fullscreen) await tester.ensureVisible(entry);
  await tester.tap(entry);
  await _paint(tester);
}

Offset _leftEdge(WidgetTester tester) {
  final rect = tester.getRect(_surface);
  return Offset(rect.left + rect.width * .21, rect.center.dy);
}

TextEditingController _controller(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!;

ScrollableState _editorScroll(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(of: _scroll, matching: find.byType(Scrollable)).first,
    );

Future<void> _verifyImeScrollAndUndo(WidgetTester tester) async {
  final playback = _PeekPlayback(startsPlaying: false);
  await _mount(
    tester,
    playback,
    VideoNoteService(),
    landscape: const Size(542, 300),
    scale: 2,
  );
  tester.view.viewPadding = const FakeViewPadding(right: 19);
  tester.view.padding = const FakeViewPadding(right: 19);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  await _paint(tester);
  await _open(tester);
  final draft = List.filled(10, _draft).join('\n');
  await tester.enterText(_titleField, _title);
  await tester.ensureVisible(_bodyField);
  await tester.showKeyboard(_bodyField);
  tester.view.viewInsets = const FakeViewPadding(bottom: 155);
  addTearDown(tester.view.resetViewInsets);
  await _paint(tester);
  tester.testTextInput.enterText(draft);
  await tester.pump(const Duration(milliseconds: 500));
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '$draft!',
      selection: TextSelection.collapsed(offset: draft.length + 1),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  expect(tester.takeException(), isNull);
  final scroller = _editorScroll(tester);
  final beforeParkingScroll = scroller.position.pixels;
  final field = tester.widget<EditableText>(
    find.descendant(of: _bodyField, matching: find.byType(EditableText)),
  );
  await tester.tapAt(_leftEdge(tester));
  await tester.pump();
  expect(field.focusNode.hasFocus, isFalse);
  tester.view.resetViewInsets();
  await _paint(tester);
  expect(playback.current.isPlaying, isFalse);
  expect(_handle.hitTestable(), findsOneWidget);
  expect(tester.getTopRight(_handle).dx, closeTo(523, .1));
  expect(_editorScroll(tester), same(scroller));
  expect(_editorScroll(tester).position.pixels, greaterThan(0));
  final savedScrollOffset = scroller.position.pixels;

  final body = tester.getRect(_surface);
  final horizontal = await tester.startGesture(
    Offset(body.left + 80, body.center.dy),
  );
  await horizontal.moveBy(const Offset(75, 0));
  await tester.pump();
  await horizontal.moveBy(const Offset(95, 0));
  await tester.pump();
  await horizontal.up();
  await _paint(tester);
  expect(playback.seeks, hasLength(1));
  expect(playback.current.isPlaying, isFalse);
  await tester.tap(_playPause);
  await _paint(tester);
  expect(playback.current.isPlaying, isTrue);
  expect(playback.plays, 1);
  expect(scroller.position.pixels, savedScrollOffset);

  await tester.tap(_handle);
  await _paint(tester);
  expect(field.focusNode.hasFocus, isFalse);
  final revealedScroll = _editorScroll(tester).position;
  expect(
    revealedScroll.pixels,
    beforeParkingScroll.clamp(
      revealedScroll.minScrollExtent,
      revealedScroll.maxScrollExtent,
    ),
  );
  expect(_controller(tester, _bodyField).text, '$draft!');
  await tester.ensureVisible(_bodyField);
  await tester.showKeyboard(_bodyField);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 450));
  expect(_controller(tester, _bodyField).text, draft);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(_loadEvidenceFonts);

  testWidgets('横屏第一次点进度仅收起，同一草稿可继续并能手动保存', (tester) async {
    final service = VideoNoteService();
    final playback = _PeekPlayback(startsPlaying: true);
    final boundary = await _mount(
      tester,
      playback,
      service,
      landscape: const Size(860, 420),
    );
    final mediaState = tester.state(find.byType(FullscreenVideoTransform));
    await _open(tester);
    await tester.enterText(_titleField, _title);
    await tester.enterText(_bodyField, _draft);
    const selection = TextSelection(baseOffset: 0, extentOffset: 4);
    _controller(tester, _bodyField).selection = selection;
    await tester.pump();
    expect(find.text('视频位置：00:20'), findsOneWidget);
    if (!_before) {
      expect(find.semantics.byLabel('收起时间点笔记'), findsOneWidget);
    }
    await _capture(tester, boundary, _before ? 'before-open' : '01-expanded');
    final slider = tester.getRect(_slider);
    final untouchedTap = Offset(
      slider.left + slider.width * .15,
      slider.center.dy,
    );
    await tester.tapAt(untouchedTap);
    await tester.pump();
    if (_before) await _capture(tester, boundary, 'before-after-outside');
    expect(playback.seeks, isEmpty, reason: 'first outside tap must not seek');
    expect(playback.current.isPlaying, isTrue);
    expect(_barrier, findsNothing);
    expect(_handle.hitTestable(), findsOneWidget);
    expect(_bodyField.hitTestable(), findsNothing); // Even mid-animation.
    expect(find.semantics.byLabel('继续编辑时间点笔记'), findsOneWidget);
    expect(find.semantics.byLabel('视频位置：00:20'), findsNothing);
    final handleSize = tester.getSize(_handle);
    expect(handleSize.width, greaterThanOrEqualTo(48));
    expect(handleSize.height, greaterThanOrEqualTo(48));

    // While the panel is still moving offscreen, the seek control already owns
    // the gesture. Its down event must not hit a transparent dismiss barrier.
    await tester.dragFrom(
      Offset(slider.left + slider.width * .35, slider.center.dy),
      Offset(slider.width * .25, 0),
    );
    await _paint(tester);
    expect(playback.seeks, hasLength(1));
    expect(playback.current.position.inSeconds, greaterThan(45));
    expect(playback.current.isPlaying, isTrue);
    expect(tester.getTopLeft(_panel).dx, greaterThan(860));
    expect(playback.onlineOpens, 1);
    expect(
      identical(
        tester.state(find.byType(FullscreenVideoTransform)),
        mediaState,
      ),
      isTrue,
    );
    await _capture(tester, boundary, '02-parked-after-seek');

    await tester.tap(_handle);
    await _paint(tester);
    expect(_barrier, findsOneWidget);
    expect(_handle, findsNothing);
    expect(_controller(tester, _titleField).text, _title);
    expect(
      _controller(tester, _bodyField).value,
      const TextEditingValue(text: _draft, selection: selection),
    );
    expect(tester.widget<Text>(_position).data, '视频位置：00:20');

    // Reverse an in-flight slide as well as a completed one.
    await tester.tapAt(_leftEdge(tester));
    await tester.pump();
    await tester.tap(_handle);
    await _paint(tester);
    final save = find.byKey(const Key('save-video-note'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await _paint(tester);
    final note = (await service.loadNotesForVideo(_video.bvid)).single;
    expect(note.title, _title);
    expect(note.body, _draft);
    expect(note.position, _anchor);
    expect(playback.seeks, hasLength(1));
    expect(playback.pauses, 0);
    expect(playback.plays, 0);
    expect(tester.takeException(), isNull);
    _editorScroll(tester).position.jumpTo(0);
    await _paint(tester);
    await _capture(tester, boundary, '03-restored-and-saved');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    '小横屏大字和键盘时保持滚动及撤销，收起后播放按钮和横滑可用',
    _verifyImeScrollAndUndo,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('宽窗口的笔记替换工作台右栏，播放区不变，关闭后恢复详情', (tester) async {
    final service = VideoNoteService();
    final playback = _PeekPlayback(startsPlaying: false);
    final boundary = await _mount(
      tester,
      playback,
      service,
      landscape: const Size(1024, 560),
      fullscreen: false,
      appPlatform: AppPlatform.windows,
      scale: 1.4,
    );
    final noteEntry = find.byTooltip('记笔记');
    final paneRect = tester.getRect(_workspacePane);
    final playerRect = tester.getRect(_surface);
    final playerState = tester.state(find.byType(FullscreenVideoTransform));
    expect(
      find.descendant(of: _workspacePane, matching: noteEntry),
      findsOneWidget,
    );
    await tester.ensureVisible(noteEntry);
    await tester.tap(noteEntry, kind: ui.PointerDeviceKind.mouse);
    await _paint(tester);
    await _capture(
      tester,
      boundary,
      _before ? 'workspace-before' : 'workspace-inline',
    );
    expect(
      find.descendant(of: _workspacePane, matching: _inlinePanel),
      findsOneWidget,
    );
    expect(noteEntry, findsNothing);
    expect(_panel, findsNothing);
    expect(_barrier, findsNothing);
    expect(_handle, findsNothing);
    expect(tester.getRect(_workspacePane), paneRect);
    expect(tester.getRect(_surface), playerRect);
    expect(
      tester.state(find.byType(FullscreenVideoTransform)),
      same(playerState),
    );
    await tester.tap(_playPause, kind: ui.PointerDeviceKind.mouse);
    await tester.pump();
    expect(playback.plays, 1);
    expect(_inlinePanel, findsOneWidget);

    await tester.enterText(_titleField, _title);
    await tester.enterText(_bodyField, _draft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(playback.pauses, 0);
    expect(tester.widget<Text>(_position).data, '00:20');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _paint(tester);
    expect(_inlinePanel, findsNothing);
    expect(noteEntry, findsOneWidget);
    expect(tester.getRect(_workspacePane), paneRect);
    final note = (await service.loadNotesForVideo(_video.bvid)).single;
    expect(note.title, _title);
    expect(note.body, _draft);
    expect(note.position, _anchor);

    await _open(tester, fullscreen: false);
    await tester.tap(find.byKey(Key('portrait-video-note-${note.id}')));
    await _paint(tester);
    expect(_controller(tester, _bodyField).text, _draft);
    expect(playback.seeks, isEmpty);
    final jump = find.byKey(const Key('jump-to-video-note-position'));
    await tester.ensureVisible(jump);
    await tester.tap(jump);
    await _paint(tester);
    expect(playback.seeks, [_anchor]);
    await tester.ensureVisible(find.byKey(const Key('close-video-notes')));
    await tester.tap(find.byKey(const Key('close-video-notes')).hitTestable());
    await _paint(tester);
    expect(noteEntry, findsOneWidget);
    expect(playback.onlineOpens, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽窗口与真实全屏切换时在各自布局继续同一份笔记', (tester) async {
    const windowChannel = MethodChannel('window_manager');
    const experienceChannel = MethodChannel(
      'com.focubili.app/windows_experience',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final fullscreenChanges = <bool>[];
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isMaximized') return false;
      if (call.method == 'setFullScreen') {
        fullscreenChanges.add(
          (call.arguments as Map<Object?, Object?>)['isFullScreen'] as bool,
        );
      }
      return null;
    });
    messenger.setMockMethodCallHandler(experienceChannel, (_) async => true);
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(experienceChannel, null);
    });
    final playback = _PeekPlayback(startsPlaying: false);
    await _mount(
      tester,
      playback,
      VideoNoteService(),
      landscape: const Size(1024, 560),
      fullscreen: false,
      appPlatform: AppPlatform.windows,
    );
    await _open(tester, fullscreen: false);
    await tester.enterText(_bodyField, _draft);
    await tester.tap(find.byTooltip('进入全屏').hitTestable());
    await _paint(tester);
    expect(_workspacePane, findsNothing);
    expect(_inlinePanel, findsNothing);
    expect(_panel.hitTestable(), findsOneWidget);
    expect(_barrier, findsOneWidget);
    expect(_controller(tester, _bodyField).text, _draft);
    expect(tester.widget<Text>(_position).data, '视频位置：00:20');

    await tester.tapAt(_leftEdge(tester));
    await _paint(tester);
    expect(_handle.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('退出全屏').hitTestable());
    await _paint(tester);
    expect(
      find.descendant(of: _workspacePane, matching: _inlinePanel),
      findsOneWidget,
    );
    expect(_panel, findsNothing);
    expect(_handle, findsNothing);
    expect(_controller(tester, _bodyField).text, _draft);
    expect(tester.widget<Text>(_position).data, '00:20');
    expect(fullscreenChanges, [true, false]);

    // An unmaximized resize can cross the breakpoint without going portrait.
    tester.view.physicalSize = const Size(860, 520);
    await _paint(tester);
    expect(_workspacePane, findsNothing);
    expect(_panel.hitTestable(), findsOneWidget);
    await tester.tapAt(_leftEdge(tester));
    await _paint(tester);
    expect(_handle.hitTestable(), findsOneWidget);
    tester.view.physicalSize = const Size(1024, 560);
    await _paint(tester);
    expect(_panel, findsNothing);
    expect(_handle, findsNothing);
    expect(_controller(tester, _bodyField).text, _draft);

    await tester.binding.handlePopRoute();
    await _paint(tester);
    expect(_inlinePanel, findsNothing);
    expect(find.byTooltip('记笔记'), findsOneWidget);
    expect(playback.onlineOpens, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄横屏仍可用 Escape 和空格操作笔记把手，转竖屏回到原稿', (tester) async {
    final playback = _PeekPlayback(startsPlaying: false);
    final boundary = await _mount(
      tester,
      playback,
      VideoNoteService(),
      landscape: const Size(860, 520),
      fullscreen: false,
      appPlatform: AppPlatform.windows,
      scale: 1.4,
    );
    expect(_workspacePane, findsNothing);
    await _open(tester, fullscreen: false);
    await tester.enterText(_titleField, _title);
    await tester.enterText(_bodyField, _draft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _paint(tester);
    expect(_handle.hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _paint(tester);
    expect(_handle, findsNothing);
    expect(_titleField.hitTestable(), findsOneWidget);
    expect(_controller(tester, _bodyField).text, _draft);
    expect(playback.plays, 0);
    await tester.tapAt(_leftEdge(tester));
    await _paint(tester);
    await _capture(tester, boundary, '04-narrow-window-parked');
    tester.view.physicalSize = const Size(396, 700);
    await _paint(tester);
    expect(_handle, findsNothing);
    expect(find.byKey(const Key('portrait-video-notes-panel')), findsOneWidget);
    expect(_controller(tester, _bodyField).text, _draft);
    expect(tester.widget<Text>(_position).data, '00:20');
    await tester.binding.handlePopRoute();
    await _paint(tester);
    expect(find.byKey(const Key('portrait-video-notes-panel')), findsNothing);
    expect(playback.onlineOpens, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('横屏第一次点旗标仅停靠，再点可取消或切换同秒笔记并保护草稿', (tester) async {
    final playback = _PeekPlayback(startsPlaying: false);
    final service = VideoNoteService();
    final date = DateTime(2026, 11, 18);
    for (final id in ['同秒 A', '同秒 B']) {
      await service.saveNote(
        VideoNote(
          id: id,
          bvid: _video.bvid,
          videoTitle: _video.title,
          ownerName: _video.ownerName,
          partCid: _video.cid,
          partPageNumber: 1,
          partTitle: _video.parts.single.title,
          title: id,
          body: '已保存正文',
          createdAt: date,
          updatedAt: date,
          position: const Duration(seconds: 15),
        ),
      );
    }
    await _mount(tester, playback, service, landscape: const Size(860, 420));
    final flag = find.byKey(const ValueKey('player-note-flag-hit-0'));
    final chooser = find.text('选择笔记');
    await tester.tap(flag.hitTestable());
    await _paint(tester);
    await tester.tap(find.byKey(const ValueKey('choose-note-同秒 A')));
    await _paint(tester);
    await tester.enterText(_bodyField, _draft);
    final target = tester.getCenter(flag);

    await tester.tapAt(target);
    await tester.pump();
    expect(_handle.hitTestable(), findsOneWidget);
    expect(chooser, findsNothing);
    expect(playback.seeks, isEmpty);
    await tester.tap(flag.hitTestable());
    await _paint(tester);
    expect(chooser, findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await _paint(tester);
    await tester.tap(_handle.hitTestable());
    await _paint(tester);
    expect(_controller(tester, _titleField).text, '同秒 A');
    expect(_controller(tester, _bodyField).text, _draft);

    await tester.tapAt(target);
    await tester.pump();
    expect(chooser, findsNothing);
    await tester.tap(flag.hitTestable());
    await _paint(tester);
    await tester.tap(find.byKey(const ValueKey('choose-note-同秒 B')));
    await _paint(tester);
    expect(_handle, findsNothing);
    expect(_controller(tester, _titleField).text, '同秒 B');
    final notes = await service.loadNotes();
    expect(notes.singleWhere((note) => note.id == '同秒 A').body, _draft);
    expect(playback.seeks, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停靠中的待保存草稿随播放器卸载落盘', (tester) async {
    final service = VideoNoteService();
    final playback = _PeekPlayback(startsPlaying: false);
    await _mount(tester, playback, service, landscape: const Size(740, 400));
    await _open(tester);
    await tester.enterText(_titleField, _title);
    await tester.enterText(_bodyField, _draft);
    await tester.tapAt(_leftEdge(tester));
    await tester.pump();
    expect(_handle.hitTestable(), findsOneWidget);
    expect(await service.loadNotes(), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    final note = (await service.loadNotes()).single;
    expect(note.title, _title);
    expect(note.body, _draft);
    expect(note.position, _anchor);
  });

  testWidgets('全屏停靠后退出仍可继续编辑，真实返回先关笔记再退全屏', (tester) async {
    final playback = _PeekPlayback(startsPlaying: false);
    final service = VideoNoteService();
    await _mount(tester, playback, service, landscape: const Size(740, 400));
    await _open(tester);
    await tester.enterText(_titleField, _title);
    await tester.tapAt(_leftEdge(tester));
    await _paint(tester);
    await tester.tap(find.byTooltip('退出全屏'));
    await _paint(tester);
    expect(_handle.hitTestable(), findsOneWidget);
    await tester.tap(_handle);
    await _paint(tester);
    expect(_controller(tester, _titleField).text, _title);
    await tester.tapAt(_leftEdge(tester));
    await _paint(tester);
    await tester.tap(find.byTooltip('进入全屏'));
    await _paint(tester);
    await tester.binding.handlePopRoute();
    await _paint(tester);
    expect(_handle, findsNothing);
    expect(_panel, findsNothing);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _paint(tester);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
    expect((await service.loadNotes()).single.title, _title);
    expect(playback.onlineOpens, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
