import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/app.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _InactiveSubscriptions extends SubscriptionService {
  @override
  void setForeground(bool value) {}
}

void main() {
  test('main Android host handles input configuration changes in place', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final host = RegExp(
      r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>',
    ).firstMatch(manifest)?.group(0);
    expect(host, isNotNull);
    final config = RegExp(
      r'android:configChanges="([^"]+)"',
    ).firstMatch(host!)?.group(1)?.split('|');
    expect(
      config,
      containsAll(['keyboard', 'keyboardHidden', 'navigation', 'touchscreen']),
    );
  });

  test(
    'input configuration diagnostics accept only expected primitive fields',
    () {
      final info = DiagnosticDeviceInfo.fromPlatformMap({
        'activityStartedAtMs': 1795082400000,
        'activityCreatesInProcess': 2,
        'restoredActivityState': true,
        'previousActivityChangedConfiguration': true,
        'lastInputConfigurationChangeAtMs': 1795082401000,
        'inputDeviceName': 'do not export',
      }).publicInfo;
      expect(info['当前 Android 界面创建时间'], isNotEmpty);
      expect(info['本进程 Android 界面创建次数'], '2');
      expect(info['系统曾提供界面恢复状态'], '是');
      expect(info['上一界面因配置变更销毁'], '是');
      expect(info['最近输入配置变更'], isNotEmpty);
      expect(info.values, isNot(contains('do not export')));
      expect(
        DiagnosticDeviceInfo.fromPlatformMap({
          'activityStartedAtMs': 'not a timestamp',
          'activityCreatesInProcess': -1,
          'restoredActivityState': 1,
          'previousActivityChangedConfiguration': 'yes',
          'lastInputConfigurationChangeAtMs': 4102444800001,
        }).publicInfo,
        isEmpty,
      );
    },
  );

  testWidgets(
    'Flutter viewport changes preserve a pushed route and its state',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        FirstLaunchService.agreementAcceptedKey: true,
        FirstLaunchService.loginGuideShownKey: true,
      });
      final subscriptions = _InactiveSubscriptions();
      addTearDown(subscriptions.dispose);
      tester.view.devicePixelRatio = 2.23;
      tester.view.physicalSize = const Size(3000, 2120);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        FocuBiliApp(
          checkForUpdatesOnStart: false,
          subscriptionService: subscriptions,
        ),
      );
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      const editor = Key('issue-96-route-editor');
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: TextField(key: editor)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(editor), 'still here');

      // Simulates the viewport update after an in-place host callback, not an
      // Android Bluetooth connection or an Activity recreation.
      tester.view.physicalSize = const Size(3000, 2000);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(3000, 2120);
      await tester.pumpAndSettle();
      expect(navigator.canPop(), isTrue);
      expect(find.byKey(editor), findsOneWidget);
      expect(find.text('still here'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 13));
    },
  );
}
