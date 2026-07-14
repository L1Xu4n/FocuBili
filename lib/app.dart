import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      // 根据实际主题在整棵页面树外层设置系统栏图标颜色，覆盖无 AppBar 的页面。
      builder: (BuildContext context, Widget? child) {
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.systemOverlayStyle(Theme.of(context).brightness),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
