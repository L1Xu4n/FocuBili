import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, unmountAb, menu;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

void main() {
  for (final v in [
    (const Size(390, 844), 1.0, false, 'phone'),
    (const Size(320, 640), 2.0, true, 'compact'),
    (const Size(320, 640), 2.4, true, 'largest'),
    (const Size(1280, 900), 1.0, false, 'desktop'),
  ]) {
    testWidgets('学习菜单优先且重复打开、关闭、屏蔽撤销不误退播放器 ${v.$4}', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = v.$1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final p = AbPlayback();
      final theme = v.$3 ? AppTheme.dark() : AppTheme.light();
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(v.$2)),
            child: w!,
          ),
          home: PlayerPage(
            video: abVideo,
            playbackService: p,
            playerOverlayService: AbOverlay(),
            offlineVideoService: ReviewOfflineLibrary(),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const Key('more-settings-menu')));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(
        t.getTopLeft(find.byKey(const Key('listening-menu-item'))).dy,
        lessThan(t.getTopLeft(find.byKey(const Key('player-block-video'))).dy),
      );
      final creator = t.widget<PopupMenuItem<dynamic>>(
        find.byKey(const Key('player-block-creator')),
      );
      expect(creator.enabled, isFalse);
      await t.tap(find.text('字幕').last);
      await t.pumpAndSettle();
      expect(find.byType(PlayerSubtitleSheet), findsOneWidget);
      await t.tap(find.byTooltip('关闭字幕设置'));
      await t.pumpAndSettle();
      expect(find.byType(PlayerSubtitleSheet), findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      await menu(t, 'listening-menu-item');
      expect(p.current.audioOnly, isTrue);
      await menu(t, 'listening-menu-item');
      expect(p.current.audioOnly, isFalse);
      await menu(t, 'player-block-video');
      expect(
        (await const ContentBlocklistService().load()).videos,
        contains(abVideo.bvid),
      );
      await t.tap(find.text('撤销'));
      await t.pumpAndSettle();
      expect((await const ContentBlocklistService().load()).videos, isEmpty);
      await t.tap(find.byKey(const Key('more-settings-menu')));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('listening-menu-item')), findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      await t.tap(find.byKey(const Key('more-settings-menu')));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.byKey(const Key('listening-menu-item')), findsNothing);
      expect(t.takeException(), isNull);

      await unmountAb(t);
    });
  }
}
