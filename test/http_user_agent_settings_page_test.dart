import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/http_user_agent_settings_page.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/http_user_agent_preferences.dart';

import 'subscription_compact_ui_test.dart'
    show captureSubscriptionUi, loadBetaReviewFonts;

const _sample = 'ExampleClient/1.0 (Local QA)';
final _field = find.byKey(const Key('http-user-agent-input'));
final _save = find.byKey(const Key('http-user-agent-save'));
final _restore = find.byKey(const Key('http-user-agent-reset'));
final _open = find.byKey(const Key('open-http-user-agent-settings'));

Future<void> _tap(WidgetTester t, Finder target) async {
  await t.pumpAndSettle();
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await t.tap(target);
  await t.pumpAndSettle();
}

void main() {
  const prefs = HttpUserAgentPreferences();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  testWidgets(
    'settings entry saves, reopens and resets the real local preference',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const PersonalizationSettingsPage(
            appPlatform: AppPlatform.windows,
            showLayoutSettings: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.scrollUntilVisible(_open, 180);
      await _tap(t, _open);
      expect(find.byType(HttpUserAgentSettingsPage), findsOneWidget);
      expect(find.text('当前使用默认标识'), findsOneWidget);
      await t.enterText(_field, '  $_sample ');
      await _tap(t, _save);
      expect(find.text('当前使用自定义标识'), findsOneWidget);
      expect(await prefs.load(), _sample);
      await t.pageBack();
      await t.pumpAndSettle();
      await _tap(t, _open);
      expect(t.widget<TextField>(_field).controller!.text, _sample);
      await _tap(t, _restore);
      expect(t.widget<TextField>(_field).controller!.text, '');
      expect(find.text('当前使用默认标识'), findsOneWidget);
      expect(await prefs.load(), isNull);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'with a narrow 200% viewport control inputs and overlength never persist',
    (t) async {
      t.view.physicalSize = const Size(320, 580);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const HttpUserAgentSettingsPage(),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(_field, 'Unsafe/1\nX-Extra: invalid');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.textContaining('只接受单行 ASCII'), findsOneWidget);
      expect(await prefs.load(), isNull);
      await t.ensureVisible(_field);
      await t.enterText(_field, 'y' * 513);
      expect(t.widget<TextField>(_field).controller!.text.length, 513);
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(t, _save);
      expect(find.textContaining('最多 512'), findsOneWidget);
      expect(await prefs.load(), isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'guard asynchronous writes and do not announce a failed save as active',
    (t) async {
      final first = Completer<void>();
      final writes = <String?>[];
      final store = HttpUserAgentPreferences(
        readValue: () async => 'Before/1',
        writeValue: (value) async {
          writes.add(value);
          await first.future;
          throw const FileSystemException('private fixture');
        },
      );
      await t.pumpWidget(
        MaterialApp(home: HttpUserAgentSettingsPage(preferences: store)),
      );
      await t.pumpAndSettle();
      await t.enterText(_field, _sample);
      await t.tap(_save);
      await t.pump();
      expect(t.widget<FilledButton>(_save).onPressed, isNull);
      expect(t.widget<TextButton>(_restore).onPressed, isNull);
      first.complete();
      await t.pumpAndSettle();
      expect(writes, [_sample]);
      expect(find.text('未能确认保存。请重试。'), findsOneWidget);
      expect(find.textContaining('private fixture'), findsNothing);
      expect(await store.load(), 'Before/1');
      expect(t.widget<TextField>(_field).controller!.text, _sample);
    },
  );

  testWidgets('corrupt data reports default and one tap clears it', (t) async {
    await SharedPreferencesAsync().setString(
      HttpUserAgentPreferences.storageKey,
      'bad\r\nheader',
    );
    await t.pumpWidget(const MaterialApp(home: HttpUserAgentSettingsPage()));
    await t.pumpAndSettle();
    expect(find.text('当前使用默认标识'), findsOneWidget);
    expect(find.textContaining('无法读取保存的设置'), findsOneWidget);
    await _tap(t, _restore);
    expect(find.text('已恢复默认。'), findsOneWidget);
    expect(await prefs.load(), isNull);
  });

  testWidgets(
    'capture the actual settings in its default and configured states',
    (t) async {
      if (const String.fromEnvironment('BETA3_CAPTURE_DIR').isEmpty) return;
      final frame = GlobalKey();
      await loadBetaReviewFonts(t);
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final theme = AppTheme.light();
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'BetaReview'),
            ),
            home: const PersonalizationSettingsPage(
              appPlatform: AppPlatform.android,
              showLayoutSettings: true,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.scrollUntilVisible(_open, 180);
      await _tap(t, _open);
      await captureSubscriptionUi(t, frame, 'http-user-agent-default');
      await t.enterText(_field, _sample);
      await _tap(t, _save);
      await captureSubscriptionUi(t, frame, 'http-user-agent-configured');
    },
  );
}
