import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder checkboxIn(Finder tile) =>
    find.descendant(of: tile, matching: find.byType(Checkbox));

Future<void> sweepCheckboxes(
  WidgetTester tester,
  Finder from,
  Finder to,
) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
  await gesture.moveTo(tester.getCenter(to));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 200));
}
