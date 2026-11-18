import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'player_ab_repeat_test.dart' show AbOverlay, abVideo, unmountAb;
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class _AppVolumePlayback extends FeedbackPlayback {
  double volume = .18;

  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async =>
      SystemPlaybackLevels(brightness: 1, volume: volume);

  @override
  Future<void> setMediaVolume(double value) async => volume = value;
}

Future<void> _mountVolumePlayer(
  WidgetTester tester,
  _AppVolumePlayback playback,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: abVideo,
        appPlatform: AppPlatform.macos,
        playbackService: playback,
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: AbOverlay(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openVolumeSheet(WidgetTester tester) async {
  final entry = find.byKey(const Key('player-app-volume'));
  await tester.tap(entry, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

void main() {
  for (final reopenPlayer in [false, true]) {
    testWidgets(
      'macOS app volume mute preserves the audible level (reopen player=$reopenPlayer)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        const preferences = PlaybackPreferencesService();
        var playback = _AppVolumePlayback();
        await _mountVolumePlayer(tester, playback);
        await _openVolumeSheet(tester);
        await tester.tap(find.byTooltip('静音'), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(playback.volume, 0);
        expect((await preferences.load()).appVolume, 0);
        Navigator.of(tester.element(find.byTooltip('取消静音'))).pop();
        await tester.pumpAndSettle();

        if (reopenPlayer) {
          await unmountAb(tester);
          playback = _AppVolumePlayback()
            ..volume = (await preferences.load()).appVolume;
          await _mountVolumePlayer(tester, playback);
        }
        await _openVolumeSheet(tester);
        await tester.tap(find.byTooltip('取消静音'), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(playback.volume, closeTo(.18, .0001));
        expect((await preferences.load()).appVolume, closeTo(.18, .0001));
        await unmountAb(tester);
      },
    );
  }

  testWidgets('macOS app volume mute from older preferences resumes quietly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PlaybackPreferencesService.appVolumeKey: 0.0,
    });
    final playback = _AppVolumePlayback()..volume = 0;
    await _mountVolumePlayer(tester, playback);
    await _openVolumeSheet(tester);
    await tester.tap(find.byTooltip('取消静音'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(playback.volume, closeTo(.1, .0001));
    await unmountAb(tester);
  });
}
