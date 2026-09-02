import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/windows_clipboard_link_service.dart';

/// 验证 Windows 剪贴板检测开关默认保护隐私，并可在本机持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 旧版本没有设置记录时必须默认关闭，用户开启后重建服务仍能读取。
  test('Windows 剪贴板检测默认关闭并可持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WindowsClipboardLinkPreferencesService service =
        WindowsClipboardLinkPreferencesService(
          preferencesLoader: () async => preferences,
        );

    expect(await service.loadEnabled(), isFalse);
    expect(await service.saveEnabled(true), isTrue);
    expect(await service.loadEnabled(), isTrue);
  });

  /// 验证 Android 启动监听时会读取一次剪贴板，并把非空文本交给应用根组件。
  test('Android 进入前台时检查一次剪贴板文本', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'windows_clipboard_link_detection.enabled': true,
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final List<String> observed = <String>[];
    final WindowsClipboardLinkMonitor monitor = WindowsClipboardLinkMonitor(
      preferencesService: WindowsClipboardLinkPreferencesService(
        preferencesLoader: () async => preferences,
      ),
      platform: AppPlatform.android,
      allowInFlutterTest: true,
      // 测试读取函数返回固定链接，避免访问真实系统剪贴板。
      clipboardTextReader: () async =>
          'https://www.bilibili.com/video/BV1GJ411x7h7',
    );
    addTearDown(monitor.dispose);

    monitor.start(observed.add);
    await Future<void>.delayed(Duration.zero);

    expect(observed, <String>['https://www.bilibili.com/video/BV1GJ411x7h7']);
  });

  /// 验证偏好读取期间退到后台后不会继续访问系统剪贴板。
  test('Android 读取准备期间进入后台会取消本次检查', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'windows_clipboard_link_detection.enabled': true,
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final Completer<void> preferencesRequested = Completer<void>();
    final Completer<void> allowPreferencesResult = Completer<void>();
    int clipboardReads = 0;
    final List<String> observed = <String>[];
    final WindowsClipboardLinkMonitor monitor = WindowsClipboardLinkMonitor(
      preferencesService: WindowsClipboardLinkPreferencesService(
        preferencesLoader: () async {
          preferencesRequested.complete();
          await allowPreferencesResult.future;
          return preferences;
        },
      ),
      platform: AppPlatform.android,
      allowInFlutterTest: true,
      // 测试读取函数记录调用次数，确保后台切换发生后不会触达剪贴板。
      clipboardTextReader: () async {
        clipboardReads += 1;
        return 'https://www.bilibili.com/video/BV1GJ411x7h7';
      },
    );
    addTearDown(monitor.dispose);

    monitor.start(observed.add);
    await preferencesRequested.future;
    monitor.setForeground(false);
    allowPreferencesResult.complete();
    await Future<void>.delayed(Duration.zero);

    expect(clipboardReads, 0);
    expect(observed, isEmpty);
  });
}
