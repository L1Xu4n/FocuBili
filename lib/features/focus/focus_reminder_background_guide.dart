import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../services/focus_notification_service.dart';
import '../../services/focus_preferences_service.dart';

/// 在小米等需要后台自启动的设备第一次成功设置提醒后展示保护说明。
Future<void> showFocusReminderBackgroundGuideIfNeeded(
  BuildContext context, {
  FocusNotificationService notificationService =
      const FocusNotificationService(),
  FocusPreferencesService? preferencesService,
  Future<void> Function()? openPermissionManagement,
}) async {
  final FocusPreferencesService preferences =
      preferencesService ?? FocusPreferencesService();
  final FocusPreferences stored = await preferences.load();
  if (stored.hasSeenBackgroundReminderGuide || !context.mounted) {
    return;
  }
  final AndroidPermissionOverview overview = await notificationService
      .getPermissionOverview();
  if (!overview.requiresAutostartGuide || !context.mounted) {
    return;
  }
  await preferences.markBackgroundReminderGuideSeen();
  if (!context.mounted) {
    return;
  }
  final bool? openPermissions = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: const Icon(Icons.notifications_active_outlined),
      title: const Text('开启后台提醒保护'),
      content: const Text(
        '小米/HyperOS 在划掉多任务后台后，只有开启“后台自启动”并把电量策略设为“无限制”，才会允许焦点哔哩在提醒时间重新启动接收器。请到统一权限管理页完成检查。',
      ),
      actions: <Widget>[
        TextButton(
          // 稍后处理函数关闭一次性引导，统一权限页仍会长期保留入口。
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('稍后处理'),
        ),
        FilledButton(
          // 权限管理函数关闭说明后进入应用内统一权限页面。
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('权限管理'),
        ),
      ],
    ),
  );
  if (openPermissions != true || !context.mounted) {
    return;
  }
  if (openPermissionManagement != null) {
    await openPermissionManagement();
    return;
  }
  await Navigator.of(context).pushNamed<void>(AppRoutes.androidPermissions);
}
