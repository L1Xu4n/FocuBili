import 'package:flutter/material.dart';

import '../../features/player/player_page.dart';
import '../../features/profile/cache_management_page.dart';
import '../../features/profile/login_page.dart';
import '../../features/profile/watch_history_page.dart';
import '../../features/shell/main_shell.dart';
import '../../models/video_preview.dart';

/// 保存应用所有路由名称，减少页面之间手写字符串造成的错误。
abstract final class AppRoutes {
  static const String home = '/';
  static const String player = '/player';
  static const String login = '/login';
  static const String cacheManagement = '/settings/cache';
  static const String watchHistory = '/history';
}

/// 根据路由名称创建页面，是整个应用唯一的页面导航入口。
abstract final class AppRouter {
  /// 把路由请求转换为对应页面，并处理缺少播放器参数的情况。
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.home:
        return MaterialPageRoute<void>(
          // 主页构建函数创建带底部导航的主框架。
          builder: (BuildContext context) => const MainShell(),
          settings: settings,
        );
      case AppRoutes.player:
        final Object? arguments = settings.arguments;
        final VideoPreview video =
            arguments is VideoPreview ? arguments : VideoPreview.placeholder();
        return MaterialPageRoute<void>(
          // 播放页构建函数把选中的视频信息交给原生播放器占位页。
          builder: (BuildContext context) => PlayerPage(video: video),
          settings: settings,
        );
      case AppRoutes.login:
        return MaterialPageRoute<Object?>(
          // 登录页构建函数创建手机号、密码、Cookie 和官方网页登录入口。
          builder: (BuildContext context) => const LoginPage(),
          settings: settings,
        );
      case AppRoutes.cacheManagement:
        return MaterialPageRoute<void>(
          // 缓存设置页构建函数创建只管理边播边缓存的独立设置页面。
          builder: (BuildContext context) => const CacheManagementPage(),
          settings: settings,
        );
      case AppRoutes.watchHistory:
        return MaterialPageRoute<void>(
          // 观看记录页构建函数显示仅保存在当前设备上的最近观看视频。
          builder: (BuildContext context) => const WatchHistoryPage(),
          settings: settings,
        );
      default:
        return MaterialPageRoute<void>(
          // 未知路由回到主框架，避免用户看到空白页面。
          builder: (BuildContext context) => const MainShell(),
          settings: settings,
        );
    }
  }
}
