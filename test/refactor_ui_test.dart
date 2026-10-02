import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_folder_card.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/player_route_session.dart';
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

/// Captures generated widget renderings when explicitly requested, without committing outputs.
Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_REFACTOR_UI')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/ui-verification').create(recursive: true);
      await File(
        'build/ui-verification/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// Models a native owner so pause leases can be verified through the real player page.
class OwnedPlayback extends ReviewLocalPlayback {
  int initializationCount = 0;

  /// Records platform acquisition so a late old initializer cannot pass unnoticed.
  @override
  Future<int?> initialize() async {
    initializationCount++;
    return 1;
  }

  /// Keeps platform ownership deterministic without invoking Android.
  @override
  bool get ownsPlatformChannel => true;
}

/// Delays startup before native acquisition to reproduce an external-link race.
class PendingPlaybackPreferences extends PlaybackPreferencesService {
  final pending = Completer<PlaybackPreferences>();

  /// Completes only when the test releases the original player's startup.
  @override
  Future<PlaybackPreferences> load() => pending.future;
}

/// Exercises narrow and desktop layouts plus player route and mouse interactions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'suspended startup cannot acquire the native channel after a newer player opens',
    (tester) async {
      final navigation = GlobalKey<NavigatorState>();
      final oldBackend = OwnedPlayback();
      final newBackend = OwnedPlayback();
      final preferences = PendingPlaybackPreferences();
      final video = ReviewOfflineLibrary.record.toPreview();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigation,
          home: PlayerPage(
            video: video,
            forceOffline: true,
            playbackService: oldBackend,
            playbackPreferencesService: preferences,
            offlineVideoService: ReviewOfflineLibrary(),
          ),
        ),
      );
      await tester.pump();
      final suspended = await PlayerRouteSession.suspendCurrent();
      unawaited(
        navigation.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              video: video,
              forceOffline: true,
              playbackService: newBackend,
              offlineVideoService: ReviewOfflineLibrary(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(newBackend.initializationCount, 1);
      preferences.pending.complete(const PlaybackPreferences());
      await tester.pumpAndSettle();
      expect(oldBackend.initializationCount, 0);
      expect(oldBackend.localOpened, isFalse);
      expect(newBackend.localOpened, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await suspended!.restoreIfAttached();
    },
  );

  testWidgets('settings and local folders fit mobile and desktop', (
    tester,
  ) async {
    for (final size in [const Size(320, 850), const Size(1280, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (const bool.fromEnvironment('CAPTURE_REFACTOR_UI')) {
        await tester.runAsync(() async {
          final font = File('C:/Windows/Fonts/msyh.ttc');
          if (await font.exists()) {
            final loader = FontLoader('ReviewUI')
              ..addFont(
                font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
              );
            await loader.load();
          }
          final icons = File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          );
          if (await icons.exists()) {
            final loader = FontLoader('MaterialIcons')
              ..addFont(
                icons.readAsBytes().then(
                  (bytes) => ByteData.sublistView(bytes),
                ),
              );
            await loader.load();
          }
        });
      }
      final theme = AppTheme.light();
      final renderedTheme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'ReviewUI'),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: renderedTheme,
            home: const PersonalizationSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('settings-search')), '倍速');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('playback-speeds-preference')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'settings-${size.width.toInt()}');

      final service = AppFavoritesService();
      final folder = await service.createFolder('中文课程收藏夹');
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: renderedTheme,
            home: AppFavoriteFoldersPage(favoritesService: service),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(size.width < 520 ? 1.8 : 1),
              ),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteFolderCard), findsOneWidget);
      expect(find.byTooltip('管理收藏夹'), findsOneWidget);
      expect(find.text('从 B 站导入'), findsOneWidget);
      if (size.width < 520) {
        expect(
          tester
              .getTopLeft(find.byKey(const Key('import-bilibili-favorites')))
              .dy,
          greaterThan(tester.getBottomRight(find.byType(AppBar)).dy),
        );
      }
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'favorites-${size.width.toInt()}');
      await tester.tap(find.byKey(Key('app-favorite-actions-${folder!.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('rename-app-favorite-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app-favorite-folder-name-input')),
        '重命名后的课程',
      );
      await tester.tap(
        find.byKey(const Key('confirm-app-favorite-folder-name')),
      );
      await tester.pumpAndSettle();
      expect(find.text('重命名后的课程'), findsOneWidget);
      await tester.tap(find.byKey(Key('app-favorite-actions-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('delete-app-favorite-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(await service.loadFolders(), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'player actions align and mouse drags collection while external navigation pauses',
    (tester) async {
      tester.view.physicalSize = const Size(360, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final record = ReviewOfflineLibrary.record;
      final service = OwnedPlayback();
      final key = GlobalKey();
      final video = VideoPreview(
        bvid: record.bvid,
        cid: record.cid,
        title: '离线课程',
        ownerName: 'UP',
        parts: record.toPreview().parts,
        collection: VideoCollection(
          id: 1,
          title: '课程合集',
          totalCount: 8,
          entries: List.generate(
            8,
            (index) => VideoCollectionEntry(
              bvid: 'BV1GJ411x7h$index',
              cid: index + 1,
              title: '第 $index 节课',
              thumbnailUrl: '',
              duration: const Duration(minutes: 2),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'ReviewUI',
              ),
            ),
            home: PlayerPage(
              video: video,
              forceOffline: true,
              playbackService: service,
              offlineVideoService: ReviewOfflineLibrary(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final names = [
        'current-video-learning-list-button',
        'current-video-offline-download-button',
        'current-video-app-favorite-button',
        'portrait-note-button',
      ];
      final rects = names
          .map((name) => tester.getRect(find.byKey(Key(name))))
          .toList();
      for (final rect in rects) {
        expect(rect.top, closeTo(rects.first.top, 0.1));
        expect(rect.width, closeTo(rects.first.width, 0.1));
      }
      await capture(tester, key, 'player-actions');
      expect(tester.takeException(), isNull);
      final strip = find.byKey(const Key('collection-preview-list'));
      await tester.ensureVisible(strip);
      await tester.pumpAndSettle();
      final state = tester.state<ScrollableState>(
        find.descendant(of: strip, matching: find.byType(Scrollable)).first,
      );
      await tester.drag(
        strip,
        const Offset(-220, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      final lease = await PlayerRouteSession.suspendCurrent();
      expect(service.paused, isTrue);
      await lease!.restoreIfAttached();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await PlayerRouteSession.suspendCurrent(), isNull);
    },
  );
}
