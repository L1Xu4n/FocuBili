import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';

const double _open = 700;

HomeDrawerScrollPhysics _physics(double? start, {bool enabled = true}) =>
    HomeDrawerScrollPhysics(
      cardOffset: () => _open,
      gestureStart: () => start,
      enabled: () => enabled,
      parent: const ClampingScrollPhysics(),
    );

FixedScrollMetrics _at(double pixels) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 2400,
  pixels: pixels,
  viewportDimension: 800,
  axisDirection: AxisDirection.down,
  devicePixelRatio: 1,
);

double _target(double position, double start, [double velocity = 0]) =>
    HomeDrawerScrollPhysics.snapTarget(
      position: position,
      start: start,
      velocity: velocity,
      extent: _open,
    );

void main() {
  test('a decisive pull moves directly between closed and open', () {
    expect(_target(120, 0, 2500), _open);
    expect(_target(580, _open, -2500), 0);
    expect(_target(120, 0), _open);
    expect(_target(580, _open), 0);
  });

  test('half-open is an optional rest, never forced on a fast fling', () {
    expect(_target(340, 0), 350);
    expect(_target(370, _open), 350);
    expect(_target(350, 0, 2000), _open);
    expect(_target(350, _open, -2000), 0);
    expect(_target(25, 0), 0);
    expect(_target(680, _open), _open);
  });

  test('interruption uses the release position and direction', () {
    expect(_target(290, 180, 950), _open);
    expect(_target(400, 600, -950), 0);
  });

  test('native list motion does not bounce a deliberate long drag back', () {
    final simulation = _physics(0).createBallisticSimulation(_at(850), 2000)!;
    expect(simulation.x(.1), greaterThan(850));
    expect(_physics(0).createBallisticSimulation(_at(850), 0), isNull);
  });

  test(
    'returning deep-list inertia stops at open until the drag crosses it',
    () {
      final simulation = _physics(
        1200,
      ).createBallisticSimulation(_at(1100), -5000)!;
      for (var i = 0; i < 200; i++) {
        expect(simulation.x(i / 100), greaterThanOrEqualTo(_open));
      }
      expect(simulation.x(2), _open);
      expect(simulation.isDone(2), isTrue);
      final deliberate = _physics(
        1200,
      ).createBallisticSimulation(_at(500), -1000)!;
      expect(deliberate.x(1), 0);
    },
  );

  test('settling does not move away from the target or overshoot it', () {
    final simulation = _physics(0).createBallisticSimulation(_at(350), 7000)!;
    var last = 350.0;
    for (var i = 1; i < 60; i++) {
      final next = simulation.x(i / 120);
      expect(next, inInclusiveRange(last, _open));
      last = next;
    }
    expect(last, closeTo(_open, .5));
  });

  test('programmatic scrolling and editing retain native physics', () {
    expect(_physics(null).createBallisticSimulation(_at(300), 0), isNull);
    expect(
      _physics(0, enabled: false).createBallisticSimulation(_at(300), 0),
      isNull,
    );
  });
}
