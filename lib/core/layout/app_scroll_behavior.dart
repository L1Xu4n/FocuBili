import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Opts horizontal lists into mouse dragging without changing text-selection surfaces.
class AppScrollBehavior extends MaterialScrollBehavior {
  /// Apply through HorizontalMouseScroll, not to the whole MaterialApp.
  const AppScrollBehavior();

  /// Keeps touch, stylus and trackpad support while enabling the desktop mouse.
  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

/// Gives a horizontal strip mouse support while keeping surrounding editors unchanged.
class HorizontalMouseScroll extends StatelessWidget {
  /// Wraps a horizontal list without taking ownership of its controller or physics.
  const HorizontalMouseScroll({super.key, required this.child});
  final Widget child;

  /// Overrides pointer policy only for this strip's descendants.
  @override
  Widget build(BuildContext context) =>
      ScrollConfiguration(behavior: const AppScrollBehavior(), child: child);
}
