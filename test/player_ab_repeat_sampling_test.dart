import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'player_ab_repeat_test.dart'
    show AbPlayback, mountAb, configureAb, unmountAb;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'one-second 5x A–B resumes on the first sampled position inside interval even if 400ms beyond A',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester, a: '20', b: '21');
      p.emitOnSeek = false;
      p.at(21, speed: 5);
      await tester.pump();
      expect(p.seeks, [const Duration(seconds: 20)]);
      p.emit(
        p.current.copyWith(
          position: const Duration(milliseconds: 20400),
          speed: 5,
        ),
      );
      await tester.pump();
      p.at(21, speed: 5);
      await tester.pump();
      final actual = List.of(p.seeks);
      await unmountAb(tester);
      expect(actual, [
        const Duration(seconds: 20),
        const Duration(seconds: 20),
      ]);
    },
  );

  testWidgets(
    'timer-triggered 5x loop accepts a fresh sample after the reported origin',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester, a: '20', b: '21');
      p.emitOnSeek = false;
      p.emit(
        p.current.copyWith(
          position: const Duration(milliseconds: 20200),
          speed: 5,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(p.seeks, [const Duration(seconds: 20)]);

      // Virtual time reached B, but no position event reported B before seek.
      p.emit(p.current.copyWith(position: const Duration(milliseconds: 20400)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(p.seeks, [
        const Duration(seconds: 20),
        const Duration(seconds: 20),
      ]);
      await unmountAb(tester);
    },
  );

  testWidgets(
    'a seek with no usable position exits without hammering the backend',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester, a: '20', b: '21');
      p.emitOnSeek = false;
      p.at(21, speed: 5);
      await tester.pump();
      p.at(26, speed: 5);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(p.seeks, [const Duration(seconds: 20)]);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      expect(find.text('未能确认区间回跳，已关闭 A–B 循环'), findsOneWidget);
      await unmountAb(tester);
    },
  );
}
