import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/services/app_behavior_preferences_service.dart';

/// 验证时间点笔记底部操作在宽屏和窄屏都保持稳定的右对齐布局。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('播放器笔记默认纯文本，启用预览与关闭后均保留草稿', (tester) async {
    await tester.binding.setSurfaceSize(const Size(340, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final titleController = TextEditingController();
    final bodyController = TextEditingController();
    addTearDown(titleController.dispose);
    addTearDown(bodyController.dispose);
    final List<String> changes = <String>[];
    const String source =
        '# 复习\n\n第一步\n第二步\n\n![附图](file:///note.png)\n\n'
        '[继续阅读](https://example.org/notes)';
    final bodyField = find.byKey(const Key('note-body-field'));
    final preview = find.text('Markdown 预览');
    final edit = find.text('编辑正文');
    final preferences = AppBehaviorPreferencesService();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: VideoNoteComposer(
              titleController: titleController,
              bodyController: bodyController,
              position: const Duration(seconds: 3),
              includeFrame: false,
              saving: false,
              onIncludeFrameChanged: (_) {},
              onSave: () {},
              onNew: () {},
              onClose: () {},
              onBodyChanged: changes.add,
              compact: true,
              borderless: true,
            ),
          ),
        ),
      ),
    );

    await tester.enterText(bodyField, source);
    expect(preview, findsNothing);
    expect(edit, findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.widget<TextField>(bodyField).controller!.text, source);

    expect(await preferences.saveNoteMarkdownEnabled(true), isTrue);
    await tester.pumpAndSettle();
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(bodyField, findsNothing);
    expect(find.text('复习', findRichText: true), findsOneWidget);
    expect(find.text('第一步\n第二步', findRichText: true), findsOneWidget);
    expect(find.text('［图片：附图］', findRichText: true), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    final link = find.text('继续阅读', findRichText: true);
    await tester.tapAt(tester.getTopLeft(link) + const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(find.text('https://example.org/notes'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(bodyField).controller!.text, source);

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(await preferences.saveNoteMarkdownEnabled(false), isTrue);
    await tester.pumpAndSettle();
    expect(preview, findsNothing);
    expect(edit, findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.widget<TextField>(bodyField).controller!.text, source);

    expect(await preferences.saveNoteMarkdownEnabled(true), isTrue);
    await tester.pumpAndSettle();
    expect(preview, findsOneWidget);
    expect(edit, findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.widget<TextField>(bodyField).controller!.text, source);
    expect(changes, <String>[source]);
    expect(tester.takeException(), isNull);
  });

  /// 宽屏应把删除和保存放在同一个最右侧操作组，不随左侧按钮宽度漂移。
  testWidgets('笔记删除保存按钮在宽屏默认靠右', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final TextEditingController titleController = TextEditingController(
      text: 'test',
    );
    final TextEditingController bodyController = TextEditingController(
      text: 'test',
    );
    addTearDown(titleController.dispose);
    addTearDown(bodyController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: VideoNoteComposer(
              titleController: titleController,
              bodyController: bodyController,
              position: const Duration(minutes: 8, seconds: 32),
              includeFrame: false,
              saving: false,
              onIncludeFrameChanged: (_) {},
              onSave: () {},
              onNew: () {},
              onClose: () {},
              onJumpToPosition: () {},
              onDelete: () {},
              borderless: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect commitActions = tester.getRect(
      find.byKey(const Key('video-note-commit-actions')),
    );
    final Rect composerBounds = tester.getRect(find.byType(VideoNoteComposer));
    expect(commitActions.right, closeTo(composerBounds.right, 0.1));
    expect(
      tester.getRect(find.byKey(const Key('delete-video-note'))).right,
      lessThan(tester.getRect(find.byKey(const Key('save-video-note'))).left),
    );
  });
}
