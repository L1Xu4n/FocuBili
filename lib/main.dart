import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';

/// 初始化 Flutter 绑定、系统栏样式，并启动焦点哔哩应用。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  runApp(const FocuBiliApp());
}
