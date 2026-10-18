import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_ab_repeat_sheet.dart';
import 'package:focubili/models/ab_repeat_range.dart';
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;
import 'player_ab_repeat_test.dart'
    show AbPlayback, abVideo, configureAb, menu, unmountAb;

void main() {
  testWidgets(
    'AB sheet 320px with 160% text keeps both point controls and actions reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var position = const Duration(seconds: 20);
      AbRepeatRange? applied;
      var clears = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PlayerAbRepeatSheet(
                    bvid: 'cheese:ss1',
                    cid: 1,
                    duration: const Duration(minutes: 2),
                    readPosition: () => position,
                    initialRange: const AbRepeatRange(
                      bvid: 'cheese:ss1',
                      cid: 1,
                      a: Duration(seconds: 10),
                      b: Duration(seconds: 30),
                    ),
                    onApply: (range) => applied = range,
                    onClear: () => clears++,
                  ),
                ),
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      for (final point in ['A', 'B']) {
        await tester.ensureVisible(find.byKey(Key('ab-repeat-set-$point')));
        await tester.tap(find.byKey(Key('ab-repeat-set-$point')));
        await tester.pumpAndSettle();
        position += const Duration(seconds: 2);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('ab-repeat-A-input')))
            .controller!
            .text,
        '00:20',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('ab-repeat-B-input')))
            .controller!
            .text,
        '00:22',
      );
      await tester.ensureVisible(find.byKey(const Key('ab-repeat-apply')));
      await tester.tap(find.byKey(const Key('ab-repeat-apply')));
      await tester.pumpAndSettle();
      expect(applied!.a, const Duration(seconds: 20));
      expect(applied!.b, const Duration(seconds: 22));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('ab-repeat-clear')));
      await tester.tap(find.byKey(const Key('ab-repeat-clear')));
      await tester.pumpAndSettle();
      expect(clears, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final entry in {
    'mobile': (const Size(390, 844), 1.0),
    'desktop-large-text': (const Size(1280, 800), 1.3),
  }.entries) {
    testWidgets('synthetic AB controls and timeline ${entry.key}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = entry.value.$1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const directory = String.fromEnvironment('AB_CAPTURE_DIR');
      if (directory.isNotEmpty) {
        await tester.runAsync(() async {
          for (final font in {
            'AbEvidence': 'C:/Windows/Fonts/msyh.ttc',
            'MaterialIcons':
                'C:/Users/L1XU4N/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            final bytes = await File(font.value).readAsBytes();
            await (FontLoader(
              font.key,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
      }
      final theme = AppTheme.light();
      final key = GlobalKey();
      final playback = AbPlayback();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: directory.isEmpty
                ? theme
                : theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'AbEvidence'),
                  ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(entry.value.$2)),
              child: child!,
            ),
            home: PlayerPage(
              video: abVideo,
              playbackService: playback,
              offlineVideoService: ReviewOfflineLibrary(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await playback.pause();
      await tester.pump();
      await configureAb(tester, b: '00:50');
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
      expect(tester.takeException(), isNull);
      Future<void> capture(String suffix) async {
        if (directory.isEmpty) return;
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/ab-${entry.key}-$suffix.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('timeline');
      await menu(tester, 'ab-repeat-menu-item');
      expect(find.byKey(const Key('ab-repeat-A-input')), findsOneWidget);
      expect(find.byKey(const Key('ab-repeat-clear')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('sheet');
      await unmountAb(tester);
    });
  }
}
