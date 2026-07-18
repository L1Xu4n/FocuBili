import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/playback_preferences.dart';
import '../../services/playback_preferences_service.dart';
import '../../services/app_update_service.dart';

/// 展示焦点哔哩的个性化选项，并把播放器手势偏好保存在当前设备。
class PersonalizationSettingsPage extends StatefulWidget {
  /// 创建个性化设置页；测试可注入内存服务替代真实设备存储。
  const PersonalizationSettingsPage({
    super.key,
    this.preferencesService = const PlaybackPreferencesService(),
  });

  final PlaybackPreferencesService preferencesService;

  /// 创建负责加载和保存设置的页面状态。
  @override
  State<PersonalizationSettingsPage> createState() =>
      _PersonalizationSettingsPageState();
}

/// 管理播放器偏好加载状态，并在用户切换开关时立即持久化。
class _PersonalizationSettingsPageState
    extends State<PersonalizationSettingsPage> {
  PlaybackPreferences _preferences = const PlaybackPreferences();
  bool _loading = true;
  bool _saving = false;
  bool _savingUpdatePreference = false;
  late final AppUpdateController _fallbackUpdateController;

  /// 页面创建后读取设备里已经保存的播放器偏好。
  @override
  void initState() {
    super.initState();
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
      if (!mounted) {
        return;
      }
      setState(() {
        _preferences = preferences;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
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
    _fallbackUpdateController
      ..removeListener(_handleFallbackUpdateChanged)
      ..dispose();
    super.dispose();
  }
}
