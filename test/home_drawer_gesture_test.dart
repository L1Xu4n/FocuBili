import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';

void main() {
  testWidgets(
    'quick drawer drags stop half-open before fully opening and closing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FocusTimerController(
        tickInterval: const Duration(days: 1),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusDashboard(
              controller: controller,
              onOpenVideo: () {},
              onOpenStatistics: () {},
              onOpenProfile: () {},
              onOpenLearningList: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final view = find.byType(CustomScrollView).first;
      final scroll = tester.widget<CustomScrollView>(view).controller!;
      expect(
        tester.widget<CustomScrollView>(view).physics,
        isA<HomeDrawerScrollPhysics>(),
      );
      await tester.fling(view, const Offset(0, -120), 2500);
      await tester.pumpAndSettle();
      final half = scroll.offset;
      expect(half, inInclusiveRange(350, 410));
      await tester.fling(view, const Offset(0, -120), 2500);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(half * 2, 2));
      await tester.fling(view, const Offset(0, 120), 2500);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(half, 2));
      await tester.fling(view, const Offset(0, 120), 2500);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(0, 2));
      await tester.flingFrom(
        const Offset(215, 850),
        const Offset(0, -810),
        3000,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(half, 2));
    },
  );
}
