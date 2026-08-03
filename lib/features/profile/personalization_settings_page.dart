import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/playback_preferences.dart';
import '../../services/playback_preferences_service.dart';
import '../../services/app_update_service.dart';
import '../../services/focus_notification_service.dart';
import '../../services/focus_preferences_service.dart';

/// 展示焦点哔哩的个性化选项，并把播放器手势偏好保存在当前设备。
class PersonalizationSettingsPage extends StatefulWidget {
  /// 创建个性化设置页；测试可注入内存服务替代真实设备存储。
  const PersonalizationSettingsPage({
    super.key,
    this.preferencesService = const PlaybackPreferencesService(),
    this.focusPreferencesService,
    this.focusNotificationService = const FocusNotificationService(),
  });

  final PlaybackPreferencesService preferencesService;
  final FocusPreferencesService? focusPreferencesService;
  final FocusNotificationService focusNotificationService;

  /// 创建负责加载和保存设置的页面状态。
  @override
  State<PersonalizationSettingsPage> createState() =>
      _PersonalizationSettingsPageState();
}

/// 管理播放器偏好加载状态，并在用户切换开关时立即持久化。
class _PersonalizationSettingsPageState
    extends State<PersonalizationSettingsPage>
    with WidgetsBindingObserver {
  PlaybackPreferences _preferences = const PlaybackPreferences();
  FocusPreferences _focusPreferences = const FocusPreferences();
  bool _loading = true;
  bool _saving = false;
  bool _savingDoNotDisturb = false;
  bool _hasDoNotDisturbAccess = false;
  bool _savingUpdatePreference = false;
  late final AppUpdateController _fallbackUpdateController;
  late final FocusPreferencesService _focusPreferencesService;

  /// 页面创建后读取设备里已经保存的播放器偏好。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusPreferencesService =
        widget.focusPreferencesService ?? FocusPreferencesService();
    _fallbackUpdateController = AppUpdateController()
      ..addListener(_handleFallbackUpdateChanged);
    _loadPreferences();
  }

  /// 独立组件没有根更新作用域时，也能刷新开关和检查结果。
  void _handleFallbackUpdateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 从本地读取配置；读取失败时保留安全默认值，设置页仍可继续使用。
  Future<void> _loadPreferences() async {
    try {
      final PlaybackPreferences preferences = await widget.preferencesService
          .load();
      final FocusPreferences focusPreferences = await _focusPreferencesService
          .load();
      final bool hasDoNotDisturbAccess = await widget.focusNotificationService
          .hasDoNotDisturbAccess();
      if (!mounted) {
        return;
      }
      setState(() {
        _preferences = preferences;
        _focusPreferences = focusPreferences;
        _hasDoNotDisturbAccess = hasDoNotDisturbAccess;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 从系统设置返回页面时重新读取勿扰特殊访问权限，让开关说明立即反映结果。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshDoNotDisturbAccess());
    }
  }

  /// 查询当前勿扰权限并刷新副标题；查询失败时按未授权处理。
  Future<void> _refreshDoNotDisturbAccess() async {
    final bool permitted = await widget.focusNotificationService
        .hasDoNotDisturbAccess();
    if (mounted) {
      setState(() => _hasDoNotDisturbAccess = permitted);
    }
  }

  /// 保存专注勿扰开关；首次开启或权限被撤销时解释用途并打开系统特殊访问页。
  Future<void> _setDoNotDisturbEnabled(bool enabled) async {
    if (_savingDoNotDisturb) {
      return;
    }
    final FocusPreferences previous = _focusPreferences;
    setState(() {
      _focusPreferences = _focusPreferences.copyWith(
        enableDoNotDisturb: enabled,
      );
      _savingDoNotDisturb = true;
    });
    try {
      final bool saved = await _focusPreferencesService.saveDoNotDisturbEnabled(
        enabled,
      );
      if (!saved) {
        throw StateError('无法保存勿扰模式开关');
      }
      if (!enabled) {
        await widget.focusNotificationService.setFocusDoNotDisturb(false);
        return;
      }
      final bool permitted = await widget.focusNotificationService
          .hasDoNotDisturbAccess();
      if (!mounted) {
        return;
      }
      setState(() => _hasDoNotDisturbAccess = permitted);
      if (permitted) {
        return;
      }
      final bool? openSettings = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('允许控制勿扰模式'),
          content: const Text(
            '首次使用需要在 Android 的“勿扰模式访问权限”中允许焦点哔哩。专注视频播放时开启勿扰，用户暂停时恢复；快进、快退产生的短暂缓冲不会反复切换。',
          ),
          actions: <Widget>[
            TextButton(
              // 稍后设置函数保留开关；每次开始专注仍会重新检查并提醒。
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('稍后设置'),
            ),
            FilledButton(
              // 打开设置函数进入 Android 特殊访问页面，由用户亲自授权。
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('打开系统设置'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await widget.focusNotificationService.openDoNotDisturbSettings();
      }
    } on Object {
      if (mounted) {
        setState(() => _focusPreferences = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('勿扰模式设置保存失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _savingDoNotDisturb = false);
      }
    }
  }

  /// 保存双击行为；关闭后播放器任意区域双击都只切换播放或暂停。
  Future<void> _setDoubleTapSeekEnabled(bool enabled) async {
    if (_saving) {
      return;
    }
    final PlaybackPreferences previous = _preferences;
    setState(() {
      _preferences = _preferences.copyWith(enableDoubleTapSeek: enabled);
      _saving = true;
    });
    try {
      await widget.preferencesService.saveDoubleTapSeekEnabled(enabled);
    } catch (_) {
      if (mounted) {
        setState(() => _preferences = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 保存启动检查开关；重新开启时控制器会立即执行一次 GitHub Release 检查。
  Future<void> _setUpdateCheckEnabled(
    AppUpdateController controller,
    bool enabled,
  ) async {
    if (_savingUpdatePreference) {
      return;
    }
    setState(() => _savingUpdatePreference = true);
    try {
      await controller.setEnabled(enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('更新检查设置保存失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _savingUpdatePreference = false);
      }
    }
  }

  /// 创建个性化设置页面，并保留缓存管理的独立入口。
  @override
  Widget build(BuildContext context) {
    final AppUpdateController updateController =
        AppUpdateScope.maybeOf(context) ?? _fallbackUpdateController;
    if (!updateController.loaded && !updateController.checking) {
      unawaited(updateController.initialize(checkOnStart: false));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('个性化设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: <Widget>[
                SwitchListTile.adaptive(
                  key: const Key('enable-double-tap-seek'),
                  value: _preferences.enableDoubleTapSeek,
                  // 双击开关函数立即更新界面并把选择保存到当前设备。
                  onChanged: _saving ? null : _setDoubleTapSeekEnabled,
                  secondary: const Icon(Icons.touch_app_outlined),
                  title: const Text('启用双击快进快退'),
                  subtitle: const Text('关闭后，双击视频画面的任何位置都会切换播放或暂停。'),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const Key('open-android-permissions'),
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('权限管理'),
                  subtitle: const Text('统一申请、检查、取消权限，并设置后台提醒保护'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  // 权限管理入口函数打开统一页面，原有勿扰开关和功能内申请入口继续保留。
                  onTap: () => Navigator.of(
                    context,
                  ).pushNamed(AppRoutes.androidPermissions),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  key: const Key('enable-focus-do-not-disturb'),
                  value: _focusPreferences.enableDoNotDisturb,
                  // 勿扰开关函数保存用户选择，并在首次开启时说明 Android 特殊访问权限。
                  onChanged: _savingDoNotDisturb
                      ? null
                      : _setDoNotDisturbEnabled,
                  secondary: const Icon(Icons.do_not_disturb_on_outlined),
                  title: const Text('专注状态将手机设为勿扰模式'),
                  subtitle: Text(
                    !_focusPreferences.enableDoNotDisturb
                        ? '关闭时不会修改手机的勿扰状态。'
                        : _hasDoNotDisturbAccess
                        ? '已授权；播放时开启，暂停或结束时恢复，快进不会反复切换。'
                        : '尚未授权；每次开始专注都会检查并提示。',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  key: const Key('enable-startup-update-check'),
                  value: updateController.enabled,
                  onChanged: _savingUpdatePreference
                      ? null
                      : (bool enabled) =>
                            _setUpdateCheckEnabled(updateController, enabled),
                  secondary: const Icon(Icons.system_update_alt_rounded),
                  title: const Text('启动时检查更新'),
                  subtitle: const Text('每次启动从 GitHub Release 检查新的正式版本。'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('视频缓存管理'),
                  subtitle: const Text('查看和清理边播边缓存的数据'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  // 缓存入口函数进入已有缓存管理页面，不把两种设置混在一个开关中。
                  onTap: () => Navigator.of(
                    context,
                  ).pushNamed(AppRoutes.cacheManagement),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const Key('open-about-page'),
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('关于'),
                  subtitle: const Text('项目地址、负责人、版本与更新'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (updateController.hasUpdate) ...<Widget>[
                        Container(
                          key: const Key('settings-update-dot'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.about),
                ),
              ],
            ),
    );
  }

  /// 释放独立页面的后备更新控制器和监听器。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fallbackUpdateController
      ..removeListener(_handleFallbackUpdateChanged)
      ..dispose();
    super.dispose();
  }
}
