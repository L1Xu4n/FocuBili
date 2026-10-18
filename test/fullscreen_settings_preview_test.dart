import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/double_tap_regions_page.dart';
import 'package:focubili/features/profile/fullscreen_settings_preview.dart';
import 'package:focubili/features/profile/player_control_size_page.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/app_layout_preferences_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _landscape = [
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.landscapeRight',
];
const _portrait = ['DeviceOrientation.portraitUp'];

List<List<String>> _orientations(List<MethodCall> calls) => [
  for (final call in calls)
    if (call.method == 'SystemChrome.setPreferredOrientations')
      List<String>.from(call.arguments as List),
];

List<Object?> _uiModes(List<MethodCall> calls) => [
  for (final call in calls)
    if (call.method == 'SystemChrome.setEnabledSystemUIMode') call.arguments,
];

void _view(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          host = context;
          return const Scaffold(body: Text('host'));
        },
      ),
    ),
  );
  return host;
}

class _FailingPreferences extends PlaybackPreferencesService {
  @override
  Future<void> saveDoubleTapRegions(DoubleTapRegions regions) async =>
      throw StateError('synthetic save failure');
  @override
  Future<void> saveControlScale(double scale) async =>
      throw StateError('synthetic save failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final systemCalls = <MethodCall>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutPreferencesService.activeMode = AppLayoutMode.adaptive;
    systemCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          systemCalls.add(call);
          return null;
        });
  });
  tearDown(() {
    AppLayoutPreferencesService.activeMode = AppLayoutMode.adaptive;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final platform in [AppPlatform.android, AppPlatform.ios]) {
    for (final device in [
      (name: 'phone portrait', size: const Size(390, 844), adaptive: _portrait),
      (
        name: 'phone landscape',
        size: const Size(844, 390),
        adaptive: _portrait,
      ),
      (
        name: 'tablet portrait',
        size: const Size(800, 1280),
        adaptive: _landscape,
      ),
      (
        name: 'tablet landscape',
        size: const Size(1280, 800),
        adaptive: _landscape,
      ),
    ]) {
      for (final mode in AppLayoutMode.values) {
        testWidgets(
          '${platform.name} ${device.name} ${mode.name} preview cancel restores policy',
          (tester) async {
            _view(tester, device.size);
            AppLayoutPreferencesService.activeMode = mode;
            final context = await _host(tester);
            final pending = showFullscreenSettingsPreview<Object>(
              context: context,
              platform: platform,
              builder: (_) => const Scaffold(body: Text('preview')),
            );
            await tester.pumpAndSettle();
            expect(find.text('preview'), findsOneWidget);
            expect(_orientations(systemCalls), [_landscape]);
            Navigator.of(context).pop();
            await tester.pumpAndSettle();
            expect(await pending, isNull);
            final expected = switch (mode) {
              AppLayoutMode.adaptive => device.adaptive,
              AppLayoutMode.landscape => _landscape,
              AppLayoutMode.portrait => _portrait,
            };
            expect(_orientations(systemCalls), [_landscape, expected]);
            expect(_uiModes(systemCalls), [
              'SystemUiMode.immersiveSticky',
              'SystemUiMode.edgeToEdge',
            ]);
          },
        );
      }
    }

    for (final failingMethod in [
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
    ]) {
      testWidgets(
        '${platform.name} restores policy after $failingMethod entry failure',
        (tester) async {
          _view(tester, const Size(1280, 800));
          AppLayoutPreferencesService.activeMode = AppLayoutMode.portrait;
          final context = await _host(tester);
          var failed = false;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                systemCalls.add(call);
                if (!failed && call.method == failingMethod) {
                  failed = true;
                  throw PlatformException(code: 'synthetic_entry_failure');
                }
                return null;
              });
          final pending = showFullscreenSettingsPreview<Object>(
            context: context,
            platform: platform,
            builder: (_) => const Scaffold(body: Text('preview')),
          );
          final failure = expectLater(
            pending,
            throwsA(isA<PlatformException>()),
          );
          await tester.pumpAndSettle();
          await failure;
          expect(find.text('preview'), findsNothing);
          expect(_orientations(systemCalls), [_landscape, _portrait]);
          expect(_uiModes(systemCalls).last, 'SystemUiMode.edgeToEdge');
        },
      );
    }

    testWidgets('${platform.name} restores when host unmounts during entry', (
      tester,
    ) async {
      _view(tester, const Size(844, 390));
      AppLayoutPreferencesService.activeMode = AppLayoutMode.portrait;
      final context = await _host(tester);
      final ready = Completer<void>();
      var held = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            systemCalls.add(call);
            if (!held &&
                call.method == 'SystemChrome.setPreferredOrientations') {
              held = true;
              await ready.future;
            }
            return null;
          });
      final pending = showFullscreenSettingsPreview<Object>(
        context: context,
        platform: platform,
        builder: (_) => const Scaffold(body: Text('preview')),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      ready.complete();
      await tester.pumpAndSettle();
      expect(await pending, isNull);
      expect(_orientations(systemCalls), [_landscape, _portrait]);
      expect(_uiModes(systemCalls).last, 'SystemUiMode.edgeToEdge');
    });
  }

  for (final editor in ['double tap', 'control size']) {
    for (final fails in [false, true]) {
      testWidgets(
        'ios $editor editor restores after ${fails ? 'save failure and cancel' : 'save'}',
        (tester) async {
          _view(tester, const Size(844, 390));
          AppLayoutPreferencesService.activeMode = AppLayoutMode.portrait;
          final context = await _host(tester);
          final service = fails
              ? _FailingPreferences()
              : const PlaybackPreferencesService();
          final Future<Object?> pending;
          final Key save;
          if (editor == 'double tap') {
            pending = showDoubleTapRegionsEditor(
              context: context,
              regions: const DoubleTapRegions(),
              service: service,
              platform: AppPlatform.ios,
            );
            save = const Key('save-double-tap-regions');
          } else {
            pending = showPlayerControlSizeEditor(
              context: context,
              scale: 1,
              service: service,
              platform: AppPlatform.ios,
            );
            save = const Key('save-player-control-size');
          }
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byKey(save));
          await tester.tap(find.byKey(save));
          await tester.pumpAndSettle();
          if (fails) {
            expect(find.byKey(save), findsOneWidget);
            expect(_orientations(systemCalls), [_landscape]);
            Navigator.of(context).pop();
            await tester.pumpAndSettle();
            expect(await pending, isNull);
          } else {
            expect(
              await pending,
              editor == 'double tap' ? isA<DoubleTapRegions>() : 1,
            );
          }
          expect(_orientations(systemCalls), [_landscape, _portrait]);
          expect(_uiModes(systemCalls).last, 'SystemUiMode.edgeToEdge');
        },
      );
    }
  }

  for (final platform in [
    AppPlatform.windows,
    AppPlatform.macos,
    AppPlatform.linux,
  ]) {
    for (final wasFullscreen in [false, true]) {
      testWidgets(
        '${platform.name} retains desktop window restoration from fullscreen=$wasFullscreen',
        (tester) async {
          final windowCalls = <MethodCall>[];
          const channel = MethodChannel('window_manager');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                windowCalls.add(call);
                if (call.method == 'isFullScreen') return wasFullscreen;
                if (call.method == 'isMaximized') return true;
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final context = await _host(tester);
          final pending = showFullscreenSettingsPreview<int>(
            context: context,
            platform: platform,
            builder: (_) => const Scaffold(body: Text('preview')),
          );
          await tester.pumpAndSettle();
          Navigator.of(context).pop(3);
          await tester.pumpAndSettle();
          expect(await pending, 3);
          expect(windowCalls.map((call) => call.method), [
            'isFullScreen',
            'isMaximized',
            if (!wasFullscreen) 'unmaximize',
            'setFullScreen',
            'setFullScreen',
            if (!wasFullscreen) 'maximize',
          ]);
          expect(
            windowCalls
                .where((call) => call.method == 'setFullScreen')
                .map((call) => call.arguments),
            [
              {'isFullScreen': true},
              {'isFullScreen': wasFullscreen},
            ],
          );
          expect(_orientations(systemCalls), isEmpty);
          expect(_uiModes(systemCalls), isEmpty);
        },
      );
    }
  }
}
