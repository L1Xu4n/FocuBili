import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../platform/app_platform.dart';
import '../../services/focus_preferences_service.dart';

/// 第一次打开播放器专注时按平台说明勿扰边界，并允许用户直接进入应用设置。
Future<void> showPlayerFocusDoNotDisturbGuideIfNeeded(
  BuildContext context, {
  FocusPreferencesService? preferencesService,
  Future<void> Function()? openSettings,
  AppPlatform? appPlatform,
}) async {
  final FocusPreferencesService service =
      preferencesService ?? FocusPreferencesService();
  final FocusPreferences preferences = await service.load();
  if (preferences.hasSeenPlayerDoNotDisturbGuide || !context.mounted) {
    return;
  }
  await service.markPlayerDoNotDisturbGuideSeen();
  if (!context.mounted) {
    return;
  }
  final bool isWindows =
      (appPlatform ?? AppPlatformDetector.current) == AppPlatform.windows;
  final bool? shouldOpenSettings = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: const Icon(Icons.do_not_disturb_on_outlined),
      title: Text(isWindows ? 'Windows 系统专注需要手动启动' : '专注时可以自动开启勿扰'),
      content: Text(
        isWindows
            ? 'Windows 自动启动系统专注需要微软单独授权。你可以在“我的 → 设置 → 个性化设置”中开启开始提醒，之后从 Windows“时钟”手动启动。'
            : '你可以在“我的 → 设置 → 个性化设置”中开启专注勿扰。开启后，专注视频播放时进入勿扰，暂停或结束时恢复；快进、快退不会反复切换。',
      ),
      actions: <Widget>[
        TextButton(
          // 稍后设置函数关闭首次说明，用户仍可随时从“我的”页面进入设置。
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('稍后设置'),
        ),
        FilledButton(
          // 前往设置函数先关闭说明，再由调用方打开应用内个性化设置页。
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('前往设置'),
        ),
      ],
    ),
  );
  if (shouldOpenSettings != true || !context.mounted) {
    return;
  }
  if (openSettings != null) {
    await openSettings();
    return;
  }
  await Navigator.of(
    context,
  ).pushNamed<void>(AppRoutes.personalizationSettings);
}
