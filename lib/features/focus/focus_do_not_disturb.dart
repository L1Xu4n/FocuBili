import 'package:flutter/material.dart';

import 'focus_timer_controller.dart';

/// 专注创建后检查勿扰开关；缺少特殊访问权限时解释用途并由用户决定是否打开系统设置。
Future<void> handleDoNotDisturbAfterFocusStart(
  BuildContext context,
  FocusTimerController controller,
) async {
  final FocusDoNotDisturbResult result = await controller
      .ensureDoNotDisturbForActiveFocus();
  if (!context.mounted || result == FocusDoNotDisturbResult.disabled) {
    return;
  }
  if (result == FocusDoNotDisturbResult.permissionRequired) {
    final bool? openSettings = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('需要勿扰模式权限'),
        content: const Text(
          '你已开启“专注状态将手机设为勿扰模式”。Android 要求你在特殊访问设置中允许焦点哔哩控制勿扰模式；每次开始专注都会重新检查。',
        ),
        actions: <Widget>[
          TextButton(
            // 暂不授权函数保留专注任务，但本次不会修改手机的勿扰状态。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不授权'),
          ),
          FilledButton(
            // 打开设置函数交给 Android 展示勿扰模式特殊访问列表。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('打开系统设置'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await controller.openDoNotDisturbSettings();
    }
    return;
  }
  final String message = switch (result) {
    FocusDoNotDisturbResult.enabled => '视频播放时已进入勿扰；暂停或专注结束后会恢复原设置',
    FocusDoNotDisturbResult.failed => '暂时无法启用勿扰模式，请检查系统权限',
    FocusDoNotDisturbResult.disabled ||
    FocusDoNotDisturbResult.permissionRequired => '',
  };
  if (message.isEmpty || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
