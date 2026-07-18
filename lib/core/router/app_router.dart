import 'package:flutter/material.dart';

import '../../features/player/player_page.dart';
import '../../features/focus/focus_statistics_page.dart';
import '../../features/notes/video_notes_page.dart';
import '../../features/profile/cache_management_page.dart';
import '../../features/profile/about_page.dart';
import '../../features/profile/login_page.dart';
import '../../features/profile/personalization_settings_page.dart';
import '../../features/profile/watch_history_page.dart';
import '../../features/shell/main_shell.dart';
import '../../models/video_preview.dart';

/// 保存应用所有路由名称，减少页面之间手写字符串造成的错误。
abstract final class AppRoutes {
  static const String home = '/';
  static const String player = '/player';
  static const String login = '/login';
  static const String cacheManagement = '/settings/cache';
  static const String about = '/settings/about';
  static const String personalizationSettings = '/settings/personalization';
  static const String watchHistory = '/history';
  static const String videoNotes = '/notes';
  static const String focusStatistics = '/focus/statistics';
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
        final VideoPreview video = arguments is VideoPreview
            ? arguments
            : VideoPreview.placeholder();
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
      case AppRoutes.about:
        return MaterialPageRoute<void>(
          // 关于页集中展示项目来源、版本和 GitHub Release 更新状态。
          builder: (BuildContext context) => const AboutPage(),
          settings: settings,
        );
      case AppRoutes.personalizationSettings:
        return MaterialPageRoute<void>(
          // 个性化设置页构建函数集中管理播放器手势与缓存入口。
          builder: (BuildContext context) =>
              const PersonalizationSettingsPage(),
          settings: settings,
        );
      case AppRoutes.watchHistory:
        return MaterialPageRoute<void>(
          // 观看记录页构建函数显示仅保存在当前设备上的最近观看视频。
          builder: (BuildContext context) => const WatchHistoryPage(),
          settings: settings,
        );
      case AppRoutes.videoNotes:
        return MaterialPageRoute<void>(
          // 时间点笔记页构建函数统一读取、编辑和删除保存在本机的笔记。
          builder: (BuildContext context) => const VideoNotesPage(),
          settings: settings,
        );
      case AppRoutes.focusStatistics:
        return MaterialPageRoute<void>(
          // 专注统计页构建函数读取全应用控制器并提供看板与记录管理。
          builder: (BuildContext context) => const FocusStatisticsPage(),
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
