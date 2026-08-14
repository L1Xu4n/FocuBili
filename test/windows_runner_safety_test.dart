import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows Runner 的勿扰刷新与窗口消息边界不会再次形成进程级 abort。
void main() {
  /// 勿扰刷新不得使用包含当前进程的 HWND_BROADCAST，以免同步重入 Flutter 方法通道。
  test('Windows 勿扰刷新排除当前进程窗口', () {
    final String runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    expect(
      runner,
      contains('EnumWindows(NotifyExternalWindowOfNotificationChange'),
    );
    expect(runner, contains('window_process_id == current_process_id'));
    expect(runner, isNot(contains('SendNotifyMessageW(HWND_BROADCAST')));
  });

  /// noexcept 的 Win32 回调必须拦截引擎或插件异常，并在控制器销毁后安全处理字体消息。
  test('Windows 窗口消息边界阻止异常触发 terminate', () {
    final String runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    expect(runner, contains('FlutterWindow::MessageHandler'));
    expect(runner, contains('} catch (...) {'));
    expect(
      runner,
      contains('if (flutter_controller_ && flutter_controller_->engine())'),
    );
  });

  /// Windows 勿扰方法通道也必须把原生异常转换为 Dart 可处理的平台错误。
  test('Windows 勿扰方法通道拦截原生异常', () {
    final String runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    expect(runner, contains('"windows_do_not_disturb_failed"'));
    expect(runner, contains('Windows do-not-disturb operation failed.'));
  });

  /// Runner 不得再把旧的全局通知注册表开关当成 Windows 系统专注启动接口。
  test('Windows 系统专注未授权时不再伪造自动启动', () {
    final String runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    expect(runner, isNot(contains('EnableWindowsDoNotDisturb')));
    expect(runner, contains('result->Success(flutter::EncodableValue(false))'));
    expect(runner, contains('RestoreLegacyNotificationSetting'));
    expect(
      runner,
      isNot(contains('WriteUserDword(kRuntimeStateKey, kRestoreExistsValue')),
    );
  });
}
