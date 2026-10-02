import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/player_feedback_layout.dart';
import 'package:focubili/features/player/widgets/player_notice_controller.dart';

/// 核验提示计时、真实控制栏避让、叠放和小空间中的操作可达性。
void main() {
  testWidgets('短提示独立到期且重复消息续期不覆盖其他消息', (tester) async {
    final notices = PlayerNoticeController();
    notices.show('第一条');
    await tester.pump(const Duration(seconds: 1));
    notices.show('第二条', actionLabel: '查看', onAction: () {});
    await tester.pump(const Duration(seconds: 1));
    notices.show('第一条');
    expect(notices.messages, ['第一条', '第二条']);
    expect(notices.entries.last.actionLabel, '查看');
    await tester.pump(const Duration(milliseconds: 2100));
    expect(notices.messages, ['第一条']);
    await tester.pump(const Duration(seconds: 1));
    expect(notices.messages, isEmpty);
    notices.show('退出后不回调');
    notices.dispose();
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('80至200百分比上下栏按实际换行高度避让并纵向排列提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final scale in [.8, 1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                PlayerFeedbackViewport(
                  controlsVisible: true,
                  topControls: SizedBox(
                    key: const Key('top'),
                    height: 34 * scale + 24,
                  ),
                  bottomControls: SizedBox(
                    key: const Key('bottom'),
                    height: 92 * scale,
                  ),
                  feedback: const PlayerFeedbackStack(
                    children: [
                      PlayerNoticeCard(key: Key('first'), message: '第一条提示'),
                      PlayerNoticeCard(key: Key('second'), message: '第二条提示'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const Key('player-feedback-viewport')),
      );
      expect(
        viewport.top,
        tester.getRect(find.byKey(const Key('top'))).bottom + 8,
      );
      expect(
        viewport.bottom,
        tester.getRect(find.byKey(const Key('bottom'))).top - 8,
      );
      final first = tester.getRect(find.byKey(const Key('first')));
      final second = tester.getRect(find.byKey(const Key('second')));
      expect(first.bottom + 6, closeTo(second.top, .1));
      expect(first.top, greaterThanOrEqualTo(viewport.top));
      expect(second.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('小反馈视口可滚动到操作按钮而不进入播放栏', (tester) async {
    var clicked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 180,
            child: PlayerFeedbackViewport(
              controlsVisible: true,
              topControls: const SizedBox(height: 40),
              bottomControls: const SizedBox(height: 40),
              feedback: PlayerFeedbackStack(
                interactive: true,
                children: [
                  for (var i = 0; i < 5; i++)
                    PlayerNoticeCard(message: '提示 $i'),
                  TextButton(
                    key: const Key('action'),
                    onPressed: () => clicked = true,
                    child: const Text('继续学习'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('action')));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(
      find.byKey(const Key('player-feedback-viewport')),
    );
    final action = tester.getRect(find.byKey(const Key('action')));
    expect(action.top, greaterThanOrEqualTo(viewport.top));
    expect(action.bottom, lessThanOrEqualTo(viewport.bottom));
    await tester.tap(find.byKey(const Key('action')));
    expect(clicked, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通提示透传触摸且隐藏播放栏后反馈空间恢复', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 180,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
                const PlayerFeedbackViewport(
                  controlsVisible: false,
                  edgeInsets: EdgeInsets.only(top: 10, bottom: 12),
                  topControls: IgnorePointer(child: SizedBox(height: 50)),
                  bottomControls: IgnorePointer(child: SizedBox(height: 60)),
                  feedback: PlayerFeedbackStack(
                    children: [PlayerNoticeCard(message: '提示')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = tester.getRect(
      find.byKey(const Key('player-feedback-viewport')),
    );
    expect(viewport.height, 140);
    await tester.tapAt(tester.getCenter(find.text('提示')));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
