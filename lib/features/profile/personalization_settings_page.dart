import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/router/app_router.dart';
import '../../models/playback_preferences.dart';
import '../../services/app_behavior_preferences_service.dart';
import '../../services/playback_preferences_service.dart';
import '../../services/app_update_service.dart';
import '../../services/focus_notification_service.dart';
import '../../services/focus_preferences_service.dart';
import '../../services/windows_clipboard_link_service.dart';
import '../../platform/app_platform.dart';
import 'app_theme_mode_controller.dart';

/// 可选择的主题强调色预设，供设置页以色块形式展示。
const List<(String, int)> _themeColorOptions = <(String, int)>[
  ('默认蓝', 0xFF1677FF),
  ('B站粉', 0xFFFB7299),
  ('玫红', 0xFFE91E63),
  ('珊瑚橙', 0xFFFF7043),
  ('翠绿', 0xFF00A870),
  ('湖蓝', 0xFF00B8D4),
  ('薰衣草紫', 0xFF7C4DFF),
];

/// 标识个性化设置当前显示首页还是某个二级分类页面。
enum _SettingsLevel {
  overview,
  accountAndPrivacy,
  playbackAndFocus,
  appearanceAndApplication,
}

/// 展示焦点哔哩的个性化选项，并把播放器手势偏好保存在当前设备。
class PersonalizationSettingsPage extends StatefulWidget {
  /// 创建个性化设置页；测试可注入内存服务替代真实设备存储。
  const PersonalizationSettingsPage({
    super.key,
    this.preferencesService = const PlaybackPreferencesService(),
    this.focusPreferencesService,
    this.focusNotificationService = const FocusNotificationService(),
    this.windowsClipboardPreferencesService,
    this.behaviorPreferencesService,
    this.appPlatform,
  });

  final PlaybackPreferencesService preferencesService;
  final FocusPreferencesService? focusPreferencesService;
  final FocusNotificationService focusNotificationService;
  final WindowsClipboardLinkPreferencesService?
  windowsClipboardPreferencesService;
  final AppBehaviorPreferencesService? behaviorPreferencesService;
  final AppPlatform? appPlatform;

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
  bool _windowsClipboardDetectionEnabled = false;
  bool _savingWindowsClipboardPreference = false;
  bool _accountReadOnly = true;
  bool _searchHistoryEnabled = true;
  bool _watchHistoryEnabled = true;
  bool _savingBehaviorPreference = false;
  _SettingsLevel _settingsLevel = _SettingsLevel.overview;
  late final AppUpdateController _fallbackUpdateController;
  late final AppThemeModeController _fallbackThemeModeController;
  late final FocusPreferencesService _focusPreferencesService;
  late final WindowsClipboardLinkPreferencesService
  _windowsClipboardPreferencesService;
  late final AppBehaviorPreferencesService _behaviorPreferencesService;

  /// 判断页面是否明确运行在 Windows，测试可通过构造参数稳定覆盖。
  bool get _isWindows =>
      (widget.appPlatform ?? AppPlatformDetector.current) ==
      AppPlatform.windows;

  /// 判断当前平台是否支持前台剪贴板链接检测。
  bool get _supportsClipboardDetection {
    final AppPlatform platform =
        widget.appPlatform ?? AppPlatformDetector.current;
    return platform == AppPlatform.windows || platform == AppPlatform.android;
  }

  /// 页面创建后读取设备里已经保存的播放器偏好。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusPreferencesService =
        widget.focusPreferencesService ?? FocusPreferencesService();
    _windowsClipboardPreferencesService =
        widget.windowsClipboardPreferencesService ??
        WindowsClipboardLinkPreferencesService();
    _behaviorPreferencesService =
        widget.behaviorPreferencesService ?? AppBehaviorPreferencesService();
    _fallbackUpdateController = AppUpdateController()
      ..addListener(_handleFallbackUpdateChanged);
    _fallbackThemeModeController = AppThemeModeController()
      ..addListener(_handleFallbackThemeModeChanged);
    unawaited(_fallbackThemeModeController.initialize());
    _loadPreferences();
  }

  /// 独立组件没有根更新作用域时，也能刷新开关和检查结果。
  void _handleFallbackUpdateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 独立组件没有根主题作用域时，也能让模式按钮随保存结果刷新。
  void _handleFallbackThemeModeChanged() {
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
      final bool windowsClipboardDetectionEnabled =
          await _windowsClipboardPreferencesService.loadEnabled();
      final bool accountReadOnly = await _behaviorPreferencesService
          .loadAccountReadOnly();
      final bool searchHistoryEnabled = await _behaviorPreferencesService
          .loadSearchHistoryEnabled();
      final bool watchHistoryEnabled = await _behaviorPreferencesService
          .loadWatchHistoryEnabled();
      final bool hasDoNotDisturbAccess =
          widget.focusNotificationService.supportsDoNotDisturb
          ? await widget.focusNotificationService.hasDoNotDisturbAccess()
          : false;
      if (!mounted) {
        return;
      }
      setState(() {
        _preferences = preferences;
        _focusPreferences = focusPreferences;
        _windowsClipboardDetectionEnabled = windowsClipboardDetectionEnabled;
        _accountReadOnly = accountReadOnly;
        _searchHistoryEnabled = searchHistoryEnabled;
        _watchHistoryEnabled = watchHistoryEnabled;
        _hasDoNotDisturbAccess = hasDoNotDisturbAccess;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 保存账号只读开关；关闭后账号互动服务才允许提交写请求。
  Future<void> _setAccountReadOnly(bool enabled) async {
    await _saveBehaviorPreference(
      enabled: enabled,
      previous: _accountReadOnly,
      applyValue: (bool value) => _accountReadOnly = value,
      saveValue: _behaviorPreferencesService.saveAccountReadOnly,
      failureMessage: '账号只读设置保存失败，请稍后重试。',
    );
  }

  /// 保存搜索记录开关；关闭后保留已有记录但不再新增。
  Future<void> _setSearchHistoryEnabled(bool enabled) async {
    await _saveBehaviorPreference(
      enabled: enabled,
      previous: _searchHistoryEnabled,
      applyValue: (bool value) => _searchHistoryEnabled = value,
      saveValue: _behaviorPreferencesService.saveSearchHistoryEnabled,
      failureMessage: '搜索记录设置保存失败，请稍后重试。',
    );
  }

  /// 保存观看记录开关；关闭后保留已有记录但不再新增。
  Future<void> _setWatchHistoryEnabled(bool enabled) async {
    await _saveBehaviorPreference(
      enabled: enabled,
      previous: _watchHistoryEnabled,
      applyValue: (bool value) => _watchHistoryEnabled = value,
      saveValue: _behaviorPreferencesService.saveWatchHistoryEnabled,
      failureMessage: '观看记录设置保存失败，请稍后重试。',
    );
  }

  /// 统一执行行为开关的乐观更新、持久化和失败回滚。
  Future<void> _saveBehaviorPreference({
    required bool enabled,
    required bool previous,
    required ValueChanged<bool> applyValue,
    required Future<bool> Function(bool enabled) saveValue,
    required String failureMessage,
  }) async {
    if (_savingBehaviorPreference) {
      return;
    }
    setState(() {
      applyValue(enabled);
      _savingBehaviorPreference = true;
    });
    try {
      if (!await saveValue(enabled)) {
        throw StateError('无法保存应用行为偏好');
      }
    } catch (_) {
      if (mounted) {
        setState(() => applyValue(previous));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failureMessage)));
      }
    } finally {
      if (mounted) {
        setState(() => _savingBehaviorPreference = false);
      }
    }
  }

  /// 保存前台剪贴板检测开关；失败时恢复原值并显示说明。
  Future<void> _setWindowsClipboardDetectionEnabled(bool enabled) async {
    if (_savingWindowsClipboardPreference) {
      return;
    }
    final bool previous = _windowsClipboardDetectionEnabled;
    setState(() {
      _windowsClipboardDetectionEnabled = enabled;
      _savingWindowsClipboardPreference = true;
    });
    try {
      final bool saved = await _windowsClipboardPreferencesService.saveEnabled(
        enabled,
      );
      if (!saved) {
        throw StateError('无法保存剪贴板开关');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _windowsClipboardDetectionEnabled = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪贴板检测设置保存失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _savingWindowsClipboardPreference = false);
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
    if (!widget.focusNotificationService.supportsDoNotDisturb) {
      return;
    }
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
      if (_isWindows) {
        if (!mounted) {
          return;
        }
        final bool? openSettings = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('Windows 系统专注需要手动启动'),
            content: const Text(
              '微软把自动启动系统专注设为受限功能，焦点哔哩当前没有对应授权。开启后，应用会在每次专注开始时提醒你前往 Windows“时钟”手动启动，不会再用注册表模拟开启。',
            ),
            actions: <Widget>[
              TextButton(
                // 仅保存提醒开关，不离开当前个性化设置页。
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('知道了'),
              ),
              FilledButton(
                // 打开微软公开的勿扰设置入口，方便用户完成手动配置。
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('打开勿扰设置'),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await widget.focusNotificationService.openDoNotDisturbSettings();
        }
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

  /// 保存 Wi-Fi 或移动网络默认清晰度；失败时恢复进入选择前的配置。
  Future<void> _setDefaultQuality({
    required bool forWifi,
    required PreferredPlaybackQuality quality,
  }) async {
    if (_saving) {
      return;
    }
    final PlaybackPreferences previous = _preferences;
    setState(() {
      _preferences = forWifi
          ? _preferences.copyWith(wifiDefaultQuality: quality)
          : _preferences.copyWith(mobileDefaultQuality: quality);
      _saving = true;
    });
    try {
      if (forWifi) {
        await widget.preferencesService.saveWifiDefaultQuality(quality);
      } else {
        await widget.preferencesService.saveMobileDefaultQuality(quality);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _preferences = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('默认清晰度保存失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 创建一项网络清晰度下拉选择器，说明不可用时只会向更低档回退。
  Widget _buildDefaultQualityTile({required bool forWifi}) {
    final PreferredPlaybackQuality selected = forWifi
        ? _preferences.wifiDefaultQuality
        : _preferences.mobileDefaultQuality;
    return ListTile(
      key: Key(
        forWifi ? 'wifi-default-quality-tile' : 'mobile-default-quality-tile',
      ),
      leading: Icon(forWifi ? Icons.wifi_rounded : Icons.signal_cellular_alt),
      title: Text(forWifi ? 'Wi-Fi 默认清晰度' : '移动网络默认清晰度'),
      subtitle: const Text('当前视频没有该档位时，自动选择下一档更低清晰度'),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<PreferredPlaybackQuality>(
          key: Key(
            forWifi
                ? 'wifi-default-quality-dropdown'
                : 'mobile-default-quality-dropdown',
          ),
          value: selected,
          isDense: true,
          // 清晰度选择函数立即更新界面并保存到对应网络配置。
          onChanged: _saving
              ? null
              : (PreferredPlaybackQuality? value) {
                  if (value != null) {
                    unawaited(
                      _setDefaultQuality(forWifi: forWifi, quality: value),
                    );
                  }
                },
          items: PreferredPlaybackQuality.values
              .map(
                (PreferredPlaybackQuality quality) =>
                    DropdownMenuItem<PreferredPlaybackQuality>(
                      value: quality,
                      child: Text(quality.label),
                    ),
              )
              .toList(growable: false),
        ),
      ),
    );
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

  /// 保存全应用外观模式；失败时控制器会恢复旧值并向用户说明。
  Future<void> _setThemeMode(
    AppThemeModeController controller,
    ThemeMode mode,
  ) async {
    final bool saved = await controller.setMode(mode);
    if (!saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('深色模式设置保存失败，请稍后重试。')));
    }
  }

  /// 创建浅色、深色和跟随系统三段式选择器，切换后整套应用立即生效。
  Widget _buildThemeModeTile(AppThemeModeController controller) {
    return Padding(
      key: const Key('theme-mode-setting'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.brightness_6_outlined),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('深色模式'),
                    SizedBox(height: 2),
                    Text(
                      '默认跟随系统，切换后立即应用并在重启后保留',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              key: const Key('theme-mode-segmented-button'),
              showSelectedIcon: false,
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('浅色', key: Key('theme-mode-light-option')),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('深色', key: Key('theme-mode-dark-option')),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('跟随系统', key: Key('theme-mode-system-option')),
                ),
              ],
              selected: <ThemeMode>{controller.mode},
              // 模式选择函数只接受一个值，并交给全应用控制器立即应用和保存。
              onSelectionChanged: controller.saving
                  ? null
                  : (Set<ThemeMode> selection) {
                      unawaited(_setThemeMode(controller, selection.first));
                    },
            ),
          ),
        ],
      ),
    );
  }

  /// 创建主题强调色选择区，点按色块后整套应用立即换色并持久化。
  Widget _buildThemeColorTile(AppThemeModeController controller) {
    return Padding(
      key: const Key('theme-color-setting'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.palette_outlined),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('主题颜色'),
                    SizedBox(height: 2),
                    Text(
                      '选择整套界面的强调色，切换后立即应用并在重启后保留',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: <Widget>[
              for (final (String label, int value) in _themeColorOptions)
                Tooltip(
                  message: label,
                  child: InkWell(
                    key: Key('theme-color-option-${value.toRadixString(16)}'),
                    customBorder: const CircleBorder(),
                    onTap: controller.saving
                        ? null
                        : () => unawaited(
                            _setThemeColor(controller, Color(value)),
                          ),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(value),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: controller.seedColor.toARGB32() == value
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: controller.seedColor.toARGB32() == value
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('reset-theme-color'),
              onPressed: controller.saving
                  ? null
                  : () => unawaited(_resetThemeColor(controller)),
              child: const Text('恢复默认'),
            ),
          ),
        ],
      ),
    );
  }

  /// 保存新的主题强调色；失败时控制器会恢复旧值并向用户说明。
  Future<void> _setThemeColor(
    AppThemeModeController controller,
    Color color,
  ) async {
    final bool saved = await controller.setSeedColor(color);
    if (!saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('主题颜色保存失败，请稍后重试。')));
    }
  }

  /// 恢复默认主题颜色，失败时提示用户稍后重试。
  Future<void> _resetThemeColor(AppThemeModeController controller) async {
    final bool saved = await controller.resetSeedColor();
    if (!saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('主题颜色恢复失败，请稍后重试。')));
    }
  }

  /// 创建“账号与隐私”设置卡，集中管理账号写入和本机行为记录。
  Widget _buildAccountAndPrivacySection() {
    return _buildSettingsSection(
      key: const Key('settings-account-privacy-section'),
      icon: Icons.admin_panel_settings_outlined,
      title: '账号与隐私',
      children: <Widget>[
        SwitchListTile.adaptive(
          key: const Key('enable-account-read-only'),
          value: _accountReadOnly,
          // 账号只读开关函数保存后会被所有 B站写请求统一检查。
          onChanged: _savingBehaviorPreference ? null : _setAccountReadOnly,
          secondary: const Icon(Icons.lock_outline_rounded),
          title: const Text('账号只读'),
          subtitle: const Text('开启后将无法进行点赞、投币、收藏等对账号写入的操作。'),
        ),
        SwitchListTile.adaptive(
          key: const Key('enable-search-history'),
          value: _searchHistoryEnabled,
          // 搜索记录开关函数只控制后续新增，已有记录仍可查看和清除。
          onChanged: _savingBehaviorPreference
              ? null
              : _setSearchHistoryEnabled,
          secondary: const Icon(Icons.manage_search_rounded),
          title: const Text('启用搜索记录'),
          subtitle: const Text('关闭后不再新增搜索记录，已有记录会继续保留。'),
        ),
        SwitchListTile.adaptive(
          key: const Key('enable-watch-history'),
          value: _watchHistoryEnabled,
          // 观看记录开关函数只控制播放器后续写入，不阻止用户删除旧记录。
          onChanged: _savingBehaviorPreference ? null : _setWatchHistoryEnabled,
          secondary: const Icon(Icons.history_rounded),
          title: const Text('启用观看记录'),
          subtitle: const Text('关闭后不再新增或更新观看进度，已有记录会继续保留。'),
        ),
        if (_supportsClipboardDetection)
          SwitchListTile.adaptive(
            key: const Key('enable-windows-clipboard-link-detection'),
            value: _windowsClipboardDetectionEnabled,
            // 剪贴板开关只保存本机选择，关闭时根监听器不会读取任何内容。
            onChanged: _savingWindowsClipboardPreference
                ? null
                : _setWindowsClipboardDetectionEnabled,
            secondary: const Icon(Icons.content_paste_search_rounded),
            title: const Text('检测剪贴板中的 B站链接'),
            subtitle: const Text('仅在焦点哔哩位于前台时检查；发现可播放视频后先询问，不会自动打开。'),
          ),
      ],
    );
  }

  /// 创建“播放与专注”设置卡，集中播放器行为、清晰度和专注系统能力。
  Widget _buildPlaybackAndFocusSection() {
    final bool supportsDoNotDisturb =
        widget.focusNotificationService.supportsDoNotDisturb;
    return _buildSettingsSection(
      key: const Key('settings-playback-section'),
      icon: Icons.play_circle_outline_rounded,
      title: '播放与专注',
      children: <Widget>[
        _buildDefaultQualityTile(forWifi: true),
        _buildDefaultQualityTile(forWifi: false),
        SwitchListTile.adaptive(
          key: const Key('enable-double-tap-seek'),
          value: _preferences.enableDoubleTapSeek,
          // 双击开关函数立即更新界面并把选择保存到当前设备。
          onChanged: _saving ? null : _setDoubleTapSeekEnabled,
          secondary: const Icon(Icons.touch_app_outlined),
          title: const Text('启用双击快进快退'),
          subtitle: const Text('关闭后，双击视频画面的任何位置都会切换播放或暂停。'),
        ),
        if (supportsDoNotDisturb || _isWindows)
          SwitchListTile.adaptive(
            key: const Key('enable-focus-do-not-disturb'),
            value: _focusPreferences.enableDoNotDisturb,
            // 开关函数在 Android 保存自动勿扰选择，在 Windows 保存手动启动提醒选择。
            onChanged: _savingDoNotDisturb ? null : _setDoNotDisturbEnabled,
            secondary: const Icon(Icons.do_not_disturb_on_outlined),
            title: Text(_isWindows ? '开始时提醒开启 Windows 系统专注' : '专注状态将手机设为勿扰模式'),
            subtitle: _isWindows
                ? Text(
                    _focusPreferences.enableDoNotDisturb
                        ? '已开启提醒；请在 Windows“时钟”中手动启动系统专注。'
                        : '关闭后不再提醒；焦点哔哩不会修改 Windows 的全局通知设置。',
                  )
                : Text(
                    !_focusPreferences.enableDoNotDisturb
                        ? '关闭时不会修改手机的勿扰状态。'
                        : _hasDoNotDisturbAccess
                        ? '已授权；播放时开启，暂停或结束时恢复，快进不会反复切换。'
                        : '尚未授权；每次开始专注都会检查并提示。',
                  ),
          ),
      ],
    );
  }

  /// 创建“外观与应用”设置卡，把主题、权限、更新、缓存和版本入口集中展示。
  Widget _buildApplicationSection(
    AppUpdateController updateController,
    AppThemeModeController themeModeController,
  ) {
    final bool usesWindowsCapabilities =
        widget.focusNotificationService.usesWindowsBackend;
    final bool usesUnavailableCapabilities =
        widget.focusNotificationService.usesUnavailableBackend;
    return _buildSettingsSection(
      key: const Key('settings-application-section'),
      icon: Icons.tune_rounded,
      title: '外观与应用',
      children: <Widget>[
        _buildThemeModeTile(themeModeController),
        _buildThemeColorTile(themeModeController),
        ListTile(
          key: const Key('open-android-permissions'),
          leading: const Icon(Icons.admin_panel_settings_outlined),
          title: Text(
            usesWindowsCapabilities || usesUnavailableCapabilities
                ? '系统能力'
                : '权限管理',
          ),
          subtitle: Text(
            usesWindowsCapabilities
                ? '检查 Windows 通知、未来提醒和安装包身份'
                : usesUnavailableCapabilities
                ? '当前平台的系统能力尚未接入'
                : '统一申请、检查、取消权限，并设置后台提醒保护',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          // 权限管理入口函数打开统一页面，原有勿扰开关和功能内申请入口继续保留。
          onTap: () =>
              Navigator.of(context).pushNamed(AppRoutes.systemCapabilities),
        ),
        SwitchListTile.adaptive(
          key: const Key('enable-startup-update-check'),
          value: updateController.enabled,
          // 更新开关函数把用户选择交给全应用更新控制器保存。
          onChanged: _savingUpdatePreference
              ? null
              : (bool enabled) =>
                    _setUpdateCheckEnabled(updateController, enabled),
          secondary: const Icon(Icons.system_update_alt_rounded),
          title: const Text('启动时检查更新'),
          subtitle: const Text('每次启动从 GitHub Release 检查新的正式版本。'),
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('视频缓存管理'),
          subtitle: const Text('查看和清理边播边缓存的数据'),
          trailing: const Icon(Icons.chevron_right_rounded),
          // 缓存入口函数进入已有缓存管理页面，不把两种设置混在一个开关中。
          onTap: () =>
              Navigator.of(context).pushNamed(AppRoutes.cacheManagement),
        ),
        ListTile(
          key: const Key('open-about-page'),
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('关于'),
          subtitle: Text(
            updateController.hasUpdate &&
                    updateController.result.releaseHighlights.isNotEmpty
                ? '新版本：${updateController.result.releaseHighlights.first}'
                : '项目地址、负责人、版本与更新',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
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
          // 关于入口函数打开版本、项目地址和更新状态页面。
          onTap: () => Navigator.of(context).pushNamed(AppRoutes.about),
        ),
      ],
    );
  }

  /// 给一组设置项添加标题、图标和分隔线，手机与平板复用相同信息结构。
  Widget _buildSettingsSection({
    required Key key,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final List<Widget> separatedChildren = <Widget>[];
    for (int index = 0; index < children.length; index += 1) {
      separatedChildren.add(children[index]);
      if (index < children.length - 1) {
        separatedChildren.add(const Divider(height: 1));
      }
    }
    return Card(
      key: key,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: Icon(icon),
            title: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1),
          ...separatedChildren,
        ],
      ),
    );
  }

  /// 创建设置首页的单个分类入口，并显示该分类包含的主要内容。
  Widget _buildSettingsCategoryTile({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required _SettingsLevel level,
  }) {
    return ListTile(
      key: key,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      // 分类入口函数在当前设置路由内切换层级，保留已经加载的设置状态。
      onTap: () => setState(() => _settingsLevel = level),
    );
  }

  /// 创建由三个分类入口组成的设置首页。
  Widget _buildSettingsOverview() {
    return SingleChildScrollView(
      key: const Key('settings-overview-list'),
      padding: const EdgeInsets.all(16),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            _buildSettingsCategoryTile(
              key: const Key('open-account-privacy-settings'),
              icon: Icons.admin_panel_settings_outlined,
              title: '账号与隐私',
              subtitle: '账号只读、剪贴板与本机记录',
              level: _SettingsLevel.accountAndPrivacy,
            ),
            const Divider(height: 1),
            _buildSettingsCategoryTile(
              key: const Key('open-playback-focus-settings'),
              icon: Icons.play_circle_outline_rounded,
              title: '播放与专注',
              subtitle: '清晰度、播放器手势与专注模式',
              level: _SettingsLevel.playbackAndFocus,
            ),
            const Divider(height: 1),
            _buildSettingsCategoryTile(
              key: const Key('open-appearance-application-settings'),
              icon: Icons.tune_rounded,
              title: '外观与应用',
              subtitle: '主题、权限、更新、缓存与版本',
              level: _SettingsLevel.appearanceAndApplication,
            ),
          ],
        ),
      ),
    );
  }

  /// 根据当前层级创建设置首页或对应二级页面内容。
  Widget _buildSettingsBody(
    AppUpdateController updateController,
    AppThemeModeController themeModeController,
  ) {
    if (_settingsLevel == _SettingsLevel.overview) {
      return _buildSettingsOverview();
    }
    final Widget section = switch (_settingsLevel) {
      _SettingsLevel.accountAndPrivacy => _buildAccountAndPrivacySection(),
      _SettingsLevel.playbackAndFocus => _buildPlaybackAndFocusSection(),
      _SettingsLevel.appearanceAndApplication => _buildApplicationSection(
        updateController,
        themeModeController,
      ),
      _SettingsLevel.overview => const SizedBox.shrink(),
    };
    return SingleChildScrollView(
      key: const Key('settings-detail-page'),
      padding: const EdgeInsets.all(16),
      child: section,
    );
  }

  /// 返回当前层级对应的页面标题。
  String get _pageTitle {
    return switch (_settingsLevel) {
      _SettingsLevel.overview => '个性化设置',
      _SettingsLevel.accountAndPrivacy => '账号与隐私',
      _SettingsLevel.playbackAndFocus => '播放与专注',
      _SettingsLevel.appearanceAndApplication => '外观与应用',
    };
  }

  /// 二级页面收到返回操作时先回到设置首页，不立即退出整个设置路由。
  void _returnToSettingsOverview() {
    setState(() => _settingsLevel = _SettingsLevel.overview);
  }

  /// 处理系统返回键；仅在二级页面尚未弹出路由时切回设置首页。
  void _handleSettingsPop(bool didPop, Object? result) {
    if (!didPop && _settingsLevel != _SettingsLevel.overview) {
      _returnToSettingsOverview();
    }
  }

  /// 创建带分类首页和二级内容页的个性化设置页面。
  @override
  Widget build(BuildContext context) {
    final AppUpdateController updateController =
        AppUpdateScope.maybeOf(context) ?? _fallbackUpdateController;
    final AppThemeModeController themeModeController =
        AppThemeModeScope.maybeOf(context) ?? _fallbackThemeModeController;
    if (!updateController.loaded && !updateController.checking) {
      unawaited(updateController.initialize(checkOnStart: false));
    }
    return PopScope<Object?>(
      canPop: _settingsLevel == _SettingsLevel.overview,
      onPopInvokedWithResult: _handleSettingsPop,
      child: Scaffold(
        appBar: AppBar(
          leading: _settingsLevel == _SettingsLevel.overview
              ? null
              : IconButton(
                  key: const Key('settings-level-back-button'),
                  // 顶部返回函数回到设置首页，并保留本页已经加载的开关状态。
                  onPressed: _returnToSettingsOverview,
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回设置首页',
                ),
          title: Text(_pageTitle),
        ),
        body: AdaptivePageFrame(
          maxWidth: 900,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildSettingsBody(updateController, themeModeController),
        ),
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
    _fallbackThemeModeController
      ..removeListener(_handleFallbackThemeModeChanged)
      ..dispose();
    super.dispose();
  }
}
