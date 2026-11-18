import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/widgets/drag_selection_region.dart';

void main() {
  testWidgets('drag gives stable grid order and anchor on a reversal', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final updates = <DragSelectionUpdate>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: DragSelectionRegion(
                controller: controller,
                itemCount: 40,
                checkedAt: (index) => index == 1,
                onDragUpdate: updates.add,
                builder: (context, dragging) => GridView.builder(
                  controller: controller,
                  physics: dragging
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: 40,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisExtent: 60,
                    crossAxisSpacing: 16,
                  ),
                  itemBuilder: (context, index) => DragSelectionTarget(
                    key: ValueKey('card-$index'),
                    index: index,
                    builder: (context, handleKey) => ListTile(
                      title: Text('Video $index'),
                      trailing: KeyedSubtree(
                        key: handleKey,
                        child: Checkbox(
                          key: ValueKey('box-$index'),
                          value: index == 1,
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final fromTitle = await tester.startGesture(
      tester.getCenter(find.text('Video 1')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await fromTitle.up();
    await tester.pumpAndSettle();
    expect(updates, isEmpty);

    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('box-1'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('box-6'))));
    await tester.pump();
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('box-3'))));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(updates, [
      (anchor: 1, previous: 1, current: 1, checked: false),
      (anchor: 1, previous: 1, current: 6, checked: false),
      (anchor: 1, previous: 6, current: 3, checked: false),
    ]);
    expect(tester.takeException(), isNull);
  });
}
