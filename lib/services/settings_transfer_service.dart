import 'video_tag_preferences.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/danmaku_preferences.dart';
import '../models/playback_preferences.dart';
import '../models/search_content_filter.dart';
import 'app_behavior_preferences_service.dart';
import 'app_theme_mode_service.dart';
import 'app_text_scale_service.dart';
import 'content_blocklist_service.dart';
import 'image_resource_cache.dart';
import 'media_cache_service.dart';
import 'playback_preferences_service.dart';
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
    AppBehaviorPreferencesService.noteMarkdownEnabledKey: _SettingType.boolean,
    VideoTagPreferences.key: _SettingType.text,
    'appearance.theme_mode': _SettingType.text,
    'appearance.theme_color': _SettingType.integer,
    'appearance.text_scale': _SettingType.decimal,
    'appearance.layout_orientation': _SettingType.text,
    'app_update.check_on_start': _SettingType.boolean,
    'app_update.ignored_release': _SettingType.text,
    'windows_clipboard_link_detection.enabled': _SettingType.boolean,
    'focus_preferences.enable_do_not_disturb': _SettingType.boolean,
    'playback_preferences.enable_double_tap_seek': _SettingType.boolean,
    'playback_preferences.speeds': _SettingType.stringList,
    'playback_preferences.line_preference': _SettingType.text,
    'playback_preferences.mode': _SettingType.text,
    'playback_preferences.subtitle_position': _SettingType.decimal,
    PlaybackPreferencesService.subtitleOpacityKey: _SettingType.decimal,
    PlaybackPreferencesService.autoEnableSubtitlesKey: _SettingType.boolean,
    PlaybackPreferencesService.subtitlePriorityKey: _SettingType.text,
    'playback_preferences.app_volume': _SettingType.decimal,
    'playback_preferences.prefer_non_pcdn': _SettingType.boolean,
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
    'dashboard.home_drawer_enabled': _SettingType.boolean,
    'dashboard.layout.profile': _SettingType.json,
    'windows_media_cache_capacity_bytes': _SettingType.integer,
    'search.content_filter_v2': _SettingType.json,
    DeviceSettingsRuntimeAdapter.enabledKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.notificationsKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.backgroundKey: _SettingType.boolean,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: _SettingType.integer,
  };

  // ZIP restore is deliberately narrower than the overwrite-style settings
  // JSON import. This list is explicit so future export keys cannot silently
  // enable a device integration, affect accounts, or trim caches on restore.
  static const _portableZipKeys = <String>{
    'app_behavior.search_history_enabled',
    'app_behavior.watch_history_enabled',
    AppBehaviorPreferencesService.noteMarkdownEnabledKey,
    VideoTagPreferences.key,
    'appearance.theme_mode',
    'appearance.theme_color',
    'appearance.layout_orientation',
    'playback_preferences.enable_double_tap_seek',
    'playback_preferences.speeds',
    'playback_preferences.line_preference',
    'playback_preferences.mode',
    'playback_preferences.subtitle_position',
    PlaybackPreferencesService.subtitleOpacityKey,
    PlaybackPreferencesService.autoEnableSubtitlesKey,
    PlaybackPreferencesService.subtitlePriorityKey,
    'playback_preferences.app_volume',
    'playback_preferences.prefer_non_pcdn',
    'playback_preferences.long_press_speed',
    'playback_preferences.double_tap_regions',
    'playback_preferences.action_animation',
    'playback_preferences.control_scale',
    'playback_preferences.show_note_time_markers',
    'playback_preferences.subtitle_font_size',
    'playback_preferences.two_finger_video_transform',
    'playback_preferences.prefer_offline_cache',
    'playback_preferences.wifi_default_quality',
    'playback_preferences.mobile_default_quality',
    'focubili_danmaku_preferences_v1',
    'dashboard.layout.home',
    'dashboard.home_drawer_enabled',
    'dashboard.layout.profile',
    'search.content_filter_v2',
    ContentBlocklistService.storageKey,
  };

  static bool isPortableZipKey(String key) => _portableZipKeys.contains(key);

  static void validatePortableZipValue(String key, Object? value) {
    if (value == null || !isPortableZipKey(key)) {
      throw const FormatException('不支持的备份设置');
    }
    if (key == ContentBlocklistService.storageKey) {
      if (value is! String || value.length > 200000) {
        throw const FormatException('屏蔽列表格式不正确');
      }
      ContentBlocklistService.validateBackup(value);
    } else {
      _validateValue(key, value);
    }
  }

  /// Adds only absent portable keys. Present values (including explicitly
  /// saved defaults) are never replaced by the archive.
  Future<int> importMissingZipSettings(Map<String, Object> values) {
    final snapshot = _snapshot(values);
    return _enqueue(() async {
      for (final entry in snapshot.entries) {
        validatePortableZipValue(entry.key, entry.value);
      }
      if (snapshot.isEmpty) return 0;
      Future<int> apply() => _apply(snapshot, onlyMissing: true);
      return snapshot.containsKey(ContentBlocklistService.storageKey)
          ? ContentBlocklistService.serializeWrites(apply)
          : apply();
    });
  }

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

  /// 在将较大文本放进编辑框或 JSON 解码器前检查与文件相同的 UTF-8 上限。
  static bool fitsTransferLimit(String source) =>
      source.length <= maximumBytes &&
      (source.length <= maximumBytes ~/ 3 ||
          utf8.encode(source).length <= maximumBytes);

  /// 完整验证导入文件后返回待确认设置，未知键和错误类型不写入磁盘。
  Map<String, Object> parseSettings(String source) {
    if (!fitsTransferLimit(source)) {
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
  Future<void> importSettings(Map<String, Object> values) {
    // Freeze the confirmed input before entering the queue or awaiting storage.
    // The only supported collection value is a list of primitive strings.
    final snapshot = _snapshot(values);
    return _enqueue(() async {
      for (final entry in snapshot.entries) {
        _validateValue(entry.key, entry.value);
      }
      await _apply(snapshot);
    });
  }

  /// 只移除设置白名单，保留账号、协议状态、订阅源、笔记、清单和历史记录。
  Future<void> resetSettings() => _enqueue(() async {
    await _apply({for (final key in _schema.keys) key: null});
  });

  static Map<String, Object> _snapshot(Map<String, Object> settings) =>
      Map.unmodifiable({
        for (final entry in settings.entries)
          entry.key: entry.value is List
              ? List<Object?>.unmodifiable(entry.value as List)
              : entry.value,
      });

  /// 串行化导入和重置，前一次失败不会阻止下一次恢复操作。
  Future<T> _enqueue<T>(Future<T> Function() operation) {
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
    if (key == DeviceSettingsRuntimeAdapter.imageCapacityKey &&
        (value as int) >
            ImageResourceCache.capacities.reduce(math.max) * 1024 * 1024) {
      throw const FormatException('图片缓存容量超出支持范围');
    }
    if (key == 'appearance.theme_color' &&
        !AppThemeModeService.isSupportedColorValue(value as int)) {
      throw const FormatException('主题颜色无效');
    }
    if (key == 'windows_media_cache_capacity_bytes' &&
        !supportedMediaCacheBytes.contains(value)) {
      throw const FormatException('视频缓存容量无效');
    }
    if (key == 'playback_preferences.line_preference' &&
        !PlaybackLinePreference.values.any((item) => item.name == value)) {
      throw const FormatException('播放线路偏好无效');
    }
    if (key == PlaybackPreferencesService.subtitlePriorityKey &&
        !SubtitlePriority.values.any((priority) => priority.name == value)) {
      throw const FormatException('字幕优先级无效');
    }
    if (key == 'playback_preferences.speeds') {
      final speeds = (value as List)
          .map((item) => double.parse(item as String))
          .toList();
      final normalized = PlaybackPreferences.normalizeSpeeds(speeds);
      if (speeds.any((speed) => !normalized.contains(speed))) {
        throw const FormatException('播放速度无效');
      }
    }
    final normalizedPlaybackNumber = switch (key) {
      PlaybackPreferencesService.subtitlePositionKey =>
        PlaybackPreferences.normalizeSubtitlePosition(
          (value as num).toDouble(),
        ),
      PlaybackPreferencesService.subtitleOpacityKey =>
        PlaybackPreferences.normalizeSubtitleOpacity((value as num).toDouble()),
      'playback_preferences.app_volume' => DoubleTapRegions.normalize(
        (value as num).toDouble(),
        0,
        1,
        1,
      ),
      'appearance.text_scale' => AppTextScaleService.normalize(
        (value as num).toDouble(),
      ),
      'playback_preferences.long_press_speed' =>
        PlaybackPreferences.normalizeLongPressPlaybackSpeed(
          (value as num).toDouble(),
        ),
      'playback_preferences.control_scale' =>
        PlaybackPreferences.normalizeControlScale((value as num).toDouble()),
      'playback_preferences.subtitle_font_size' =>
        PlaybackPreferences.normalizeSubtitleFontSize(
          (value as num).toDouble(),
        ),
      _ => null,
    };
    if (normalizedPlaybackNumber != null && normalizedPlaybackNumber != value) {
      throw const FormatException('播放器设置数值无效');
    }
    if ((key == 'playback_preferences.wifi_default_quality' ||
            key == 'playback_preferences.mobile_default_quality') &&
        PreferredPlaybackQuality.fromId(value as int).id != value) {
      throw const FormatException('默认清晰度无效');
    }
    if (key == VideoTagPreferences.key &&
        !VideoTagMode.values.any((m) => m.name == value)) {
      throw const FormatException('视频标签模式无效');
    }
    if (key == 'appearance.theme_mode' &&
        !{'light', 'dark', 'system'}.contains(value)) {
      throw const FormatException('主题模式无效');
    }
    if (key == 'playback_preferences.mode' &&
        !PlaybackMode.values.any((mode) => mode.name == value)) {
      throw const FormatException('播放模式无效');
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
        for (final entry in DoubleTapRegions.fromMap(decoded).toMap().entries) {
          if (decoded[entry.key] != entry.value) {
            throw const FormatException('双击区域范围无效');
          }
        }
      } else if (key == 'search.content_filter_v2') {
        SearchContentFilter.fromJsonStrict(decoded);
      } else {
        final fields = DanmakuPreferences().toJson();
        for (final entry in decoded.entries) {
          final item = entry.value;
          final valid = switch (fields[entry.key]) {
            bool() => item is bool,
            num() => item is num && item.isFinite,
            List() => item is List && item.every((value) => value is String),
            // Preserve the existing extension-field policy and optional fields.
            _ => item is bool || item is num || item is List,
          };
          if (!valid) {
            throw const FormatException('弹幕设置结构无效');
          }
        }
        final normalized = DanmakuPreferences.fromJson(decoded).toJson();
        for (final entry in decoded.entries) {
          final field = fields[entry.key];
          if (field is num) {
            // Preserve the model's documented finite-number -> integer policy
            // for laneCount; reject range clamping, not that conversion.
            final actual = field is int
                ? (entry.value as num).toInt()
                : entry.value;
            if (normalized[entry.key] != actual) {
              throw const FormatException('弹幕设置数值无效');
            }
          }
        }
      }
    }
  }

  /// 保存一组设置并检查平台返回值，失败时尽力恢复全部旧值并报告状态。
  Future<int> _apply(
    Map<String, Object?> values, {
    bool onlyMissing = false,
  }) async {
    final preferences = await preferencesLoader();
    if (onlyMissing) await preferences.reload();
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
    final old = <String, Object?>{};
    final oldRuntime = runtime.isEmpty
        ? <String, Object>{}
        : await runtimeAdapter.readSettings();
    try {
      for (final entry in regular.entries) {
        final previous = preferences.get(entry.key);
        if (onlyMissing && previous != null) continue;
        // Include the failing key in rollback: SharedPreferences may update
        // its cache before a rejected platform write.
        old[entry.key] = previous;
        if (!await _write(preferences, entry.key, entry.value)) {
          throw StateError('设置写入失败');
        }
      }
      if (runtime.isNotEmpty) await runtimeAdapter.writeSettings(runtime);
      // The ZIP flow asks for a restart. Live widget listeners for tags and
      // block rules can fetch more content; do not trigger them during restore.
      if (!onlyMissing) {
        if (old.containsKey(VideoTagPreferences.key)) {
          VideoTagPreferences.changes.value++;
        }
        if (old.containsKey(
          AppBehaviorPreferencesService.noteMarkdownEnabledKey,
        )) {
          AppBehaviorPreferencesService.changes.value++;
        }
      }
      return old.length;
    } catch (_) {
      var restored = true;
      if (onlyMissing) {
        try {
          // Do not undo a newer app edit while rolling back ZIP additions.
          // Reload first because a failed setter can leave a provisional value.
          await preferences.reload();
        } catch (_) {
          throw StateError('保存与恢复未全部成功，请检查设置后重试');
        }
      }
      for (final entry in old.entries.toList().reversed) {
        try {
          if (onlyMissing &&
              !_sameValue(preferences.get(entry.key), values[entry.key])) {
            continue;
          }
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

  static bool _sameValue(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
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
