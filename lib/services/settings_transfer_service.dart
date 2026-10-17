import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_runtime_adapter.dart';

/// 定义允许迁移的基础偏好类型，账号、协议和学习数据从不进入白名单。
enum _SettingType { boolean, integer, decimal, text, stringList, json }

/// 将偏好设置与账号、历史、订阅源和学习数据隔离迁移。
class SettingsTransferService {
  /// 创建可注入内存存储的设置迁移服务。
  const SettingsTransferService({
    this.preferencesLoader = SharedPreferences.getInstance,
    this.runtimeAdapter = const DeviceSettingsRuntimeAdapter(),
  });
  final Future<SharedPreferences> Function() preferencesLoader;
  final SettingsRuntimeAdapter runtimeAdapter;
  static Future<void> _writes = Future.value();
  static const maximumBytes = 2 * 1024 * 1024;
  static const _schema = <String, _SettingType>{
    'app_behavior.account_read_only': _SettingType.boolean,
    'app_behavior.search_history_enabled': _SettingType.boolean,
    'app_behavior.watch_history_enabled': _SettingType.boolean,
    'app_behavior.wbi_signing_enabled': _SettingType.boolean,
    'appearance.theme_mode': _SettingType.text,
    'appearance.theme_color': _SettingType.integer,
    'appearance.layout_orientation': _SettingType.text,
    'app_update.check_on_start': _SettingType.boolean,
    'app_update.ignored_release': _SettingType.text,
    'windows_clipboard_link_detection.enabled': _SettingType.boolean,
    'focus_preferences.enable_do_not_disturb': _SettingType.boolean,
    'playback_preferences.enable_double_tap_seek': _SettingType.boolean,
    'playback_preferences.speeds': _SettingType.stringList,
    'playback_preferences.long_press_speed': _SettingType.decimal,
    'playback_preferences.double_tap_regions': _SettingType.json,
    'playback_preferences.action_animation': _SettingType.boolean,
    'playback_preferences.control_scale': _SettingType.decimal,
    'playback_preferences.show_note_time_markers': _SettingType.boolean,
    'playback_preferences.subtitle_font_size': _SettingType.decimal,
    'playback_preferences.two_finger_video_transform': _SettingType.boolean,
    'playback_preferences.prefer_offline_cache': _SettingType.boolean,
    'playback_preferences.wifi_default_quality': _SettingType.integer,
    'playback_preferences.mobile_default_quality': _SettingType.integer,
    'focubili_danmaku_preferences_v1': _SettingType.json,
    'dashboard.layout.home': _SettingType.json,
    'dashboard.layout.profile': _SettingType.json,
    'windows_media_cache_capacity_bytes': _SettingType.integer,
    'search.content_filter_v2': _SettingType.json,
    DeviceSettingsRuntimeAdapter.enabledKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.notificationsKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.backgroundKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: _SettingType.integer,
  };

  /// 仅导出明确支持的设置，保留格式版本供将来升级兼容。
  Future<String> exportSettings() async {
    await _writes;
    final preferences = await preferencesLoader();
    final values = <String, Object>{};
    for (final key in _schema.keys) {
      if (DeviceSettingsRuntimeAdapter.keys.contains(key)) continue;
      final value = preferences.get(key);
      if (value != null) {
        _validateValue(key, value);
        values[key] = value;
      }
    }
    for (final entry in (await runtimeAdapter.readSettings()).entries) {
      _validateValue(entry.key, entry.value);
      values[entry.key] = entry.value;
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'focubili-settings',
      'schemaVersion': 1,
      'settings': values,
    });
  }

  /// 完整验证导入文件后返回待确认设置，未知键和错误类型不写入磁盘。
  Map<String, Object> parseSettings(String source) {
    if (utf8.encode(source).length > maximumBytes) {
      throw const FormatException('设置文件过大');
    }
    final root = jsonDecode(source);
    if (root is! Map ||
        root['format'] != 'focubili-settings' ||
        root['schemaVersion'] != 1 ||
        root['settings'] is! Map) {
      throw const FormatException('不是受支持的焦点哔哩设置文件');
    }
    final values = <String, Object>{};
    for (final entry in (root['settings'] as Map).entries) {
      if (entry.key is! String ||
          entry.value == null ||
          !_schema.containsKey(entry.key)) {
        throw const FormatException('设置文件包含不支持的项目');
      }
      _validateValue(entry.key as String, entry.value as Object);
      values[entry.key as String] = entry.value as Object;
    }
    return Map.unmodifiable(values);
  }

  /// 合并已验证设置；缺失项目保持原值，失败时恢复本次触及的旧值。
  Future<void> importSettings(Map<String, Object> values) => _enqueue(() async {
    for (final entry in values.entries) {
      _validateValue(entry.key, entry.value);
    }
    await _apply(values);
  });

  /// 只移除设置白名单，保留账号、协议状态、订阅源、笔记、清单和历史记录。
  Future<void> resetSettings() =>
      _enqueue(() => _apply({for (final key in _schema.keys) key: null}));

  /// 串行化导入和重置，前一次失败不会阻止下一次恢复操作。
  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 检查白名单、基础类型以及带 JSON 配置的结构，阻止损坏数据进入现有读取服务。
  static void _validateValue(String key, Object value) {
    final valid = switch (_schema[key]) {
      _SettingType.boolean => value is bool,
      _SettingType.integer =>
        value is int && value >= 0 && value <= 0x7fffffffffffffff,
      _SettingType.decimal =>
        value is num && value.isFinite && value >= 0 && value <= 100,
      _SettingType.text => value is String && value.length <= 512,
      _SettingType.stringList =>
        value is List &&
            value.length <= 50 &&
            value.every(
              (item) =>
                  item is String &&
                  item.length <= 20 &&
                  double.tryParse(item)?.isFinite == true,
            ),
      _SettingType.json => value is String && value.length <= 200000,
      null => false,
    };
    if (!valid) throw const FormatException('设置类型或范围不正确');
    if (key == 'appearance.theme_mode' &&
        !{'light', 'dark', 'system'}.contains(value)) {
      throw const FormatException('主题模式无效');
    }
    if (key == 'appearance.layout_orientation' &&
        !{'adaptive', 'portrait', 'landscape'}.contains(value)) {
      throw const FormatException('布局模式无效');
    }
    if (key == 'app_update.ignored_release') {
      final decoded = jsonDecode(value as String);
      if (decoded is! List ||
          decoded.length != 4 ||
          !decoded.every((item) => item is String && item.length <= 120)) {
        throw const FormatException('忽略更新设置无效');
      }
    }
    if (_schema[key] == _SettingType.json) {
      final decoded = jsonDecode(value as String);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('设置结构无效');
      }
      if (key.startsWith('dashboard.layout.')) {
        for (final name in ['order', 'hidden']) {
          if (decoded[name] is! List ||
              (decoded[name] as List).length > 100 ||
              !(decoded[name] as List).every(
                (item) => item is String && item.length <= 100,
              )) {
            throw const FormatException('布局结构无效');
          }
        }
      } else if (key.endsWith('double_tap_regions')) {
        if (!['leftWidth', 'rightWidth', 'height'].every(
          (name) => decoded[name] is num && (decoded[name] as num).isFinite,
        )) {
          throw const FormatException('双击区域结构无效');
        }
      } else if (key == 'search.content_filter_v2') {
        if (decoded['learningOnly'] is! bool ||
            decoded['minimumPlayCount'] is! int ||
            (decoded['minimumPlayCount'] as int) < 0) {
          throw const FormatException('搜索筛选结构无效');
        }
      } else {
        for (final entry in decoded.entries) {
          if (entry.value is! bool &&
              entry.value is! num &&
              entry.value is! List) {
            throw const FormatException('弹幕设置结构无效');
          }
        }
      }
    }
  }

  /// 保存一组设置并检查平台返回值，失败时尽力恢复全部旧值并报告状态。
  Future<void> _apply(Map<String, Object?> values) async {
    final preferences = await preferencesLoader();
    final runtime = {
      for (final entry in values.entries)
        if (DeviceSettingsRuntimeAdapter.keys.contains(entry.key))
          entry.key: entry.value,
    };
    final regular = {
      for (final entry in values.entries)
        if (!DeviceSettingsRuntimeAdapter.keys.contains(entry.key))
          entry.key: entry.value,
    };
    final old = {for (final key in regular.keys) key: preferences.get(key)};
    final oldRuntime = runtime.isEmpty
        ? <String, Object>{}
        : await runtimeAdapter.readSettings();
    try {
      for (final entry in regular.entries) {
        if (!await _write(preferences, entry.key, entry.value)) {
          throw StateError('设置写入失败');
        }
      }
      if (runtime.isNotEmpty) await runtimeAdapter.writeSettings(runtime);
    } catch (_) {
      var restored = true;
      for (final entry in old.entries) {
        try {
          if (!await _write(preferences, entry.key, entry.value)) {
            restored = false;
          }
        } catch (_) {
          restored = false;
        }
      }
      if (runtime.isNotEmpty) {
        try {
          await runtimeAdapter.writeSettings({
            for (final key in runtime.keys) key: oldRuntime[key],
          });
        } catch (_) {
          restored = false;
        }
      }
      await preferences.reload();
      throw StateError(restored ? '保存失败，已恢复原设置' : '保存与恢复未全部成功，请检查设置后重试');
    }
  }

  /// 根据白名单类型调用对应的偏好写入方法，不允许清空整个偏好容器。
  static Future<bool> _write(
    SharedPreferences preferences,
    String key,
    Object? value,
  ) => switch (value) {
    null => preferences.remove(key),
    final bool item => preferences.setBool(key, item),
    final int item =>
      _schema[key] == _SettingType.decimal
          ? preferences.setDouble(key, item.toDouble())
          : preferences.setInt(key, item),
    final double item => preferences.setDouble(key, item),
    final String item => preferences.setString(key, item),
    final List item => preferences.setStringList(key, item.cast<String>()),
    _ => throw const FormatException('设置类型无效'),
  };
}
