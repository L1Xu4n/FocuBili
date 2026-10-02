import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/player_tap_gesture.dart';

/// 验证轻微位移双击、正常拖动、单击和取消不会彼此串成操作。
void main() {
  testWidgets('画面双击容忍20像素位移且真实拖动和单击仍有效', (tester) async {
    var single = 0;
    var double = 0;
    var drag = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            gestureSettings: playerTouchGestureSettings,
          ),
          child: GestureDetector(
            onHorizontalDragStart: (_) => drag++,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                PlayerTapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      PlayerTapGestureRecognizer
                    >(
                      PlayerTapGestureRecognizer.new,
                      (recognizer) => recognizer
                        ..gestureSettings = playerTouchGestureSettings
                        ..onSingleTap = () {
                          single++;
                        }
                        ..onDoubleTap = () {
                          double++;
                        },
                    ),
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      final pointer = await tester.startGesture(const Offset(100, 100));
      await pointer.moveBy(const Offset(20, 0));
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(double, 1);
    expect(single, 0);
    expect(drag, 0);
    await tester.dragFrom(const Offset(100, 100), const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 350));
    expect(drag, 1);
    expect(single, 0);
    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 350));
    expect(single, 1);
    await tester.tapAt(const Offset(100, 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
    expect(single, 1);
  });
}
