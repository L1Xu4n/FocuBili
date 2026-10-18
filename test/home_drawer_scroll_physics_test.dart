import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';

void main() {
  test('a fast gesture advances only one drawer stop', () {
    expect(
      HomeDrawerScrollPhysics.snapTarget(
        position: 230,
        start: 0,
        velocity: 5000,
        extent: 700,
      ),
      350,
    );
    expect(
      HomeDrawerScrollPhysics.snapTarget(
        position: 470,
        start: 700,
        velocity: -5000,
        extent: 700,
      ),
      350,
    );
    expect(
      HomeDrawerScrollPhysics.snapTarget(
        position: 490,
        start: 350,
        velocity: 1800,
        extent: 700,
      ),
      700,
    );
  });

  test(
    'slow release chooses the nearest stop and ignores accidental motion',
    () {
      expect(
        HomeDrawerScrollPhysics.snapTarget(
          position: 305,
          start: 0,
          velocity: 80,
          extent: 700,
        ),
        350,
      );
      expect(
        HomeDrawerScrollPhysics.snapTarget(
          position: 346,
          start: 350,
          velocity: -80,
          extent: 700,
        ),
        350,
      );
      expect(
        HomeDrawerScrollPhysics.snapTarget(
          position: 200,
          start: 1400,
          velocity: -4000,
          extent: 700,
        ),
        700,
      );
    },
  );

  test('ballistic return from card content cannot close the drawer', () {
    final physics = HomeDrawerScrollPhysics(
      cardOffset: () => 700,
      gestureStart: () => 1200,
      enabled: () => true,
      parent: const ClampingScrollPhysics(),
    );
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 2400,
      pixels: 1100,
      viewportDimension: 800,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    final Simulation simulation = physics.createBallisticSimulation(
      metrics,
      -5000,
    )!;
    for (var i = 0; i < 200; i++) {
      expect(simulation.x(i / 100), greaterThanOrEqualTo(700));
    }
    expect(simulation.isDone(2), isTrue);
  });

  test('programmatic scrolling and editing retain normal physics', () {
    final physics = HomeDrawerScrollPhysics(
      cardOffset: () => 700,
      gestureStart: () => null,
      enabled: () => true,
      parent: const ClampingScrollPhysics(),
    );
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 2400,
      pixels: 300,
      viewportDimension: 800,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.createBallisticSimulation(metrics, 0), isNull);
  });

  test(
    'a drag starting closed cannot bypass stops by crossing the open boundary',
    () {
      final physics = HomeDrawerScrollPhysics(
        cardOffset: () => 700,
        gestureStart: () => 0,
        enabled: () => true,
        parent: const ClampingScrollPhysics(),
      );
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 2400,
        pixels: 850,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      final simulation = physics.createBallisticSimulation(metrics, 5000)!;
      expect(simulation.x(3), closeTo(350, 2));
      final contentPhysics = HomeDrawerScrollPhysics(
        cardOffset: () => 700,
        gestureStart: () => 700,
        enabled: () => true,
        parent: const ClampingScrollPhysics(),
      );
      expect(
        contentPhysics.createBallisticSimulation(metrics, 2000)!.x(0.1),
        greaterThan(850),
      );
    },
  );

  test(
    'bouncing top overscroll from open stops half-open instead of closing',
    () {
      final physics = HomeDrawerScrollPhysics(
        cardOffset: () => 700,
        gestureStart: () => 700,
        enabled: () => true,
        parent: const BouncingScrollPhysics(),
      );
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 2400,
        pixels: -50,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      expect(
        physics.createBallisticSimulation(metrics, -5000)!.x(3),
        closeTo(350, 2),
      );
    },
  );
}
