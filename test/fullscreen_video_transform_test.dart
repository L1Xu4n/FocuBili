import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/fullscreen_video_transform.dart';

/// Builds a picture surface with real tap/drag recognizers to catch multitouch conflicts.
Widget surface({
  bool enabled = true,
  VoidCallback? onTap,
  GestureDragUpdateCallback? onDrag,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 400,
      height: 300,
      child: FullscreenVideoTransform(
        enabled: enabled,
        builder: (context, matrix, paired) => GestureDetector(
          onTap: paired ? null : onTap,
          onHorizontalDragUpdate: paired ? null : onDrag,
          child: Transform(
            key: const Key('test-picture-transform'),
            alignment: Alignment.center,
            transform: matrix,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    ),
  ),
);

/// Reads the actual picture transform rather than private gesture implementation state.
Matrix4 pictureMatrix(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const Key('test-picture-transform')))
    .transform;

/// Sends one coordinated two-finger tap with monotonic event timestamps.
Future<void> pairedTap(WidgetTester tester, Offset center, int startMs) async {
  final first = await tester.createGesture(
    pointer: 11,
    kind: PointerDeviceKind.touch,
  );
  final second = await tester.createGesture(
    pointer: 12,
    kind: PointerDeviceKind.touch,
  );
  await first.down(
    center - const Offset(25, 0),
    timeStamp: Duration(milliseconds: startMs),
  );
  await second.down(
    center + const Offset(25, 0),
    timeStamp: Duration(milliseconds: startMs + 20),
  );
  await tester.pump();
  await first.up(timeStamp: Duration(milliseconds: startMs + 60));
  await second.up(timeStamp: Duration(milliseconds: startMs + 70));
  await tester.pump();
}

/// Verifies picture movement, reset, existing single-finger controls and the disabled setting.
void main() {
  testWidgets(
    'two fingers scale/pan and double paired tap resets without single tap',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(surface(onTap: () => taps++));
      final center = tester.getCenter(
        find.byKey(const Key('test-picture-transform')),
      );
      final first = await tester.createGesture(pointer: 1);
      final second = await tester.createGesture(pointer: 2);
      await first.down(center - const Offset(50, 0));
      await second.down(center + const Offset(50, 0));
      await tester.pump();
      await first.moveTo(center + const Offset(-20, 40));
      await second.moveTo(center + const Offset(180, 40));
      await tester.pump();
      expect(pictureMatrix(tester).entry(0, 0), closeTo(2, 0.001));
      expect(pictureMatrix(tester).entry(0, 3), closeTo(80, 0.001));
      expect(pictureMatrix(tester).entry(1, 3), closeTo(40, 0.001));
      await first.up();
      await second.up();
      await tester.pump();
      await pairedTap(tester, center, 1000);
      expect(pictureMatrix(tester).entry(0, 0), closeTo(2, 0.001));
      await pairedTap(tester, center, 1200);
      expect(pictureMatrix(tester), Matrix4.identity());
      expect(taps, 0);
    },
  );

  testWidgets('single finger still taps/drags without changing the picture', (
    tester,
  ) async {
    var taps = 0;
    var drags = 0;
    await tester.pumpWidget(
      surface(onTap: () => taps++, onDrag: (_) => drags++),
    );
    final picture = find.byKey(const Key('test-picture-transform'));
    await tester.tap(picture);
    await tester.pump();
    await tester.drag(picture, const Offset(90, 0));
    await tester.pump();
    expect(taps, 1);
    expect(drags, greaterThan(0));
    expect(pictureMatrix(tester), Matrix4.identity());
  });

  testWidgets(
    'disabled gestures ignore pairs and switching off resets the picture',
    (tester) async {
      await tester.pumpWidget(surface());
      final center = tester.getCenter(
        find.byKey(const Key('test-picture-transform')),
      );
      final first = await tester.createGesture(pointer: 1);
      final second = await tester.createGesture(pointer: 2);
      await first.down(center - const Offset(50, 0));
      await second.down(center + const Offset(50, 0));
      await first.moveTo(center - const Offset(100, 0));
      await second.moveTo(center + const Offset(100, 0));
      await tester.pump();
      expect(pictureMatrix(tester).entry(0, 0), closeTo(2, 0.001));
      await first.up();
      await second.up();
      await tester.pumpWidget(surface(enabled: false));
      expect(pictureMatrix(tester), Matrix4.identity());
      await pairedTap(tester, center, 1000);
      expect(pictureMatrix(tester), Matrix4.identity());
    },
  );
}
