import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps the welcome area, half-open drawer and first card reachable in one drag.
/// The content below the first card retains the platform's scrolling behavior.
class HomeDrawerScrollPhysics extends ScrollPhysics {
  const HomeDrawerScrollPhysics({
    required this.cardOffset,
    required this.gestureStart,
    required this.enabled,
    super.parent,
  });

  final double Function() cardOffset;
  final double? Function() gestureStart;
  final bool Function() enabled;

  @override
  HomeDrawerScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      HomeDrawerScrollPhysics(
        cardOffset: cardOffset,
        gestureStart: gestureStart,
        enabled: enabled,
        parent: buildParent(ancestor),
      );

  /// A fling advances at most one stop from the place the finger started.
  static double snapTarget({
    required double position,
    required double start,
    required double velocity,
    required double extent,
  }) {
    if (extent <= 0) return 0;
    final stops = <double>[0, extent / 2, extent];
    if (start > extent + 24) return extent;
    var startIndex = 0;
    var nearest = 0;
    for (var i = 1; i < stops.length; i++) {
      if ((stops[i] - start).abs() < (stops[startIndex] - start).abs()) {
        startIndex = i;
      }
      if ((stops[i] - position).abs() < (stops[nearest] - position).abs()) {
        nearest = i;
      }
    }
    final distance = position - start;
    // Tiny taps and incidental motion cannot open or close the drawer.
    if (distance.abs() < 18 && velocity.abs() < 650) {
      return stops[startIndex];
    }
    if (velocity.abs() >= 650 && distance.abs() >= 18) {
      nearest = startIndex + (velocity > 0 ? 1 : -1);
    }
    final lower = math.max(0, startIndex - 1);
    final upper = math.min(stops.length - 1, startIndex + 1);
    return stops[nearest.clamp(lower, upper)];
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (!enabled() || gestureStart() == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final extent = cardOffset().clamp(0.0, position.maxScrollExtent);
    if (extent <= 1) {
      return super.createBallisticSimulation(position, velocity);
    }
    final start = gestureStart()!;
    if (position.outOfRange &&
        position.pixels > position.maxScrollExtent &&
        start >= extent - 24) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (position.pixels <= extent + 24 || start < extent - 24) {
      final target = snapTarget(
        position: position.pixels,
        start: start,
        velocity: velocity,
        extent: extent,
      );
      final tolerance = toleranceFor(position);
      if ((target - position.pixels).abs() <= tolerance.distance &&
          velocity.abs() <= tolerance.velocity) {
        return null;
      }
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        target,
        // Bound momentum so a quick gesture does not overshoot another stop.
        velocity.clamp(-900.0, 900.0),
        tolerance: tolerance,
      );
    }
    final simulation = super.createBallisticSimulation(position, velocity);
    // A fling from a scrolled card list first returns to the open drawer.
    // Closing it requires another deliberate gesture in the welcome area.
    if (simulation != null && velocity < 0) {
      return _DrawerBoundarySimulation(simulation, extent);
    }
    return simulation;
  }
}

class _DrawerBoundarySimulation extends Simulation {
  _DrawerBoundarySimulation(this.delegate, this.minimum);
  final Simulation delegate;
  final double minimum;

  @override
  double x(double time) => math.max(minimum, delegate.x(time));

  @override
  double dx(double time) => delegate.x(time) <= minimum ? 0 : delegate.dx(time);

  @override
  bool isDone(double time) =>
      delegate.x(time) <= minimum || delegate.isDone(time);
}
