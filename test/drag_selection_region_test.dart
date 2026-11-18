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

  testWidgets('a slow appended page resumes edge drag without moving', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final updates = <DragSelectionUpdate>[];
    final viewport = GlobalKey();
    late StateSetter rebuild;
    var loaded = 8;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SizedBox(
                  width: 400,
                  height: 300,
                  child: DragSelectionRegion(
                    controller: controller,
                    itemCount: loaded,
                    checkedAt: (_) => false,
                    onDragUpdate: updates.add,
                    builder: (context, dragging) => ListView.builder(
                      key: viewport,
                      controller: controller,
                      physics: dragging
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: loaded,
                      itemExtent: 56,
                      itemBuilder: (context, index) => DragSelectionTarget(
                        index: index,
                        builder: (context, handleKey) => ListTile(
                          title: Text('Page row $index'),
                          trailing: KeyedSubtree(
                            key: handleKey,
                            child: Checkbox(
                              key: ValueKey('page-box-$index'),
                              value: false,
                              onChanged: (_) {},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    final start = tester.getCenter(find.byKey(const ValueKey('page-box-3')));
    final edge = tester.getRect(find.byKey(viewport)).bottom - 2;
    final drag = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await drag.moveTo(Offset(start.dx, edge));
    Future<void> advance() async {
      for (int frame = 0; frame < 45; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await advance();
    final firstPageEnd = controller.position.maxScrollExtent;
    expect(controller.offset, firstPageEnd);
    expect(updates.last.current, 7);
    expect(updates.every((update) => update.current < loaded), isTrue);

    // Eventually a response arrives while the finger is still in place.
    rebuild(() => loaded = 18);
    await tester.pump();
    await advance();
    expect(controller.offset, greaterThan(firstPageEnd + 100));
    expect(updates.last.current, greaterThanOrEqualTo(8));
    expect(
      updates.every((update) => update.anchor == 3 && update.checked),
      isTrue,
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
