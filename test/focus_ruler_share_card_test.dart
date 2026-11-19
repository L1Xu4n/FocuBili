import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/focus/focus_ruler_share_cards.dart';
import 'package:focubili/features/focus/focus_share_preview.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/focus_statistics.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/focus_share_service.dart';
import 'package:focubili/services/windows_experience_service.dart';

FocusSession _session(Duration active, {DateTime? start, DateTime? end}) =>
    FocusSession(
      id: 'share-ruler-test',
      goal: '弄懂指针与地址',
      plannedDuration: const Duration(minutes: 45),
      startedAt: start ?? DateTime(2026, 11, 19, 19, 30),
      finishedAt: end ?? DateTime(2026, 11, 19, 20, 15),
      accumulatedFocusDuration: active,
      status: FocusSessionStatus.completed,
      sourceVideoTitle: 'C 语言基础・指针与内存地址',
    );

FocusStatisticsSnapshot _statistics(
  FocusStatisticsRange range, {
  bool empty = false,
}) {
  final short = range == FocusStatisticsRange.sevenDays;
  final daily = [
    if (!short) ...[
      15,
      25,
      0,
      0,
      10,
      20,
      0,
      35,
      15,
      0,
      25,
      10,
      0,
      40,
      0,
      20,
      0,
      35,
      15,
      25,
      0,
      0,
      15,
    ],
    35,
    55,
    0,
    70,
    90,
    50,
    75,
  ];
  return FocusStatisticsSnapshot(
    range: range,
    totalFocusedDuration: range == FocusStatisticsRange.all
        ? const Duration(hours: 99)
        : Duration(minutes: daily.fold(0, (a, b) => a + b)),
    averageFocusedDuration: const Duration(minutes: 45),
    longestFocusedDuration: const Duration(minutes: 90),
    completedCount: short ? 9 : 24,
    endedEarlyCount: short ? 1 : 3,
    focusDayCount: daily.where((value) => value > 0).length,
    currentStreakDays: 4,
    linkedVideoCount: 4,
    interruptionCount: 1,
    dailyTrend: empty
        ? const []
        : [
            for (final (index, minutes) in daily.indexed)
              FocusDailyStatistic(
                date: DateTime(2026, 11, 20 - daily.length + index),
                focusedDuration: Duration(minutes: minutes),
                sessionCount: minutes == 0 ? 0 : 1,
              ),
          ],
  );
}

class _ClipboardProbe extends WindowsExperienceService {
  int copies = 0;
  int? height;
  int? width;
  Uint8List? bytes;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> copyRenderedImage(
    ui.Image image, {
    required Uint8List png,
  }) async {
    copies++;
    height = image.height;
    width = image.width;
    bytes = png;
    entered.complete();
    await release.future;
  }
}

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext) show, {
  TextScaler scaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaler),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(show(context)),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  final classic = find.byKey(const ValueKey('focus-share-style-classic'));
  final ruler = find.byKey(const ValueKey('focus-share-style-ruler'));
  final share = find.byKey(const Key('share-focus-card'));

  test(
    'dial stays on the one-hour scale through 60 minutes and does not wrap above it',
    () {
      expect(focusRulerDialScale(Duration.zero), 60);
      expect(focusRulerDialScale(const Duration(minutes: 45)), 60);
      expect(focusRulerDialScale(const Duration(hours: 1)), 60);
      expect(focusRulerDialScale(const Duration(hours: 1, seconds: 1)), 120);
      expect(focusRulerDialScale(const Duration(hours: 3)), 180);
    },
  );

  testWidgets(
    'zero actual time is not replaced by the plan; overnight ends disclose date',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusRulerSessionCard(
              session: _session(
                Duration.zero,
                start: DateTime(2026, 11, 18, 23, 40),
                end: DateTime(2026, 11, 19, 0, 10),
              ),
            ),
          ),
        ),
      );
      expect(find.text('0 分钟  ', findRichText: true), findsOneWidget);
      expect(find.textContaining('23:40', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('11/19 00:10', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('45', findRichText: true), findsNothing);
      expect(find.text('全圈 60 分钟'), findsOneWidget);
    },
  );

  for (final session in [true, false]) {
    testWidgets(
      '${session ? 'session' : 'statistics'} exports the selected style immediately, locks during export, and resets when reopened',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final probe = _ClipboardProbe();
        final service = FocusShareService(
          platform: AppPlatform.linux,
          windowsExperience: probe,
        );
        Future<void> show(BuildContext context) => session
            ? showFocusSessionSharePreview(
                context,
                _session(const Duration(minutes: 25)),
                shareService: service,
              )
            : showFocusStatisticsSharePreview(
                context,
                _statistics(FocusStatisticsRange.thirtyDays),
                shareService: service,
              );
        await _open(tester, show);
        expect(tester.widget<ChoiceChip>(classic).selected, isTrue);
        expect(
          find.byType(
            session ? FocusSessionShareCard : FocusStatisticsShareCard,
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          await tester.tap(ruler);
          // Do not pump between selecting the alternate style and tapping Share.
          await tester.tap(share);
          await tester.tap(share);
          for (
            var attempt = 0;
            attempt < 50 && !probe.entered.isCompleted;
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        expect(probe.copies, 1);
        expect(probe.width, 1080);
        expect(probe.height, 1440);
        expect(probe.bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(tester.widget<ChoiceChip>(ruler).onSelected, isNull);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text('分享预览'), findsOneWidget);
        await tester.runAsync(() async {
          probe.release.complete();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(classic).selected, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'narrow landscape large text lets user switch and scroll to share',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(330, 240);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _open(
        tester,
        (context) => showFocusStatisticsSharePreview(
          context,
          _statistics(FocusStatisticsRange.all),
        ),
        scaler: TextScaler.linear(2),
      );
      await tester.tap(ruler);
      await tester.pumpAndSettle();
      expect(find.text('近 30 天每日专注（分钟）'), findsOneWidget);
      await tester.ensureVisible(share);
      await tester.pumpAndSettle();
      expect(share.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final range in FocusStatisticsRange.values) {
    testWidgets(
      'ruler statistics ${range.name} has fixed canvas and daily semantics',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: FocusRulerStatisticsCard(snapshot: _statistics(range)),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(FocusRulerStatisticsCard)),
          const Size(360, 480),
        );
        expect(find.bySemanticsLabel('每日专注柱状图，纵轴为分钟，横轴为日期'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  const captureDir = String.fromEnvironment('FOCU_SHARE_CAPTURE_DIR');
  if (captureDir.isNotEmpty) {
    testWidgets(
      'capture approved templates using real Flutter render boundaries',
      (tester) async {
        await tester.runAsync(() async {
          final sansPath = Platform.environment['FOCU_CAPTURE_SANS'];
          final serifPath = Platform.environment['FOCU_CAPTURE_SERIF'];
          if (sansPath == null || serifPath == null) {
            throw StateError(
              'Provide FOCU_CAPTURE_SANS and FOCU_CAPTURE_SERIF for local evidence.',
            );
          }
          for (final (font, path) in [
            ('CaptureSans', sansPath),
            ('serif', serifPath),
          ]) {
            final bytes = await File(path).readAsBytes();
            await (FontLoader(
              font,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
        for (final (name, card) in [
          (
            'session',
            FocusRulerSessionCard(
              session: _session(const Duration(minutes: 45)),
              todayFocusedDuration: const Duration(minutes: 75),
              cumulativeFocusedDuration: const Duration(hours: 12),
            ),
          ),
          (
            'seven-days',
            FocusRulerStatisticsCard(
              snapshot: _statistics(FocusStatisticsRange.sevenDays),
            ),
          ),
          (
            'thirty-days',
            FocusRulerStatisticsCard(
              snapshot: _statistics(FocusStatisticsRange.thirtyDays),
            ),
          ),
        ]) {
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(fontFamily: 'CaptureSans'),
              home: Scaffold(
                body: Center(
                  child: RepaintBoundary(key: key, child: card),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 3);
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(captureDir).create(recursive: true);
              await File(
                '$captureDir/$name.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      },
    );
  }
}
