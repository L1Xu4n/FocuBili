import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/app.dart';
import 'package:focubili/core/theme/app_text_scale.dart';
import 'package:focubili/features/profile/app_text_scale_controller.dart';
import 'package:focubili/features/profile/app_text_size_page.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/services/app_text_scale_service.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/features/search/search_video_row.dart';

class _Runtime implements SettingsRuntimeAdapter {
  @override
  Future<Map<String, Object>> readSettings() async => {};
  @override
  Future<void> writeSettings(Map<String, Object?> values) async {}
}

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double size) => size < 20 ? size * 1.8 : size * 1.2;
  @override
  double get textScaleFactor => 1.8;
}

class _DelayedScaleService extends AppTextScaleService {
  final loadGate = Completer<double>();
  final writes = <double>[];
  bool fail = false;
  @override
  Future<double> load() => loadGate.future;
  @override
  Future<void> save(double value) async {
    if (fail) throw StateError('synthetic storage failure');
    writes.add(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'UI scale defaults, bounds, persistence and reset remain separate from subtitles',
    () async {
      const service = AppTextScaleService();
      expect(await service.load(), 1);
      final c = AppTextScaleController();
      addTearDown(c.dispose);
      await c.initialize();
      expect(await c.setScale(2.0), true);
      final restored = AppTextScaleController();
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.scale, 2.0);
      expect(await restored.setScale(1), true);
      expect(await service.load(), 1);
      expect(AppTextScaleService.normalize(double.nan), 1);
      expect(AppTextScaleService.normalize(20), 2.0);
      expect(AppTextScaleService.normalize(.1), .8);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'playback_preferences.subtitle_font_size',
        ),
        false,
      );
    },
  );

  test(
    'late preference load cannot overwrite preview; failed writes roll back',
    () async {
      final service = _DelayedScaleService();
      final c = AppTextScaleController(service: service);
      addTearDown(c.dispose);
      final loading = c.initialize();
      c.preview(1.5);
      service.loadGate.complete(1.2);
      await loading;
      expect(c.scale, 1.5);
      service.fail = true;
      expect(await c.setScale(2.0), false);
      expect(c.scale, 1.2);
      service.fail = false;
      final first = c.setScale(1.3), second = c.setScale(2.0);
      expect(await first, true);
      expect(await second, true);
      expect(service.writes, [1.3, 2.0]);
      expect(c.scale, 2.0);
    },
  );

  test('composition preserves nonlinear OS scaling and default identity', () {
    const system = _NonlinearScaler();
    const unchanged = AppUiTextScaler(system, 1);
    const enlarged = AppUiTextScaler(system, 1.6);
    expect(unchanged.scale(14), system.scale(14));
    expect(unchanged.scale(28), system.scale(28));
    expect(enlarged.scale(14), closeTo(system.scale(14) * 1.6, .001));
    expect(enlarged.scale(28), closeTo(system.scale(28) * 1.6, .001));
  });

  test(
    'UI preference participates in the existing settings transfer schema',
    () async {
      await const AppTextScaleService().save(1.4);
      final transfer = SettingsTransferService(runtimeAdapter: _Runtime());
      final values = transfer.parseSettings(await transfer.exportSettings());
      expect(values[AppTextScaleService.preferenceKey], 1.4);
    },
  );

  testWidgets('real application root hot-updates the inherited scaler', (
    tester,
  ) async {
    final c = AppTextScaleController();
    addTearDown(c.dispose);
    await tester.pumpWidget(FocuBiliApp(appTextScaleController: c));
    await tester.pumpAndSettle();
    var scope = tester.element(find.byType(AppTextScaleScope).first);
    final before = MediaQuery.textScalerOf(scope).scale(14);
    c.preview(1.5);
    await tester.pumpAndSettle();
    scope = tester.element(find.byType(AppTextScaleScope).first);
    // Read below the scope's MediaQuery, rather than its unscaled parent.
    final media = tester.widget<MediaQuery>(
      find
          .descendant(
            of: find.byType(AppTextScaleScope).first,
            matching: find.byType(MediaQuery),
          )
          .first,
    );
    expect(media.data.textScaler.scale(14), closeTo(before * 1.5, .001));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'video list grows for large text while icons and taps stay usable',
    (tester) async {
      final c = AppTextScaleController();
      addTearDown(c.dispose);
      await c.initialize();
      var taps = 0;
      for (final width in [360.0, 1080.0]) {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: AppTextScale(controller: c, child: child!),
            ),
            home: Scaffold(
              body: ListView(
                children: [
                  SearchVideoRow(
                    rowKey: const Key('scaled-video-row'),
                    title:
                        'Large video title with additional details and a second line',
                    owner: 'Video owner',
                    publishedAt: '2026-10-20',
                    playCount: '12.3万',
                    danmakuCount: '4567',
                    thumbnailBuilder: (width) => SizedBox(
                      width: width,
                      height: width * 9 / 16,
                      child: const ColoredBox(color: Colors.blueGrey),
                    ),
                    menu: const Icon(
                      Icons.more_vert,
                      key: Key('unscaled-menu-icon'),
                    ),
                    onTap: () => taps++,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        c.preview(1);
        await tester.pumpAndSettle();
        final original = tester
            .getSize(find.byKey(const Key('scaled-video-row')))
            .height;
        final menuSize = tester.getSize(
          find.byKey(const Key('unscaled-menu-icon')),
        );
        c.preview(2.0);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('scaled-video-row'))).height,
          greaterThanOrEqualTo(original),
        );
        expect(
          tester.getSize(find.byKey(const Key('unscaled-menu-icon'))),
          menuSize,
        );
        await tester.tap(find.byKey(const Key('scaled-video-row')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(taps, 2);
    },
  );

  testWidgets(
    'large UI text is live, scrollable, resettable, and reaches dialogs/routes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final font = FontLoader('UiTextTest');
      if (File('C:/Windows/Fonts/msyh.ttc').existsSync()) {
        font.addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
            ),
          ),
        );
        await font.load();
      }
      final c = AppTextScaleController();
      addTearDown(c.dispose);
      await c.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('ui-capture'),
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'UiTextTest'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: AppTextScale(controller: c, child: child!),
            ),
            home: const AppTextSizePage(),
          ),
        ),
      );
      final slider = tester.widget<Slider>(
        find.byKey(const Key('ui-text-size-slider')),
      );
      slider.onChanged!(2.0);
      slider.onChangeEnd!(2.0);
      await tester.pumpAndSettle();
      expect(find.text('当前 200%'), findsOneWidget);
      final preview = tester.element(
        find.byKey(const Key('ui-text-size-preview')),
      );
      expect(MediaQuery.textScalerOf(preview).scale(16), closeTo(48, .001));
      expect(AppTextScaleScope.subtitleScalerOf(preview).scale(16), 24);
      if (Platform.environment['FOCUBILI_LAYOUT_CAPTURE'] == '1') {
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('ui-capture')),
              )
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final f = File('evidence/subtitle-layout/ui-text-200-system150.png');
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final reset = find.byKey(const Key('reset-ui-text-size'));
      await tester.scrollUntilVisible(reset, 300);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(c.scale, 1);
      expect(await const AppTextScaleService().load(), 1);
      final navContext = tester.element(find.byType(AppTextSizePage));
      c.preview(2.0);
      await tester.pumpAndSettle();
      showDialog<void>(
        context: navContext,
        builder: (context) => AlertDialog(
          title: const Text('字号对话框'),
          content: Text('正文随界面字号变化', key: const Key('scaled-dialog')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const Key('scaled-dialog'))),
        ).scale(14),
        closeTo(42, .001),
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      Navigator.of(navContext).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const PersonalizationSettingsPage(showLayoutSettings: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-text-size-preference')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
