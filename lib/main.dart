import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/theme/app_theme.dart';
import 'platform/platform_services.dart';
import 'platform/app_platform.dart';
import 'platform/platform_capabilities.dart';
import 'services/problem_diagnostics_service.dart';
import 'services/apple_video_capabilities.dart';

/// 注册框架和 Dart 未捕获错误的最小诊断记录；只保存固定操作名与异常类型，绝不保存异常原文或堆栈。
void _installProblemDiagnostics() {
  final ProblemDiagnosticsService diagnostics = ProblemDiagnosticsService();
  final void Function(FlutterErrorDetails details)?
  previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    // 框架错误回调先沿用原来的控制台呈现行为，避免改变开发和测试时的报错可见性。
    previousFlutterErrorHandler?.call(details);
    // runtimeType 只包含异常类名，可帮助区分布局、状态和平台错误，同时不会带入异常正文或用户数据。
    unawaited(
      diagnostics.recordUnexpectedError(
        operation: 'flutter_framework',
        errorType: details.exception.runtimeType.toString(),
      ),
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    // Dart 异步未捕获错误同样只写固定分类和异常类名；返回 false 保留系统原有的未处理错误行为。
    unawaited(
      diagnostics.recordUnexpectedError(
        operation: 'dart_runtime',
        errorType: error.runtimeType.toString(),
      ),
    );
    return false;
  };
}

/// 按能力表初始化桌面媒体后端与窗口；移动平台不会加载这些桌面行为。
Future<void> _prepareWindowsDesktop({
  PlatformServices? platformServices,
}) async {
  final PlatformServices services =
      platformServices ?? PlatformServices.current;
  if (services.capabilities.playbackBackend == PlaybackBackendKind.mediaKit) {
    MediaKit.ensureInitialized();
    await AppleVideoCapabilities.initialize();
  }
  if (!services.capabilities.supportsDesktopWindow) {
    return;
  }
  await windowManager.ensureInitialized();
  var initialSize = const Size(1280, 800);
  var minimumSize = const Size(900, 640);
  if (services.platform == AppPlatform.macos) {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final display = views.first.display;
      final screen = display.size / display.devicePixelRatio;
      if (screen.width > 0 && screen.height > 0) {
        initialSize = Size(
          (screen.width - 40).clamp(640.0, 1280.0),
          (screen.height - 100).clamp(480.0, 800.0),
        );
        minimumSize = Size(
          initialSize.width.clamp(640.0, 900.0),
          initialSize.height.clamp(480.0, 640.0),
        );
      }
    }
  }
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: initialSize,
      minimumSize: minimumSize,
      center: true,
      backgroundColor: Color(0xFFF7F8FC),
      title: '焦点哔哩',
    ),
  );
  await windowManager.show();
  await windowManager.focus();
}

/// 初始化 Flutter 绑定、系统栏样式，并启动焦点哔哩应用。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // WebView2 子窗口进程只绘制插件标题栏，不重复初始化完整焦点哔哩应用。
  if (runWebViewTitleBarWidget(args)) {
    return;
  }
  _installProblemDiagnostics();
  await _prepareWindowsDesktop();
  // Android 启动方向由 MainActivity 在 Flutter 首帧前决定，避免未稳定的窗口尺寸把平板误判成手机。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 首帧前先按浅色背景设置深色系统图标，后续由应用主题自动同步明暗模式。
  SystemChrome.setSystemUIOverlayStyle(
    AppTheme.systemOverlayStyle(Brightness.light),
  );
  runApp(const FocuBiliApp(checkForUpdatesOnStart: true));
}
