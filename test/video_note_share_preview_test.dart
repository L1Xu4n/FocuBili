import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/notes/video_note_share_preview.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/video_note_share_service.dart';

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
      const Color(0xFFF8FAFE),
    );
    final body = tester.widget<Text>(find.text(note.body, skipOffstage: false));
    expect(body.maxLines, isNull);
    expect(find.text('12:38'), findsOneWidget);
    expect(find.text('画面 2 · 15:12', skipOffstage: false), findsOneWidget);
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
}
