import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/features/notes/video_note_share_preview.dart';
import 'package:focubili/features/notes/video_note_frames_view.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const track = SubtitleTrack(
  id: 'zh',
  language: 'zh-CN',
  label: '简体中文',
  isLocked: false,
);
const tracks = SubtitleTrackLoadResult(
  status: SubtitleLoadStatus.available,
  message: '',
  tracks: [track],
);
const cues = SubtitleCueLoadResult(
  status: SubtitleLoadStatus.available,
  message: '',
  cues: [
    SubtitleCue(
      from: Duration(milliseconds: 1250),
      to: Duration(seconds: 3),
      content: 'Alpha 已有字幕',
    ),
    SubtitleCue(
      from: Duration(seconds: 8),
      to: Duration(milliseconds: 9500),
      content: 'Beta 时间轴',
    ),
  ],
);

const updateEvidence = bool.fromEnvironment('UPDATE_V19_EVIDENCE');
final evidenceBoundary = GlobalKey();

Future<void> screenshot(WidgetTester tester, String name) async {
  if (!updateEvidence) return;
  await tester.runAsync(() async {
    final boundary =
        evidenceBoundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
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

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(fontFamily: updateEvidence ? 'EvidenceFont' : null),
  home: Scaffold(
    body: RepaintBoundary(
      key: evidenceBoundary,
      child: Material(color: Colors.white, child: child),
    ),
  ),
);

void main() {
  setUpAll(() async {
    if (updateEvidence) {
      final icons = File(
        'C:/Users/L1XU4N/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('EvidenceFont')
          ..addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'subtitle browser searches, seeks and exports the full existing timeline',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Duration? seek;
      LocalExportRequest? exported;
      await tester.pumpWidget(
        host(
          PlayerSubtitleSheet(
            videoLabel: 'P1 · 公开字幕演示',
            offValue: 'off',
            fontSize: 16,
            initialResult: tracks,
            isCurrentVideo: () => true,
            reloadTracks: () async => tracks,
            onPreviewFontSize: (_) {},
            onCommitFontSize: (value) async => value,
            loadCues: (_) async => cues,
            onSeek: (position) async => seek = position,
            exportService: LocalExportService(
              platform: AppPlatform.android,
              saveDialog: (request) async {
                exported = request;
                return 'content://test/export';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-subtitle-zh')));
      await tester.pumpAndSettle();
      expect(find.text('Alpha 已有字幕'), findsOneWidget);
      expect(find.text('Beta 时间轴'), findsOneWidget);
      await screenshot(tester, 'subtitle-list');
      await tester.enterText(find.byKey(const Key('subtitle-search')), 'alpha');
      tester.view.viewInsets = FakeViewPadding(
        bottom: 400 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('subtitle-cue-list'))).bottom,
        lessThanOrEqualTo(500),
      );
      expect(find.text('Beta 时间轴'), findsNothing);
      await tester.tap(find.text('Alpha 已有字幕'));
      await tester.pumpAndSettle();
      expect(seek, const Duration(milliseconds: 1250));
      await tester.tap(find.byKey(const Key('export-subtitle-timeline')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出 SRT'));
      await tester.pumpAndSettle();
      expect(exported!.extension, 'srt');
      expect(
        utf8.decode(exported!.bytes),
        contains('00:00:08,000 --> 00:00:09,500\nBeta 时间轴'),
      );
      expect(find.textContaining('已导出 2 条字幕'), findsOneWidget);
    },
  );

  testWidgets(
    'late subtitle result after a video change cannot display or export old cues',
    (tester) async {
      final pending = Completer<SubtitleCueLoadResult>();
      var current = true;
      await tester.pumpWidget(
        host(
          PlayerSubtitleSheet(
            videoLabel: 'P1',
            offValue: 'off',
            fontSize: 16,
            initialResult: tracks,
            isCurrentVideo: () => current,
            reloadTracks: () async => tracks,
            onPreviewFontSize: (_) {},
            onCommitFontSize: (value) async => value,
            loadCues: (_) => pending.future,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-subtitle-zh')));
      await tester.pump();
      current = false;
      pending.complete(cues);
      await tester.pumpAndSettle();
      expect(find.text('视频已切换，请重新打开字幕设置。'), findsOneWidget);
      expect(find.text('Alpha 已有字幕'), findsNothing);
      expect(
        tester
            .widget<PopupMenuButton>(
              find.byKey(const Key('export-subtitle-timeline')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'unavailable subtitle result can retry without synthesizing text',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          PlayerSubtitleSheet(
            videoLabel: 'P1',
            offValue: 'off',
            fontSize: 16,
            initialResult: tracks,
            isCurrentVideo: () => true,
            reloadTracks: () async => tracks,
            onPreviewFontSize: (_) {},
            onCommitFontSize: (value) async => value,
            loadCues: (_) async =>
                ++calls == 1 ? const SubtitleCueLoadResult.unavailable() : cues,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-subtitle-zh')));
      await tester.pumpAndSettle();
      expect(find.text('字幕暂时无法读取，请稍后重试。'), findsOneWidget);
      expect(find.text('Alpha 已有字幕'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha 已有字幕'), findsOneWidget);
      expect(calls, 2);
    },
  );

  testWidgets(
    'detail reorders and removes frames then saves independent timestamps',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final path = File('assets/icon/focubili_icon.png').absolute.path;
      final note = VideoNote(
        id: 'multi',
        bvid: 'BV1GJ411x7h7',
        videoTitle: '多画面笔记演示',
        ownerName: '演示',
        partCid: 1,
        partPageNumber: 1,
        partTitle: '第一节',
        title: '同一条笔记的多个画面',
        body: '顺序、时间点随编辑保留。',
        createdAt: DateTime(2026, 10, 17),
        updatedAt: DateTime(2026, 10, 17),
        position: const Duration(seconds: 10),
        frames: [
          VideoNoteFrame(
            path: path,
            position: const Duration(milliseconds: 10025),
          ),
          VideoNoteFrame(path: path, position: const Duration(seconds: 42)),
        ],
      );
      final service = VideoNoteService();
      await service.saveNote(note);
      if (updateEvidence) {
        await tester.pumpWidget(host(const SizedBox(width: 600, height: 900)));
        await tester.runAsync(
          () => precacheImage(
            FileImage(File(path)),
            evidenceBoundary.currentContext!,
          ).timeout(const Duration(seconds: 10)),
        );
      }
      await tester.pumpWidget(
        host(VideoNoteDetailPage(note: note, noteService: service)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('move-note-frame-up-1')),
      );
      await tester.tap(find.byKey(const ValueKey('move-note-frame-up-1')));
      await tester.pumpAndSettle();
      // 保存按钮固定在页面顶栏；直接调用允许在窄屏滚动后仍核验同一保存动作。
      tester
          .widget<FilledButton>(find.byKey(const Key('save-note-detail')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(
        (await service.loadNotes()).single.allFrames.map(
          (frame) => frame.position,
        ),
        [const Duration(seconds: 42), const Duration(milliseconds: 10025)],
      );
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: VideoNoteShareCard(note: (await service.loadNotes()).single),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('画面 1 · 00:42'), findsOneWidget);
      expect(find.text('画面 2 · 00:10.025'), findsOneWidget);
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(note.title, style: const TextStyle(fontSize: 24)),
                  const Text('笔记时间点 00:10 · 可调整每张画面的顺序'),
                  VideoNoteFramesView(
                    frames: (await service.loadNotes()).single.allFrames,
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await screenshot(tester, 'multi-frame-note');
      final saved = (await service.loadNotes()).single;
      await tester.pumpWidget(
        host(VideoNoteDetailPage(note: saved, noteService: service)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('remove-note-frame-1')),
      );
      await tester.tap(find.byKey(const ValueKey('remove-note-frame-1')));
      await tester.pumpAndSettle();
      tester
          .widget<FilledButton>(find.byKey(const Key('save-note-detail')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect((await service.loadNotes()).single.allFrames, [
        saved.allFrames.first,
      ]);
    },
  );
}
