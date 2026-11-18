import 'dart:io';
import 'dart:ui' as ui;

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_ab_repeat_sheet.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart'
    show AbOverlay, AbPlayback, abVideo, menu, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _captureKey = Key('ab-repeat-capture');
final _sheet = find.byType(PlayerAbRepeatSheet);
final _editor = find.byKey(const Key('ab-repeat-floating-editor'));
final _viewport = find.byKey(const Key('player-feedback-viewport'));
final _grip = find.byKey(const Key('ab-repeat-move-handle'));
final _a = find.byKey(const Key('ab-repeat-A-input'));
final _b = find.byKey(const Key('ab-repeat-B-input'));
final _edit = find.byTooltip('输入时间');
final _apply = find.byKey(const Key('ab-repeat-apply'));

Future<void> _mount(
  WidgetTester t,
  AbPlayback p, {
  AppPlatform platform = AppPlatform.windows,
  Size screen = const Size(1152, 720),
  double textScale = 1,
  String? font,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = screen;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: font),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PlayerPage(
          video: abVideo,
          playbackService: p,
          appPlatform: platform,
          initialPosition: const Duration(seconds: 20),
          offlineVideoService: ReviewOfflineLibrary(),
          playerOverlayService: AbOverlay(),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _fullscreen(WidgetTester t) async {
  await t.tap(find.byTooltip('进入全屏'));
  await t.pumpAndSettle();
}

Future<void> _open(WidgetTester t) => menu(t, 'ab-repeat-menu-item');

Future<void> _toggleTimes(WidgetTester t) async {
  await t.ensureVisible(_edit);
  await t.tap(_edit);
  await t.pumpAndSettle();
}

Future<void> _drag(
  WidgetTester t,
  Offset delta, {
  required PointerDeviceKind kind,
}) async {
  final g = await t.startGesture(t.getCenter(_grip), kind: kind);
  await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await g.moveBy(delta);
  await t.pump();
  await g.up();
  await t.pumpAndSettle();
}

void _fits(Rect inside, Rect outside) {
  expect(inside.left, greaterThanOrEqualTo(outside.left - .1));
  expect(inside.top, greaterThanOrEqualTo(outside.top - .1));
  expect(inside.right, lessThanOrEqualTo(outside.right + .1));
  expect(inside.bottom, lessThanOrEqualTo(outside.bottom + .1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'time fields expand down, keeping the narrow toolbar width and top',
    (t) async {
      final p = AbPlayback();
      await _mount(t, p);
      await _fullscreen(t);
      await _open(t);
      final before = t.getRect(_sheet);
      await _toggleTimes(t);
      final after = t.getRect(_sheet);
      expect(
        after.width,
        closeTo(before.width, .1),
        reason: 'toolbar width changed from ${before.width} to ${after.width}',
      );
      expect(after.left, closeTo(before.left, .1));
      expect(after.top, closeTo(before.top, .1));
      expect(after.height, greaterThan(before.height));
      expect(_a, findsOneWidget);
      expect(_b, findsOneWidget);
      expect(
        find.descendant(of: _sheet, matching: find.byIcon(Icons.info_outline)),
        findsNothing,
      );
      expect(
        find.descendant(of: _apply, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      expect(find.byTooltip('启用区间循环'), findsOneWidget);
      await unmountAb(t);
    },
  );

  for (final (platform, kind) in [
    (AppPlatform.windows, PointerDeviceKind.mouse),
    (AppPlatform.android, PointerDeviceKind.touch),
  ]) {
    testWidgets(
      '${kind.name}: only the fullscreen grip moves the panel; bounds and draft survive',
      (t) async {
        final p = AbPlayback();
        await _mount(t, p, platform: platform, textScale: 1.5);
        await _fullscreen(t);
        await _open(t);
        expect(_grip, findsOneWidget);
        final before = t.getRect(_editor);
        expect(t.getCenter(_grip).dx, greaterThan(before.center.dx));

        // Moving before a long press does not accidentally move the editor.
        final short = await t.startGesture(t.getCenter(_grip), kind: kind);
        await short.moveBy(const Offset(60, 35));
        await short.up();
        await t.pumpAndSettle();
        expect(t.getRect(_editor).topLeft, before.topLeft);

        await _drag(t, const Offset(-1000, 800), kind: kind);
        final moved = t.getRect(_editor);
        final lane = t.getRect(_viewport);
        expect(moved.left, closeTo(lane.left, .1));
        expect(moved.top, greaterThan(before.top));
        _fits(moved, lane);
        expect(p.seeks, isEmpty);
        expect(p.pauses, 0);

        await _toggleTimes(t);
        final expanded = t.getRect(_editor);
        expect(
          expanded.topLeft,
          moved.topLeft,
          reason: 'edit stays pinned at the grip',
        );
        expect(expanded.width, moved.width);
        _fits(expanded, t.getRect(_viewport));
        await t.ensureVisible(_a);
        await t.enterText(_a, '00:22.500');
        await t.ensureVisible(_b);
        await t.enterText(_b, '00:35');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(_grip, findsNothing);
        await _open(t);
        expect(t.getRect(_editor).topLeft, moved.topLeft);
        await _toggleTimes(t);
        expect(t.widget<TextField>(_a).controller!.text, '00:22.500');
        expect(t.widget<TextField>(_b).controller!.text, '00:35');
        expect(p.seeks, isEmpty);
        expect(t.takeException(), isNull);
        await unmountAb(t);
      },
    );
  }

  testWidgets('keyboard grip arrows move the fullscreen card, not playback', (
    t,
  ) async {
    final p = AbPlayback();
    await _mount(t, p, platform: AppPlatform.macos);
    await _fullscreen(t);
    await _open(t);
    expect(_grip, findsOneWidget);
    final before = t.getRect(_editor);
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    expect(find.bySemanticsLabel('移动 A–B 控件'), findsOneWidget);
    await t.tap(_grip);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    final moved = t.getRect(_editor);
    expect(moved.topLeft, before.topLeft + const Offset(24, 24));
    expect(p.seeks, isEmpty);
    expect(p.pauses, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(_grip, findsNothing);
    await unmountAb(t);
  });

  testWidgets(
    'narrow portrait keeps the accessible editor by the timeline with no floating grip',
    (t) async {
      final p = AbPlayback();
      await _mount(
        t,
        p,
        platform: AppPlatform.android,
        screen: const Size(320, 680),
        textScale: 1.8,
      );
      await _open(t);
      final before = t.getRect(_sheet);
      final slider = find.byKey(const Key('player-progress-slider'));
      expect(before.top, greaterThan(t.getRect(slider).bottom));
      expect(_grip, findsNothing);
      await _toggleTimes(t);
      final after = t.getRect(_sheet);
      expect(after.width, closeTo(before.width, .1));
      expect(after.height, greaterThan(before.height));
      expect(after.right, lessThanOrEqualTo(320));
      await t.ensureVisible(_a);
      expect(_a.hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await unmountAb(t);
    },
  );

  final evidenceDir = Platform.environment['FOCUBILI_AB_EVIDENCE'];
  testWidgets(
    'capture the same actual Flutter fullscreen editor in both states',
    (t) async {
      final font = Platform.environment['FOCUBILI_DESKTOP_INPUT_FONT'];
      final icons = Platform.environment['FOCUBILI_DESKTOP_INPUT_ICON_FONT'];
      await t.runAsync(() async {
        for (final (file, family) in [
          (font, 'AbEvidence'),
          (icons, 'MaterialIcons'),
        ]) {
          if (file == null) continue;
          final bytes = await File(file).readAsBytes();
          await (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
      Future<void> capture(String name) async {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          image.dispose();
          await File(
            '$evidenceDir/$name.png',
          ).writeAsBytes(png.buffer.asUint8List());
        });
      }

      await _mount(t, AbPlayback(), font: font == null ? null : 'AbEvidence');
      await _fullscreen(t);
      await _open(t);
      await capture('compact');
      await _toggleTimes(t);
      await capture('expanded');
      if (_grip.evaluate().isNotEmpty) {
        await _drag(t, const Offset(240, 160), kind: PointerDeviceKind.mouse);
        await capture('moved');
      }
      await unmountAb(t);
    },
    skip: evidenceDir == null,
  );
}
