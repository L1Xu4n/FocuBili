import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/focus/focus_completion_dialog.dart';
import 'package:focubili/models/focus_session.dart';

/// 注册正常完成庆祝动画和续时操作的组件测试。
void main() {
  /// 验证完成弹窗展示礼花，并把五分钟续时选择返回调用页面。
  testWidgets('专注完成弹窗庆祝并支持续时', (WidgetTester tester) async {
    Duration? selectedExtension;
    final FocusSession session =
        FocusSession.start(
          id: 'completed-1',
          goal: '看完课程',
          plannedDuration: const Duration(minutes: 25),
          now: DateTime(2026, 7, 18, 9),
        ).finishAt(
          DateTime(2026, 7, 18, 9, 25),
          finalStatus: FocusSessionStatus.completed,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: FilledButton(
              // 打开函数显示待测庆祝弹窗并保存返回的续时时长。
              onPressed: () async {
                selectedExtension = await showFocusCompletionDialog(
                  context,
                  session,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(find.byKey(const Key('focus-completion-confetti')), findsOneWidget);
    final Size confettiSize = tester.getSize(
      find.byKey(const Key('focus-completion-confetti')),
    );
    expect(confettiSize.width, greaterThan(500));
    expect(confettiSize.height, greaterThan(400));
    expect(find.text('专注已结束，做得好！'), findsOneWidget);
    await tester.tap(find.byKey(const Key('extend-completed-focus')));
    await tester.pumpAndSettle();

    expect(selectedExtension, const Duration(minutes: 5));
  });
}
