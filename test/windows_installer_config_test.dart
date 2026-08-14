import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows 安装器保持普通用户可安装、稳定升级身份和完整目录分发约束。
void main() {
  /// 检查安装脚本使用构建参数，而不是把某一个版本号永久写死在安装器配置里。
  test('Windows EXE 安装器使用动态版本和稳定应用身份', () {
    final String installer = File(
      'windows/installer/FocuBili.iss',
    ).readAsStringSync();

    expect(
      installer,
      contains('AppId={{8B7E1A0E-C692-4BA8-A2BA-B0F78ED60A26}'),
    );
    expect(installer, contains('AppVersion={#AppVersion}'));
    expect(installer, contains('VersionInfoVersion={#AppVersion}.{#AppBuild}'));
    expect(installer, contains('PrivilegesRequired=lowest'));
    expect(installer, contains('MinVersion=10.0.17763'));
    expect(installer, contains('Source: "{#SourceDir}\\*"'));
    expect(
      installer,
      contains('Flags: ignoreversion recursesubdirs createallsubdirs'),
    );
  });

  /// 检查构建脚本会复制 VC++ 运行库并在删除旧产物前限制目标目录。
  test('Windows 打包脚本包含运行库与安全清理检查', () {
    final String buildScript = File(
      'windows/installer/build_windows_packages.ps1',
    ).readAsStringSync();

    expect(buildScript, contains('Find-VcRuntimeDirectory'));
    expect(buildScript, contains('Assert-SafeInstallerOutputPath'));
    expect(
      buildScript,
      contains("@('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')"),
    );
    expect(buildScript, contains('Compress-Archive'));
    expect(
      buildScript,
      contains('Inno Setup did not produce the expected installer'),
    );
  });

  /// 检查原生 Runner 的默认尺寸、居中算法和最小窗口限制与桌面布局说明一致。
  test('Windows Runner 使用 1280×800 居中窗口和 900×640 最小尺寸', () {
    final String mainRunner = File(
      'windows/runner/main.cpp',
    ).readAsStringSync();
    final String windowRunner = File(
      'windows/runner/win32_window.cpp',
    ).readAsStringSync();

    expect(mainRunner, contains('Win32Window::Size size(1280, 800)'));
    expect(mainRunner, contains('CalculateCenteredOrigin(size)'));
    expect(windowRunner, contains('kMinimumWindowWidth = 900'));
    expect(windowRunner, contains('kMinimumWindowHeight = 640'));
    expect(windowRunner, contains('case WM_GETMINMAXINFO'));
  });

  /// 检查官方登录 WebView 标题栏子进程不会被主应用的单实例互斥锁提前拦截。
  test('Windows Runner 仅为 WebView 标题栏子进程绕过单实例锁', () {
    final String mainRunner = File(
      'windows/runner/main.cpp',
    ).readAsStringSync();

    expect(mainRunner, contains('IsWebViewTitleBarProcess()'));
    expect(mainRunner, contains('L"web_view_title_bar"'));
    expect(mainRunner, contains('if (!is_webview_title_bar)'));
    expect(mainRunner, contains(r'L"Local\\FocuBili.SingleInstance"'));
  });
}
