import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/services/video_note_service.dart';

const _evidence = bool.fromEnvironment('UPDATE_NOTES_PREVIEW_EVIDENCE');

Future<void> _waitForFrameSave(WidgetTester tester, Finder status) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (status.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(status, findsOneWidget);
}

VideoNote _screenshotNote({
  String? framePath,
  List<VideoNoteFrame> frames = const [],
}) {
  final time = DateTime(2026, 10, 18);
  return VideoNote(
    id: 'frame-save',
    bvid: 'BV1GJ411x7h7',
    videoTitle: '截图测试视频',
    ownerName: '测试资料',
    partCid: 1,
    partPageNumber: 1,
    partTitle: '第一节',
    title: '原始标题',
    body: '原始正文',
    createdAt: time,
    updatedAt: time,
    position: const Duration(seconds: 20),
    framePath: framePath,
    frames: frames,
  );
}

Future<List<VideoNoteFrame>> _realFrames(WidgetTester tester) async {
  late Directory directory;
  final paths = <String>[];
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('focubili-note-preview-');
    for (final size in [const Size(90, 160), const Size(160, 90)]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var band = 0; band < 3; band++) {
        canvas.drawRect(
          Rect.fromLTWH(0, size.height * band / 3, size.width, size.height / 3),
          Paint()
            ..color = const [
              Color(0xffc46b51),
              Color(0xfff6edd5),
              Color(0xff358c81),
            ][band],
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${directory.path}/${paths.length}.png');
      await file.writeAsBytes(png!.buffer.asUint8List());
      paths.add(file.path);
      image.dispose();
      picture.dispose();
    }
    for (final path in paths) {
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final ready = Completer<void>();
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
    }
  });
  addTearDown(() async {
    for (final path in paths) {
      await FileImage(File(path)).evict();
    }
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}focubili-note-preview-';
    expect(directory.absolute.path.startsWith(prefix), isTrue);
    await tester.runAsync(() => directory.delete(recursive: true));
  });
  return [
    VideoNoteFrame(
      path: paths[0],
      position: const Duration(milliseconds: 42125),
    ),
    VideoNoteFrame(
      path: paths[1],
      position: const Duration(milliseconds: 3500),
    ),
  ];
}

void _expectWholeImage(
  WidgetTester tester,
  Finder finder,
  Size expected,
  double maxHeight,
) {
  final image = tester.widget<Image>(finder);
  expect(image.fit, BoxFit.contain);
  final render = tester.renderObject<RenderImage>(
    find.descendant(of: finder, matching: find.byType(RawImage)),
  );
  expect(render.image, isNotNull);
  final source = Size(
    render.image!.width.toDouble(),
    render.image!.height.toDouble(),
  );
  expect(source, expected);
  expect(applyBoxFit(image.fit!, source, render.size).source, source);
  expect(render.size.height, lessThanOrEqualTo(maxHeight + .01));
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_evidence) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = await Directory(
      'docs/v1.9/evidence',
    ).create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (!_evidence) return;
    for (final font in {
      'NotesPreview': 'C:/Windows/Fonts/msyh.ttc',
      'MaterialIcons':
          'C:/Users/L1XU4N/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(font.value);
      if (await file.exists()) {
        await (FontLoader(
          font.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  for (final size in [
    const Size(320, 240),
    const Size(420, 1000),
    const Size(1000, 700),
  ]) {
    testWidgets('旧单帧和混合横竖多帧在 $size 完整显示且重排保留时间', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final original = await _realFrames(tester);
      var frames = original;
      final title = TextEditingController(text: '横竖画面 · 同一条笔记');
      final body = TextEditingController(text: '完整显示每张画面，顺序与各自的时间点一起保留。');
      addTearDown(title.dispose);
      addTearDown(body.dispose);
      final boundary = GlobalKey();
      final maxHeight = (size.height * .38).clamp(108, 280).toDouble();

      Widget host({required bool legacy}) => MaterialApp(
        theme: ThemeData(fontFamily: _evidence ? 'NotesPreview' : null),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: StatefulBuilder(
                    builder: (context, setState) => VideoNoteComposer(
                      titleController: title,
                      bodyController: body,
                      position: const Duration(seconds: 20),
                      partPageNumber: 1,
                      includeFrame: true,
                      saving: false,
                      compact: true,
                      borderless: true,
                      framePath: legacy ? original.first.path : null,
                      frames: legacy ? const [] : frames,
                      onFramesChanged: (next) => setState(() => frames = next),
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

      await tester.pumpWidget(host(legacy: true));
      await tester.pump(const Duration(milliseconds: 300));
      _expectWholeImage(
        tester,
        find.byKey(const Key('note-frame-preview')),
        const Size(90, 160),
        maxHeight,
      );
      await tester.pumpWidget(host(legacy: false));
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 2; i++) {
        _expectWholeImage(
          tester,
          find.descendant(
            of: find.byKey(ValueKey('note-frame-$i')),
            matching: find.byType(Image),
          ),
          i == 0 ? const Size(90, 160) : const Size(160, 90),
          maxHeight,
        );
      }
      expect(find.text('画面 1 · 00:42.125'), findsOneWidget);
      expect(find.text('画面 2 · 00:03.500'), findsOneWidget);
      if (size.height > 600) {
        await _capture(
          tester,
          boundary,
          'notes-mixed-${size.width.toInt()}x${size.height.toInt()}',
        );
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('move-note-frame-up-1')),
      );
      await tester.tap(find.byKey(const ValueKey('move-note-frame-up-1')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(frames, original.reversed.toList());
      expect(find.text('画面 1 · 00:03.500'), findsOneWidget);
      expect(find.text('画面 2 · 00:42.125'), findsOneWidget);
      expect(find.text('视频位置：00:20'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('混合横竖详情重排保存后逐张查看原图，笔记锚点不变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final frames = await _realFrames(tester);
    final now = DateTime(2026, 10, 18);
    final note = VideoNote(
      id: 'mixed-preview',
      bvid: 'BV1GJ411x7h7',
      videoTitle: '合成比例检查',
      ownerName: '合成资料',
      partCid: 1,
      partPageNumber: 1,
      partTitle: '第一节',
      title: '横竖混合',
      body: '非真实视频',
      createdAt: now,
      updatedAt: now,
      position: const Duration(seconds: 20),
      frames: frames,
    );
    final service = VideoNoteService();
    await service.saveNote(note);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNoteDetailPage(note: note, noteService: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('move-note-frame-up-1')),
    );
    await tester.tap(find.byKey(const ValueKey('move-note-frame-up-1')));
    await tester.pumpAndSettle();
    tester
        .widget<FilledButton>(find.byKey(const Key('save-note-detail')))
        .onPressed!();
    await tester.pumpAndSettle();
    final saved = (await service.loadNotes()).single;
    expect(saved.allFrames, frames.reversed.toList());
    expect(saved.position, const Duration(seconds: 20));
    for (var i = 0; i < saved.allFrames.length; i++) {
      final key = i == 0
          ? const Key('open-note-frame-fullscreen')
          : ValueKey('open-note-frame-$i');
      final image = find.descendant(
        of: find.byKey(key),
        matching: find.byType(Image),
      );
      _expectWholeImage(
        tester,
        image,
        i == 0 ? const Size(160, 90) : const Size(90, 160),
        240,
      );
      tester.widget<InkWell>(find.byKey(key)).onTap!();
      await tester.pumpAndSettle();
      final viewer = tester.widget<PhotoView>(
        find.byKey(const Key('fullscreen-note-frame-viewer')),
      );
      expect(
        (viewer.imageProvider! as FileImage).file.path,
        saved.allFrames[i].path,
      );
      expect(viewer.initialScale, PhotoViewComputedScale.contained);
      expect(viewer.basePosition, Alignment.center);
      await tester.tap(find.byKey(const Key('close-fullscreen-note-frame')));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按旧笔记原图可以取消，仍可打开全屏并保存原始字节', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final frames = await _realFrames(tester);
    final source = File(frames.first.path);
    final bytes = source.readAsBytesSync();
    final output = File('${source.parent.path}/exported screenshot.png');
    final note = _screenshotNote(framePath: source.path);
    final service = VideoNoteService();
    await service.saveNote(note);
    final requests = <LocalExportRequest>[];
    final exportService = LocalExportService(
      platform: AppPlatform.windows,
      saveDialog: (request) async {
        requests.add(request);
        if (requests.length == 1) return null;
        await output.writeAsBytes(request.bytes);
        return output.path;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNoteDetailPage(
          note: note,
          noteService: service,
          localExportService: exportService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final thumbnail = find.byKey(const Key('open-note-frame-fullscreen'));
    await tester.ensureVisible(thumbnail);
    await tester.pumpAndSettle();
    await tester.longPress(thumbnail);
    await _waitForFrameSave(tester, find.text('已取消保存截图。'));
    expect(find.byType(VideoNoteFrameViewerPage), findsNothing);
    expect(output.existsSync(), isFalse);

    await tester.tap(thumbnail);
    await tester.pumpAndSettle();
    final viewer = find.byKey(const Key('fullscreen-note-frame-viewer'));
    expect(viewer, findsOneWidget);
    final zoomController = tester.widget<PhotoView>(viewer).controller!;
    final initialScale = zoomController.scale!;
    await tester.tap(viewer);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(viewer);
    await tester.pumpAndSettle();
    expect(zoomController.scale, greaterThan(initialScale));
    await tester.longPress(viewer);
    await _waitForFrameSave(tester, find.text('截图已保存。'));
    expect(requests.length, 2);
    for (final request in requests) {
      expect(request.extension, 'png');
      expect(request.dialogTitle, '保存截图到本地');
      expect(request.bytes, bytes);
    }
    expect(output.readAsBytesSync(), bytes);
    expect(source.readAsBytesSync(), bytes);
    final saved = (await service.loadNotes()).single;
    expect(saved.body, note.body);
    expect(saved.allFrames, note.allFrames);
  });

  testWidgets('多帧另存为保留截图顺序并提示写入失败或缺图', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final frames = await _realFrames(tester);
    final first = File(frames.first.path);
    final second = File(frames.last.path);
    final requests = <LocalExportRequest>[];
    final exportService = LocalExportService(
      platform: AppPlatform.android,
      saveDialog: (request) async {
        requests.add(request);
        throw PlatformException(
          code: 'permission_denied',
          message: second.path,
        );
      },
    );
    final note = _screenshotNote(frames: frames);
    final service = VideoNoteService();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNoteDetailPage(
          note: note,
          noteService: service,
          localExportService: exportService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final saveSecond = find.byKey(const ValueKey('save-note-frame-1'));
    await tester.ensureVisible(saveSecond);
    await tester.pumpAndSettle();
    await tester.tap(saveSecond);
    await _waitForFrameSave(
      tester,
      find.textContaining('android/save/permission_denied'),
    );
    expect(find.textContaining(second.path), findsNothing);
    expect(requests.single.bytes, second.readAsBytesSync());

    first.deleteSync();
    final saveFirst = find.byKey(const ValueKey('save-note-frame-0'));
    await tester.ensureVisible(saveFirst);
    await tester.pumpAndSettle();
    await tester.tap(saveFirst);
    await _waitForFrameSave(tester, find.text('截图文件缺失或无法读取。'));
    expect(requests.length, 1);
  });
}
