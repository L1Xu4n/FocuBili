import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One scroll position serves the welcome area and its cards. Nothing is
/// snapped during a drag; on release only the welcome range has detents.
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

  static const _snapSpring = SpringDescription(
    mass: 1,
    stiffness: 576,
    damping: 48,
  );

  @override
  HomeDrawerScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      HomeDrawerScrollPhysics(
        cardOffset: cardOffset,
        gestureStart: gestureStart,
        enabled: enabled,
        parent: buildParent(ancestor),
      );

  /// A short deliberate pull is enough at either end. An interrupted snap
  /// starts in between and uses the release position and its latest direction.
  /// Half-open is available as a slow, deliberate rest near the midpoint, not
  /// as a stop a long or fast gesture must visit.
  static double snapTarget({
    required double position,
    required double start,
    required double velocity,
    required double extent,
  }) {
    final midpoint = extent / 2;
    final movingFast = velocity.abs() >= 350;
    if (!movingFast &&
        (position - midpoint).abs() <= math.min(24, extent * .05)) {
      return midpoint;
    }

    // A fast fling from well inside a long list returns to the entry first.
    // A pull held across the boundary, or one clearly beyond it, can close
    // from the same gesture.
    if (start > extent + 160 &&
        velocity <= -350 &&
        position > extent - math.min(120, extent / 4)) {
      return extent;
    }

    final double threshold;
    if (start <= 2) {
      threshold = math.min(64, extent / 4);
    } else if (start >= extent - 2) {
      threshold = extent - math.min(96, extent / 4);
    } else {
      threshold = midpoint;
    }
    final projection = movingFast
        ? (velocity * .18).clamp(-extent / 2, extent / 2)
        : 0.0;
    return position + projection >= threshold ? extent : 0;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final start = gestureStart();
    if (!enabled() || start == null) {
      // Wheel, keyboard, ensureVisible and card editing keep platform physics.
      return super.createBallisticSimulation(position, velocity);
    }

    final extent = cardOffset().clamp(0.0, position.maxScrollExtent);
    final pixels = position.pixels;
    final tolerance = toleranceFor(position);
    if (extent <= 1 || pixels < position.minScrollExtent) {
      return super.createBallisticSimulation(position, velocity);
    }

    if (pixels >= extent) {
      // A real drag can cross the first card in either direction. Inertia
      // alone may return a scrolled list to its start, but must not close it.
      if (velocity < 0 && pixels - extent <= tolerance.distance) return null;
      final simulation = super.createBallisticSimulation(position, velocity);
      return simulation != null && velocity < 0
          ? _CardListBoundarySimulation(simulation, extent)
          : simulation;
    }

    final target = snapTarget(
      position: pixels,
      start: start,
      velocity: velocity,
      extent: extent,
    );
    final distance = target - pixels;
    if (distance.abs() <= tolerance.distance) return null;

    // Critical damping and a velocity in the target direction keep the
    // remaining motion monotonic, even when release meant reversing.
    final initialSpeed = (velocity * distance.sign).clamp(
      0.0,
      math.min(2200, distance.abs() * 24),
    );
    return ScrollSpringSimulation(
      _snapSpring,
      pixels,
      target,
      initialSpeed * distance.sign,
      tolerance: tolerance,
    );
  }
}

class _CardListBoundarySimulation extends Simulation {
  _CardListBoundarySimulation(this.delegate, this.minimum);

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
