import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/theme/app_theme.dart';

/// 初始化 Flutter 绑定、系统栏样式，并启动焦点哔哩应用。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
