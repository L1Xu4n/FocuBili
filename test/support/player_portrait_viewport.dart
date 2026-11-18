import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real portrait FlutterView: widget constraints and MediaQuery must agree.
void setPlayerPortraitViewport(WidgetTester tester, Size size) {
  assert(size.height > size.width);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}
