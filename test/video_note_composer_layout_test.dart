import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/notes/video_note_composer.dart';

/// 验证时间点笔记底部操作在宽屏和窄屏都保持稳定的右对齐布局。
void main() {
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
