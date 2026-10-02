import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/app_theme_mode_controller.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/services/app_theme_mode_service.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

/// Models Windows, where a Widget surface replaces an Android texture ID.
class WidgetSurfacePlayback extends ReviewLocalPlayback
    implements PlaybackVideoSurface {
  /// Windows initialization does not need to provide an Android Texture.
  @override
  Future<int?> initialize() async => null;

  /// Provides a deterministic test surface instead of loading native mpv.
  @override
  Widget buildVideoSurface() =>
      const ColoredBox(key: Key('review-windows-surface'), color: Colors.black);
}

/// Rejects color persistence to exercise optimistic rollback.
class FailingColorService extends AppThemeModeService {
  /// Simulates a rejected preference write.
  @override
  Future<void> saveColor(Color color) async => throw StateError('rejected');
}

/// Tests persisted color changes, safe failures, and the desktop offline surface contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Isolates every test from production preferences.
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('accent color restores after reopening and resets to default', () async {
    final controller = AppThemeModeController();
    final restored = AppThemeModeController();
    addTearDown(controller.dispose);
    addTearDown(restored.dispose);
    await controller.initialize();
    expect(await controller.setSeedColor(Colors.pink), isTrue);
    await restored.initialize();
    expect(restored.seedColor.toARGB32(), Colors.pink.toARGB32());
    expect(await restored.resetSeedColor(), isTrue);
    expect(restored.seedColor.toARGB32(), defaultThemeSeedColorValue);
  });
  test('failed accent write rolls back to the previous color', () async {
    final controller = AppThemeModeController(service: FailingColorService());
    addTearDown(controller.dispose);
    await controller.initialize();
    final before = controller.seedColor;
    expect(await controller.setSeedColor(Colors.pink), isFalse);
    expect(controller.seedColor, before);
  });
  testWidgets('offline Windows surface works without a texture identifier', (
    tester,
  ) async {
    final service = WidgetSurfacePlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: ReviewOfflineLibrary.record.toPreview(),
          forceOffline: true,
          offlineVideoService: ReviewOfflineLibrary(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-windows-surface')), findsOneWidget);
    expect(service.localOpened, isTrue);
    expect(find.byKey(const Key('play-pause-button')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'malformed favorites are not overwritten and the queue recovers',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_favorites.folders_v1', 'broken');
      final service = AppFavoritesService();
      await expectLater(service.createFolder('One'), throwsFormatException);
      expect(prefs.getString('app_favorites.folders_v1'), 'broken');
      await prefs.remove('app_favorites.folders_v1');
      expect(await service.createFolder('Two'), isNotNull);
    },
  );
}
