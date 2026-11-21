import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/notes/video_notes_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoNetwork extends Fake implements BilibiliService {
  @override
  Future<VideoPreview> lookupVideo(String input) async =>
      throw StateError('offline');
}

const _firstTitle = '复习递归时怎样识别真正的终止条件';
const _query = 'Stop[0]';
const _secondTitle = '另一节课的笔记';
final _field = find.byKey(const Key('video-notes-search-field'));
final _export = find.byKey(const Key('save-selected-video-notes'));
Finder _tile(String id) => find.byKey(Key('managed-video-note-$id'));

VideoNote _note(int index, String title, String body) => VideoNote(
  id: 'review-$index',
  bvid: 'BV1GJ411x7h7',
  videoTitle: '第 $index 课 · 数据结构',
  ownerName: '示例讲师',
  partCid: 100,
  partPageNumber: 1,
  partTitle: '例题',
  title: title,
  body: body,
  createdAt: DateTime(2026, 11, 19 - index, 10),
  updatedAt: DateTime(2026, 11, 19 - index, 10),
  position: Duration(minutes: index, seconds: 21),
);

Future<void> _open(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  LocalExportService localExport = const LocalExportService(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final service = VideoNoteService();
  await service.saveNote(
    _note(1, _firstTitle, '${'开头的引言。' * 18}递归返回条件是 $_query，别把方括号当成正则。'),
  );
  await service.saveNote(_note(2, _secondTitle, '列表滚动时注意项目之间的间距。'));
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => VideoNotesPage(
                  noteService: service,
                  videoService: _NoNetwork(),
                  localExportService: localExport,
                ),
              ),
            ),
            child: const Text('打开笔记'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开笔记'));
  await tester.pumpAndSettle();
}

void main() {
  for (final variant in [
    (const Size(320, 480), 2.4, Brightness.dark),
    (const Size(390, 844), 1.0, Brightness.light),
    (const Size(800, 640), 1.8, Brightness.light),
    (const Size(1280, 760), 1.0, Brightness.dark),
  ]) {
    testWidgets('正文命中在可见节录中，时间点不重叠：${variant.$1} / ${variant.$2}', (
      tester,
    ) async {
      await _open(
        tester,
        size: variant.$1,
        scale: variant.$2,
        brightness: variant.$3,
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(_field, _query.toLowerCase());
      await tester.pumpAndSettle();
      final card = _tile('review-1');
      expect(_tile('review-2'), findsNothing);
      final excerpt = find.descendant(
        of: card,
        matching: find.textContaining(_query, findRichText: true),
      );
      expect(excerpt, findsOneWidget);
      final shown = tester.widget<RichText>(excerpt).text.toPlainText();
      expect(shown, isNot(contains('开头的引言')));
      final time = find.descendant(of: card, matching: find.text('01:21'));
      expect(
        tester.getRect(time).top,
        greaterThan(tester.getRect(excerpt).bottom),
      );
      expect(
        tester.getRect(find.text(_firstTitle)).right,
        lessThanOrEqualTo(tester.getRect(find.byTooltip('笔记操作')).left),
      );
      await tester.tap(find.byKey(const Key('clear-video-notes-search')));
      await tester.pumpAndSettle();
      expect(find.text('共 2 条笔记'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('收窄筛选只导出可见勾选项；取消另存后保留当前选择', (tester) async {
    List<Object?>? notes;
    await _open(
      tester,
      localExport: LocalExportService(
        platform: AppPlatform.macos,
        saveDialog: (request) async {
          final Map<String, dynamic> json = jsonDecode(
            utf8.decode(request.bytes),
          );
          notes = json['notes'] as List<Object?>;
          return null;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('select-video-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pump();
    expect(find.text('已选择 2 条'), findsOneWidget);
    expect(
      tester.getSemantics(_tile('review-1')),
      isSemantics(hasCheckedState: true, isChecked: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(_tile('review-1')).getSemanticsData().label,
      contains(_firstTitle),
    );
    await tester.enterText(_field, _query);
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 条'), findsOneWidget);
    await tester.tap(_export);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出为 JSON'));
    await tester.pumpAndSettle();
    expect(notes?.length, 1);
    expect((notes!.single as Map)['id'], 'review-1');
    expect(find.text('已选择 1 条'), findsOneWidget);
    await tester.enterText(_field, '不存在的内容');
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(_export).onPressed, isNull);
    await tester.tap(find.byKey(const Key('clear-video-notes-search')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统返回及 Escape 先退出选择，再返回上页', (tester) async {
    await _open(tester, size: const Size(1100, 740));
    await tester.enterText(_field, _query);
    await tester.pumpAndSettle();
    for (final keyboard in [false, true]) {
      await tester.longPress(_tile('review-1'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 条'), findsOneWidget);
      if (keyboard) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.text('找到 1 条笔记'), findsOneWidget);
      expect(_export, findsNothing);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开笔记'), findsOneWidget);
  });

  testWidgets('窄屏 240% 与模拟键盘下，无结果可恢复、最后一个格式可实际点选', (tester) async {
    String? filename;
    await _open(
      tester,
      size: const Size(320, 480),
      scale: 2.4,
      brightness: Brightness.dark,
      localExport: LocalExportService(
        platform: AppPlatform.macos,
        saveDialog: (request) async {
          filename = request.fileName;
          return null;
        },
      ),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 190);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(_field, '没有命中');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的笔记'), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-video-notes-search')));
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.tap(find.byKey(const Key('select-video-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pump();
    await tester.tap(_export);
    await tester.pumpAndSettle();
    final format = find.text('导出为 JSON');
    await tester.ensureVisible(format);
    await tester.pumpAndSettle();
    expect(format.hitTestable(), findsOneWidget);
    await tester.tap(format);
    await tester.pumpAndSettle();
    expect(filename, endsWith('.json'));
    expect(tester.takeException(), isNull);
  });
}
