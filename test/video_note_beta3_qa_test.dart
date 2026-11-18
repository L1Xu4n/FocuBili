import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/video_note_service.dart';

const _evidencePath = String.fromEnvironment('FOCUBILI_NOTES_QA_EVIDENCE');
const _body = '''# 期末复习

这是 **重点**。以下是复盘记录：

- 第一项：回顾定理
- 第二项：重做例题

> 画出图形再计算。

| 科目 | 概念 | 复习 | 例题 | 时间 | 页码 | 结果 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 交并补 | 待复习 | 第 3 题 | 周三晚 | 第 7 页 | 需要复查 |

最后检查结果。''';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_evidencePath.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = await Directory(_evidencePath).create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(
      bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_evidencePath.isEmpty) return;
    const cjkFontPath = String.fromEnvironment(
      'FOCUBILI_NOTES_QA_CJK_FONT',
      defaultValue: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    const iconsFontPath = String.fromEnvironment(
      'FOCUBILI_NOTES_QA_ICONS_FONT',
    );
    const iconsPath = 'material_fonts/MaterialIcons-Regular.otf';
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final iconsFont = iconsFontPath.isNotEmpty
        ? File(iconsFontPath)
        : flutterRoot != null
        ? File('$flutterRoot/bin/cache/artifacts/$iconsPath')
        : File.fromUri(
            File(
              Platform.resolvedExecutable,
            ).absolute.uri.resolve('../../$iconsPath'),
          );
    for (final font in {
      'NotesEvidenceCJK': File(cjkFontPath),
      'MaterialIcons': iconsFont,
    }.entries) {
      await (FontLoader(
        font.key,
      )..addFont(font.value.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  testWidgets('窄屏笔记预览可回到编辑，修改和旧笔记位置均保留', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final note = VideoNote(
      id: 'qa-markdown-note',
      bvid: 'BV1GJ411x7h7',
      videoTitle: '集合基础课',
      ownerName: '合成示例',
      partCid: 123,
      partPageNumber: 1,
      partTitle: '交并补',
      title: '课堂笔记',
      body: _body,
      createdAt: DateTime(2026, 11, 17, 8),
      updatedAt: DateTime(2026, 11, 17, 8),
      position: const Duration(minutes: 12, seconds: 34),
    );
    final service = VideoNoteService();
    await service.saveNote(note);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xff9180db),
            fontFamily: _evidencePath.isEmpty ? null : 'NotesEvidenceCJK',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: VideoNoteDetailPage(note: note, noteService: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.widgetWithText(TextButton, 'Markdown 预览');
    final edit = find.widgetWithText(TextButton, '编辑正文');
    final field = find.byKey(const Key('note-detail-body-field'));
    final markdown = find.byType(MarkdownBody);
    final bodyScroll = find.byKey(const Key('video-note-detail-scroll-view'));
    expect(tester.widget<TextField>(field).controller!.text, _body);
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(tester.widget<MarkdownBody>(markdown).data, _body);
    expect(find.text('期末复习', findRichText: true), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    final top = find.text('期末复习', findRichText: true);
    await tester.ensureVisible(top);
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'markdown-detail-320');
    final table = find.byType(Table);
    await tester.ensureVisible(table);
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'markdown-table-320');
    await tester.drag(bodyScroll, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(
      find.text('最后检查结果。', findRichText: true).hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, _body);

    const next = '$_body\n\n**补充：** 对照课本。';
    await tester.enterText(field, next);
    await tester.pumpAndSettle();
    await tester.ensureVisible(preview);
    await tester.pumpAndSettle();
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(tester.widget<MarkdownBody>(markdown).data, next);
    expect((await service.loadNotes()).single.body, _body);
    await tester.tap(find.byKey(const Key('save-note-detail')));
    await tester.pumpAndSettle();
    final saved = (await service.loadNotes()).single;
    expect(saved.body, next);
    expect(saved.position, note.position);
    expect(tester.takeException(), isNull);

    // A seven-column table must expose a horizontal viewport, not compress
    // enlarged text until it is unreadable inside the column borders.
    await tester.ensureVisible(table);
    await tester.pumpAndSettle();
    final tableViewport = find
        .ancestor(of: table, matching: find.byType(Scrollable))
        .evaluate()
        .where(
          (element) =>
              axisDirectionToAxis(
                (element.widget as Scrollable).axisDirection,
              ) ==
              Axis.horizontal,
        );
    expect(tableViewport, hasLength(1));
    final scroll =
        (tableViewport.single as StatefulElement).state as ScrollableState;
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    final dragTarget = tester
        .getRect(table)
        .intersect(const Rect.fromLTWH(20, 56, 280, 584))
        .center;
    for (int i = 0; i < 5 && scroll.position.extentAfter > 1; i++) {
      await tester.dragFrom(dragTarget, const Offset(-235, 0));
      await tester.pumpAndSettle();
    }
    expect(scroll.position.extentAfter, lessThanOrEqualTo(1));
    expect(find.text('需要复查', findRichText: true).hitTestable(), findsOneWidget);
    await _capture(tester, boundary, 'markdown-table-scrolled-320');
  });
}
