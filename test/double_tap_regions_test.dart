import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/double_tap_regions_page.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/playback_preferences_service.dart';

/// 验证拖动、实时试用、完整保存和默认恢复共享同一配置。
void main() {
  testWidgets('触发区编辑可拖动试用保存并恢复默认', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const service = PlaybackPreferencesService();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const DoubleTapRegionsPage(
                    regions: DoubleTapRegions(),
                    service: service,
                  ),
                ),
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final initialWidth = tester
        .getSize(find.byKey(const Key('rewind-trigger-zone')))
        .width;
    await tester.drag(
      find.byKey(const Key('rewind-zone-handle')),
      const Offset(40, 0),
    );
    await tester.pump();
    final width = tester
        .getSize(find.byKey(const Key('rewind-trigger-zone')))
        .width;
    expect(width, greaterThan(initialWidth));
    final preview = tester.getRect(
      find.byKey(const Key('double-tap-region-preview')),
    );
    expect(preview, const Rect.fromLTWH(0, 0, 800, 600));
    expect(find.byType(Slider), findsNothing);
    final tap = Offset(preview.left + preview.width * 0.38, preview.center.dy);
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('快退 5 秒'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('zone-height-handle')),
      const Offset(0, 40),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-double-tap-regions')));
    await tester.pumpAndSettle();
    final saved = await service.load();
    expect(
      saved.doubleTapRegions.leftWidth,
      closeTo(width / preview.width, 0.001),
    );
    expect(saved.doubleTapRegions.height, lessThan(1));
    expect(saved.showPlaybackActionAnimation, isTrue);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('rewind-zone-handle')),
      const Offset(40, 0),
    );
    await tester.tap(find.byKey(const Key('reset-double-tap-regions')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-double-tap-regions')));
    await tester.pumpAndSettle();
    final defaults = await service.load();
    expect(defaults.doubleTapRegions.leftWidth, 0.35);
    expect(defaults.doubleTapRegions.height, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('沉浸触发区随浅深主题强调色变化且不缩小视口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final theme in [
      AppTheme.light(seedColor: Colors.green),
      AppTheme.dark(seedColor: Colors.orange),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const DoubleTapRegionsPage(
            regions: DoubleTapRegions(),
            service: PlaybackPreferencesService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const Key('double-tap-region-preview'))),
        const Rect.fromLTWH(0, 0, 640, 360),
      );
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('rewind-trigger-zone')))
            .color,
        theme.colorScheme.primary.withValues(alpha: 0.18),
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        theme.colorScheme.surface,
      );
      expect(find.byType(Slider), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
