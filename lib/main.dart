import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/theme/app_theme.dart';
import 'services/problem_diagnostics_service.dart';

/// 注册框架和 Dart 未捕获错误的最小诊断记录；只保存固定操作名，绝不保存异常原文或堆栈。
void _installProblemDiagnostics() {
  final ProblemDiagnosticsService diagnostics = ProblemDiagnosticsService();
  final void Function(FlutterErrorDetails details)?
  previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    // 框架错误回调先沿用原来的控制台呈现行为，避免改变开发和测试时的报错可见性。
    previousFlutterErrorHandler?.call(details);
    // 诊断记录只写“Flutter 界面运行”这个固定操作名，不写异常原文、堆栈或页面中的用户数据。
    unawaited(
      diagnostics.recordUnexpectedError(operation: 'flutter_framework'),
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    // Dart 异步未捕获错误同样只写固定分类；返回 false 保留系统原有的未处理错误行为。
    unawaited(diagnostics.recordUnexpectedError(operation: 'dart_runtime'));
    return false;
  };
}

/// 初始化 Flutter 绑定、系统栏样式，并启动焦点哔哩应用。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installProblemDiagnostics();
  // 应用若在播放器全屏期间被系统结束，重新启动时先恢复首页使用的竖屏方向。
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 首帧前先按浅色背景设置深色系统图标，后续由应用主题自动同步明暗模式。
  SystemChrome.setSystemUIOverlayStyle(
    AppTheme.systemOverlayStyle(Brightness.light),
  );
  runApp(const FocuBiliApp(checkForUpdatesOnStart: true));
}
