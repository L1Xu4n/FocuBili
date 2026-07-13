import 'package:flutter/material.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// 焦点哔哩的根组件，统一配置主题、路由和调试标记。
class FocuBiliApp extends StatelessWidget {
  const FocuBiliApp({super.key});

  /// 创建整套应用界面，并把页面导航交给统一路由处理。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '焦点哔哩',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.home,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
