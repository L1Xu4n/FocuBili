import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/notes/video_note_share_preview.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:share_plus/share_plus.dart';
import 'package:focubili/services/video_note_share_service.dart';
import 'package:flutter/services.dart';
import 'package:focubili/services/windows_experience_service.dart';

class _CaptureShareBoundary extends VideoNoteShareService {
  GlobalKey? boundary;

  @override
  Future<void> shareBoundary({
    required GlobalKey boundaryKey,
    required String fileName,
    required String text,
    Rect? sharePositionOrigin,
  }) async {
    boundary = boundaryKey;
  }
}

VideoNote exampleNote({String? framePath, bool long = false}) => VideoNote(
  id: 'example',
  bvid: 'BV1GJ411x7h7',
  videoTitle: '高等数学：导数与切线',
  ownerName: '示例课程',
  partCid: 12,
  partPageNumber: 2,
  partTitle: '导数的几何意义',
  title: '为什么导数等于切线斜率？',
  body: long
      ? List.filled(40, '当另一个点逐渐靠近时，割线的斜率趋近于切线的斜率。').join('\n')
      : '先在曲线上取两点，连接成一条割线。让第二个点沿着曲线靠近第一个点，割线的斜率就越来越接近切线斜率。\n\n算题时别忘了：这个极限存在，才谈得上该点的导数。',
  createdAt: DateTime(2026, 11, 19, 21, 8),
  updatedAt: DateTime(2026, 11, 19, 21, 8),
  position: const Duration(minutes: 12, seconds: 38),
  frames: framePath == null
      ? const []
      : [
          VideoNoteFrame(
            path: framePath,
            position: const Duration(minutes: 12, seconds: 38),
          ),
          const VideoNoteFrame(
            path: '/missing-note-screen.png',
            position: Duration(minutes: 15, seconds: 12),
          ),
        ],
);

Future<void> showPreview(
  WidgetTester tester,
  VideoNote note, {
  VideoNoteShareService service = const VideoNoteShareService(),
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => unawaited(
                showVideoNoteSharePreview(context, note, shareService: service),
              ),
              child: const Text('打开分享'),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开分享'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('黑暗主题窄屏保留纸页原色、完整字句和可滚动画面', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = exampleNote(
      framePath: File('assets/icon/focubili_icon.png').absolute.path,
      long: true,
    );
    await tester.runAsync(() async {
      await showPreview(tester, note, brightness: Brightness.dark);
      // Let FileImage's asynchronous filesystem probe report the missing frame.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<VideoNoteShareCard>(find.byType(VideoNoteShareCard)).style,
      VideoNoteShareStyle.paper,
    );
    expect(
      tester
          .widget<Container>(find.byKey(const Key('video-note-share-card')))
          .color,
      const Color(0xFFFFFEFA),
    );
    final body = tester.widget<Text>(find.text(note.body, skipOffstage: false));
    expect(body.maxLines, isNull);
    expect(find.text('12:38'), findsNWidgets(2));
    expect(find.text('画面 2', skipOffstage: false), findsOneWidget);
    expect(find.text('15:12', skipOffstage: false), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(500));
    scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('截图无法读取'), findsOneWidget);
    expect(
      find.byKey(const Key('share-video-note-card')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏切换至经典后导出的 PNG 仅包含所选卡片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(650, 340));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _CaptureShareBoundary();
    await showPreview(tester, exampleNote(long: true), service: service);
    await tester.tap(find.byKey(const Key('video-note-share-style-classic')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<VideoNoteShareCard>(find.byType(VideoNoteShareCard)).style,
      VideoNoteShareStyle.classic,
    );
    final button = find.byKey(const Key('share-video-note-card'));
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(service.boundary, isNotNull);
    expect(
      find.descendant(
        of: find.byKey(service.boundary!),
        matching: find.byType(ChoiceChip),
      ),
      findsNothing,
    );
    final boundary =
        service.boundary!.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final pixels = await tester.runAsync(() async {
      final rendered = await boundary.toImage();
      try {
        final bytes = (await rendered.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        return (width: rendered.width, height: rendered.height, rgba: bytes);
      } finally {
        rendered.dispose();
      }
    });
    expect(pixels!.width, 420);
    expect(pixels.height, greaterThan(550));
    expect(pixels.rgba[0], lessThan(80));
    expect(pixels.rgba[2], greaterThan(pixels.rgba[0]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('纸页按笔记、画面、出处排序，导出与屏幕上的卡片像素一致', (tester) async {
    final note = exampleNote().copyWith(
      title: '导数 / derivative',
      body: 'x → 0 时，比较两点的斜率。',
    );
    final folder = Directory.systemTemp.createTempSync('approved-paper-share-');
    addTearDown(() => folder.deleteSync(recursive: true));
    String? exported;
    final service = VideoNoteShareService(
      platform: AppPlatform.android,
      temporaryDirectoryLoader: () async => folder,
      shareLauncher: (params) async {
        exported = params.files!.single.path;
        return const ShareResult('mock', ShareResultStatus.success);
      },
    );
    await showPreview(tester, note, service: service);
    await tester.tap(find.byKey(const Key('video-note-share-style-classic')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-note-share-style-paper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-note-share-frame')), findsNothing);
    expect(
      tester.getTopLeft(find.text(note.title)).dy,
      lessThan(tester.getTopLeft(find.text(note.body)).dy),
    );
    expect(
      tester.getTopLeft(find.text(note.body)).dy,
      lessThan(tester.getTopLeft(find.text(note.videoTitle)).dy),
    );
    for (final toolbar in ['笔记分享预览', '经典', '纸页', '分享图片']) {
      expect(
        find.descendant(
          of: find.byKey(const Key('video-note-share-card')),
          matching: find.text(toolbar),
        ),
        findsNothing,
      );
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(
            of: find.byKey(const Key('video-note-share-card')),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    late Uint8List expected;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      try {
        expected = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    });
    await tester.tap(find.byKey(const Key('share-video-note-card')));
    // Pump Flutter callbacks while the real renderer and local PNG writer work.
    final deadline = Stopwatch()..start();
    while (exported == null && deadline.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
    }
    expect(exported, isNotNull);
    expect(File(exported!).readAsBytesSync(), orderedEquals(expected));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoNoteShareCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('桌面复制纸页 PNG 和像素，不调用系统分享', (tester) async {
    const channel = MethodChannel('test/paper-clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      copied = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = VideoNoteShareService(
      platform: AppPlatform.linux,
      windowsExperience: const WindowsExperienceService(channel: channel),
      shareLauncher: (_) => throw StateError('Unexpected share'),
    );
    await showPreview(tester, exampleNote(), service: service);
    await tester.tap(find.text('复制图片'));
    final deadline = Stopwatch()..start();
    while (copied == null && deadline.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
    }
    expect(copied?.method, 'copyImage');
    final args = copied!.arguments as Map;
    expect(args['width'], 1170);
    expect((args['png'] as Uint8List).take(8), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);
    expect(
      (args['rgba'] as Uint8List).length,
      (args['width'] as int) * (args['height'] as int) * 4,
    );
    await tester.pumpAndSettle();
    expect(find.text('图片已复制到剪贴板'), findsOneWidget);
  });
}
