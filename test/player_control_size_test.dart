import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/player_control_size_page.dart';
import 'package:focubili/features/player/widgets/player_control_widgets.dart';
import 'package:focubili/services/playback_preferences_service.dart';

/// 核验大比例下真实点击面积、窄屏换行和保存/默认恢复。
void main() {
  testWidgets('播放栏大小预览放大点击范围并保存恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const service = PlaybackPreferencesService();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push<double>(
                MaterialPageRoute(
                  builder: (context) =>
                      const PlayerControlSizePage(scale: 1, service: service),
                ),
              ),
              child: const Text('调整'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('调整'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('player-control-size-preview'))),
      const Rect.fromLTWH(0, 0, 800, 360),
    );
    final panel = tester.getRect(
      find.byKey(const Key('player-control-size-panel')),
    );
    expect(panel.center.dx, 400);
    expect(panel.center.dy, inInclusiveRange(100, 180));
    final initial = tester.getSize(
      find.byKey(const Key('preview-play-button')),
    );
    final scaleSlider = tester.widget<Slider>(
      find.byKey(const Key('player-control-size-slider')),
    );
    final sliderPosition = tester.getRect(
      find.byKey(const Key('player-control-size-slider')),
    );
    scaleSlider.onChanged!(2);
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(640, 360));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final trackCenter = tester
        .getRect(find.byType(PlayerProgressSlider))
        .center
        .dy;
    expect(
      tester.getRect(find.byKey(const Key('preview-lock-button'))).bottom,
      lessThan(trackCenter - 8),
    );
    expect(
      tester.getRect(find.byKey(const Key('preview-note-button'))).bottom,
      lessThan(trackCenter - 8),
    );
    expect(
      tester.getRect(find.byKey(const Key('player-control-size-slider'))).top,
      closeTo(sliderPosition.top, 0.1),
    );
    expect(
      tester.getSize(find.byKey(const Key('preview-play-button'))).width,
      closeTo(initial.width * 2, 0.1),
    );
    expect(
      tester.getRect(find.byKey(const Key('player-control-size-panel'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('preview-play-button'))).top,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(800, 360));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preview-play-button')));
    final rect = tester.getRect(find.byKey(const Key('preview-play-button')));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('preview-play-button')))
          .tooltip,
      '暂停预览',
    );
    await tester.tap(find.byKey(const Key('save-player-control-size')));
    await tester.pumpAndSettle();
    expect((await service.load()).controlScale, 2);
    await tester.tap(find.text('调整'));
    await tester.pumpAndSettle();
    tester
        .widget<Slider>(find.byKey(const Key('player-control-size-slider')))
        .onChanged!(2);
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('reset-player-control-size')),
    );
    await tester.tap(find.byKey(const Key('reset-player-control-size')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-player-control-size')));
    await tester.pumpAndSettle();
    expect((await service.load()).controlScale, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
