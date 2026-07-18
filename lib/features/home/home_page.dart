import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/focus_session.dart';
import '../focus/focus_dashboard.dart';
import '../focus/focus_timer_scope.dart';
import '../focus/focus_video_launcher.dart';

/// 专注导向的首页，把目标计时作为主动观看前的第一入口。
class HomePage extends StatelessWidget {
  /// 创建首页，并接收切换到“打开视频”页的回调。
  const HomePage({super.key, required this.onSearchRequested});

  final VoidCallback onSearchRequested;

  /// 打开专注统计看板，查看趋势并统一管理本机记录。
  void _openFocusStatistics(BuildContext context) {
    Navigator.of(context).pushNamed(AppRoutes.focusStatistics);
  }

  /// 从首页 Pin 查询视频详情并恢复到关联分P和上次看到的位置。
  void _openLinkedVideo(BuildContext context, FocusSession session) {
    FocusVideoLauncher.open(context, session);
  }

  /// 创建使用应用级计时控制器的专注台，切换标签不会丢失当前状态。
  @override
  Widget build(BuildContext context) {
    return FocusDashboard(
      controller: FocusTimerScope.of(context),
      onOpenVideo: onSearchRequested,
      onOpenStatistics: () => _openFocusStatistics(context),
      onOpenLinkedVideo: (FocusSession session) =>
          _openLinkedVideo(context, session),
    );
  }
}
