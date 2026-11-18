import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/playback_mode.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, unmountAb, menu;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

final _trigger = find.byKey(const Key('more-settings-menu'));
final _panel = find.byKey(const Key('player-tools-panel'));
final _close = find.byKey(const Key('player-tools-close'));
final _listening = find.byKey(const Key('listening-menu-item'));

class _CountPlayback extends AbPlayback {
  final listeningRequests = <bool>[];
  @override
  Future<void> setAudioOnly(bool enabled) async {
    listeningRequests.add(enabled);
    await super.setAudioOnly(enabled);
  }
}

class _GatedModePrefs extends PlaybackPreferencesService {
  final gate = Completer<void>();
  final writes = <PlaybackMode>[];

  @override
  Future<void> saveMode(PlaybackMode mode) async {
    writes.add(mode);
    await gate.future;
    await super.saveMode(mode);
  }
}

SemanticsProperties _toolSemantics(WidgetTester tester, Finder finder) => tester
    .widget<Semantics>(
      find.descendant(of: finder, matching: find.byType(Semantics)).first,
    )
    .properties;

Future<void> _mountTools(
  WidgetTester t,
  AbPlayback playback, {
  Size size = const Size(390, 844),
  AppPlatform platform = AppPlatform.android,
  double textScale = 1,
  PlaybackPreferencesService? preferences,
  bool reduceMotion = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: PlayerPage(
        video: abVideo,
        playbackService: playback,
        appPlatform: platform,
        playbackPreferencesService: preferences,
        playerOverlayService: AbOverlay(),
        offlineVideoService: ReviewOfflineLibrary(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

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
      expect(_panel, findsOneWidget);
      if (v.$1.width < 560) {
        final closeCenter = t.getCenter(_close);
        expect(closeCenter.dy, greaterThan(v.$1.height * .12));
        expect(closeCenter.dx, lessThan(v.$1.width - 10));
      }
      expect(
        t.getTopLeft(find.byKey(const Key('listening-menu-item'))).dy,
        lessThan(t.getTopLeft(find.byKey(const Key('player-block-video'))).dy),
      );
      final creator = find.byKey(const Key('player-block-creator'));
      await t.ensureVisible(creator);
      final creatorSemantics = t.widget<Semantics>(
        find.descendant(of: creator, matching: find.byType(Semantics)).first,
      );
      expect(creatorSemantics.properties.enabled, isFalse);
      expect(creatorSemantics.properties.value, '未取得 UP 主信息');
      expect(creatorSemantics.properties.onTap, isNull);
      await t.ensureVisible(find.byKey(const Key('player-subtitle-menu-item')));
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

  testWidgets('keyboard focus is contained, restores and keeps full screen', (
    t,
  ) async {
    final playback = _CountPlayback();
    await _mountTools(
      t,
      playback,
      size: const Size(1280, 800),
      platform: AppPlatform.windows,
      reduceMotion: true,
    );
    await t.tap(find.byTooltip('进入全屏'));
    await t.pumpAndSettle();
    final trigger = t.widget<IconButton>(_trigger).focusNode!;
    trigger.requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();

    expect(_panel, findsOneWidget);
    expect(t.getCenter(_close).dx, greaterThan(1100));
    final closeButton = t.widget<IconButton>(_close);
    final dialog = t.widget<Dialog>(_panel);
    expect(
      FocusManager.instance.primaryFocus!.context!
          .findAncestorWidgetOfExactType<IconButton>(),
      same(closeButton),
    );
    for (var i = 0; i < 16; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<Dialog>(),
        same(dialog),
      );
    }
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    expect(trigger.hasFocus, isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(trigger.hasPrimaryFocus, isTrue);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(playback.plays, 0);
    expect(playback.pauses, 0);
    expect(playback.seeks, isEmpty);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(playback.listeningRequests, [true]);
    expect(_panel, findsNothing);
    await unmountAb(t);
  });

  testWidgets('mobile landscape 200% retains close, scrolling and fit state', (
    t,
  ) async {
    final playback = AbPlayback();
    final semantics = t.ensureSemantics();
    await _mountTools(t, playback, size: const Size(680, 320), textScale: 2);
    await t.tap(_trigger, kind: PointerDeviceKind.touch);
    await t.pumpAndSettle();
    final closePosition = t.getCenter(_close);
    expect(closePosition.dx, greaterThan(545));
    final contain = find.byKey(const Key('video-fit-mode-contain'));
    final cover = find.byKey(const Key('video-fit-mode-cover'));
    await t.ensureVisible(contain);
    await t.pumpAndSettle();
    expect(_toolSemantics(t, contain).selected, isTrue);
    expect(_toolSemantics(t, contain).inMutuallyExclusiveGroup, isTrue);
    expect(_toolSemantics(t, cover).selected, isFalse);
    await t.ensureVisible(cover);
    await t.pumpAndSettle();
    expect(t.getCenter(_close), closePosition);
    expect(cover.hitTestable(), findsOneWidget);
    await t.tap(cover);
    await t.pumpAndSettle();
    await t.tap(_trigger);
    await t.pumpAndSettle();
    await t.ensureVisible(cover);
    await t.pumpAndSettle();
    expect(_toolSemantics(t, cover).selected, isTrue);
    expect(_toolSemantics(t, contain).selected, isFalse);
    await t.tap(_close);
    await t.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(t.takeException(), isNull);
    semantics.dispose();
    await unmountAb(t);
  });

  testWidgets('touch scrolling and rotation leave the same panel open', (
    t,
  ) async {
    final playback = AbPlayback();
    await _mountTools(t, playback, size: const Size(320, 650), textScale: 2.4);
    await t.tap(_trigger, kind: PointerDeviceKind.touch);
    await t.pumpAndSettle();
    final list = find.byKey(const Key('player-tools-scroll'));
    final manage = find.byKey(const Key('player-manage-blocklist'));
    expect(manage.hitTestable(), findsNothing);
    final origin = t.getCenter(_close);
    for (var i = 0; i < 5 && manage.hitTestable().evaluate().isEmpty; i++) {
      await t.drag(list, const Offset(0, -420), kind: PointerDeviceKind.touch);
      await t.pumpAndSettle();
    }
    expect(manage.hitTestable(), findsOneWidget);
    expect(t.getCenter(_close), origin);
    t.view.physicalSize = const Size(680, 320);
    await t.pumpAndSettle();
    expect(_panel, findsOneWidget);
    expect(t.getCenter(_close).dx, greaterThan(545));
    await t.ensureVisible(manage);
    await t.pumpAndSettle();
    expect(manage.hitTestable(), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(playback.pauses, 0);
    expect(playback.seeks, isEmpty);
    expect(t.takeException(), isNull);
    await unmountAb(t);
  });

  testWidgets('loading and switching update; double taps dispatch only once', (
    t,
  ) async {
    final playback = _CountPlayback();
    await _mountTools(t, playback);
    playback.at(20, phase: PlaybackPhase.loading, playing: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 220));
    final triggerPoint = t.getCenter(_trigger);
    await t.tapAt(triggerPoint);
    await t.tapAt(triggerPoint);
    await t.pump();
    await t.pump(const Duration(milliseconds: 220));
    expect(_panel, findsOneWidget);
    expect(_toolSemantics(t, _listening).enabled, isFalse);
    expect(_toolSemantics(t, _listening).value, '等待视频加载');
    await t.tap(_listening);
    await t.pump();
    await t.pump(const Duration(milliseconds: 220));
    expect(playback.listeningRequests, isEmpty);
    expect(_panel, findsOneWidget);

    playback.at(20);
    await t.pumpAndSettle();
    expect(_toolSemantics(t, _listening).enabled, isTrue);
    final row = t.getCenter(_listening);
    playback.modeGate = Completer<void>();
    await t.tapAt(row);
    await t.tapAt(row);
    await t.pump();
    await t.pump(const Duration(milliseconds: 220));
    expect(_panel, findsNothing);
    expect(playback.listeningRequests, [true]);

    await t.tap(_trigger);
    await t.pump();
    await t.pump(const Duration(milliseconds: 220));
    expect(_toolSemantics(t, _listening).enabled, isFalse);
    expect(_toolSemantics(t, _listening).value, '正在切换');
    playback.modeGate!.complete();
    await t.pumpAndSettle();
    expect(_toolSemantics(t, _listening).label, '返回看视频');
    expect(_toolSemantics(t, _listening).value, '仅音频');
    expect(playback.listeningRequests, [true]);
    await t.tap(_close);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await unmountAb(t);
  });

  testWidgets(
    'loop stays disabled while saving and reflects the persisted mode',
    (t) async {
      final playback = AbPlayback();
      final preferences = _GatedModePrefs();
      await _mountTools(t, playback, preferences: preferences);
      final loop = find.byKey(const Key('playback-loop-menu-item'));
      await menu(t, 'playback-loop-menu-item');
      expect(preferences.writes, [PlaybackMode.single]);
      await t.tap(_trigger);
      await t.pumpAndSettle();
      await t.ensureVisible(loop);
      await t.pumpAndSettle();
      expect(_toolSemantics(t, loop).enabled, isFalse);
      expect(_toolSemantics(t, loop).value, '正在保存');
      await t.tap(loop);
      await t.pumpAndSettle();
      expect(preferences.writes, [PlaybackMode.single]);
      preferences.gate.complete();
      await t.pumpAndSettle();
      expect(_toolSemantics(t, loop).toggled, isTrue);
      expect(_toolSemantics(t, loop).value, '已开启');
      expect(
        _toolSemantics(
          t,
          find.byKey(const Key('playback-playlist-menu-item')),
        ).value,
        '单项循环',
      );
      await t.tap(_close);
      await t.pumpAndSettle();
      await unmountAb(t);
    },
  );

  testWidgets(
    'playback continues under tools; a new part invalidates old actions',
    (t) async {
      final playback = _CountPlayback();
      await _mountTools(t, playback);
      await t.tap(_trigger);
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      expect(_panel, findsOneWidget);
      expect(playback.current.isPlaying, isTrue);
      expect(playback.pauses, 0);
      final oldAction = _toolSemantics(t, _listening).onTap!;
      playback.at(120, playing: false, phase: PlaybackPhase.ended);
      await t.pumpAndSettle();
      expect(playback.currentCid, 102);
      expect(find.text('播放内容已切换，请重新打开功能列表。'), findsOneWidget);
      expect(_listening, findsNothing);
      // Even a buffered click from the old row cannot act on the new part.
      oldAction();
      await t.pumpAndSettle();
      expect(playback.listeningRequests, isEmpty);
      expect(_trigger.hitTestable(), findsOneWidget);
      await t.tap(_trigger);
      await t.pumpAndSettle();
      expect(_listening, findsOneWidget);
      await unmountAb(t);
    },
  );

  testWidgets(
    'tapping the backdrop dismisses without forwarding video gestures',
    (t) async {
      final playback = AbPlayback();
      await _mountTools(t, playback);
      await t.tap(_trigger);
      await t.pumpAndSettle();
      final video = t.getRect(find.byKey(const Key('player-surface')).first);
      await t.tapAt(Offset(video.center.dx, video.top + 18));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 350));
      expect(_panel, findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(playback.pauses, 0);
      expect(playback.seeks, isEmpty);
      await unmountAb(t);
    },
  );
}
