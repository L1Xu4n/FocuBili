import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_preferences.dart';

/// 在设备本地读取和保存播放器个性化配置，不会上传任何用户偏好。
class PlaybackPreferencesService {
  /// 创建播放器配置服务；默认通过 SharedPreferences 保存开关。
  const PlaybackPreferencesService();

  static const String _doubleTapSeekKey =
      'playback_preferences.enable_double_tap_seek';
  static const _speedsKey = 'playback_preferences.speeds';
  static const _regionsKey = 'playback_preferences.double_tap_regions';
  static const _actionAnimationKey = 'playback_preferences.action_animation';
  static const _controlScaleKey = 'playback_preferences.control_scale';
  static const _noteMarkersKey = 'playback_preferences.show_note_time_markers';
  static const _subtitleFontSizeKey = 'playback_preferences.subtitle_font_size';
  static const _twoFingerTransformKey =
      'playback_preferences.two_finger_video_transform';
  static const _preferOfflineCacheKey =
      'playback_preferences.prefer_offline_cache';
  static const String _wifiDefaultQualityKey =
      'playback_preferences.wifi_default_quality';
  static const String _mobileDefaultQualityKey =
      'playback_preferences.mobile_default_quality';

  /// 读取播放器配置；首次安装或旧版本没有该字段时默认开启双击快进快退。
  Future<PlaybackPreferences> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return PlaybackPreferences(
      playbackSpeeds: PlaybackPreferences.normalizeSpeeds(
        preferences
                .getStringList(_speedsKey)
                ?.map((value) => double.tryParse(value) ?? double.nan) ??
            PlaybackPreferences.defaultSpeeds,
      ),
      preferOfflineCache: preferences.getBool(_preferOfflineCacheKey) ?? false,
      enableDoubleTapSeek: preferences.getBool(_doubleTapSeekKey) ?? true,
      doubleTapRegions: _readDoubleTapRegions(
        preferences.getString(_regionsKey),
      ),
      showPlaybackActionAnimation:
          preferences.getBool(_actionAnimationKey) ?? true,
      controlScale: PlaybackPreferences.normalizeControlScale(
        switch (preferences.get(_controlScaleKey)) {
          final num value => value.toDouble(),
          _ => PlaybackPreferences.defaultControlScale,
        },
      ),
      showNoteTimeMarkers: preferences.getBool(_noteMarkersKey) ?? true,
      subtitleFontSize: PlaybackPreferences.normalizeSubtitleFontSize(
        switch (preferences.get(_subtitleFontSizeKey)) {
          final num value => value.toDouble(),
          _ => PlaybackPreferences.defaultSubtitleFontSize,
        },
      ),
      enableTwoFingerVideoTransform:
          preferences.getBool(_twoFingerTransformKey) ?? true,
      wifiDefaultQuality: PreferredPlaybackQuality.fromId(
        preferences.getInt(_wifiDefaultQualityKey),
      ),
      mobileDefaultQuality: PreferredPlaybackQuality.fromId(
        preferences.getInt(_mobileDefaultQualityKey),
      ),
    );
  }

  /// 安全读取区域 JSON；旧版本和损坏配置均恢复默认范围。
  DoubleTapRegions _readDoubleTapRegions(String? value) {
    try {
      final decoded = value == null ? null : jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return DoubleTapRegions.fromMap(decoded);
      }
    } catch (_) {
      // 无效配置不阻止进入播放器。
    }
    return const DoubleTapRegions();
  }

  /// 保存完整区域配置，并让编辑器在写入失败时继续保留草稿。
  Future<void> saveDoubleTapRegions(DoubleTapRegions regions) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(
      _regionsKey,
      jsonEncode(regions.copyWith().toMap()),
    )) {
      throw StateError('双击触发区域保存失败');
    }
  }

  /// 保存播放暂停动画开关；首次安装默认开启。
  Future<void> savePlaybackActionAnimation(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_actionAnimationKey, enabled)) {
      throw StateError('播放暂停动画设置保存失败');
    }
  }

  /// 保存播放栏比例；写入失败让预览窗口保留草稿供重试。
  Future<void> saveControlScale(double scale) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setDouble(
      _controlScaleKey,
      PlaybackPreferences.normalizeControlScale(scale),
    )) {
      throw StateError('播放栏大小保存失败');
    }
  }

  /// 保存字幕字号并检查写入结果，失败时由字幕设置恢复最近成功的字号。
  Future<void> saveSubtitleFontSize(double fontSize) async {
    final preferences = await SharedPreferences.getInstance();
    try {
      if (await preferences.setDouble(
        _subtitleFontSizeKey,
        PlaybackPreferences.normalizeSubtitleFontSize(fontSize),
      )) {
        return;
      }
    } catch (_) {
      // 下面统一从磁盘恢复偏好缓存，避免失败值被下一次读取误当作成功值。
    }
    try {
      await preferences.reload();
    } catch (_) {
      // 平台存储不可读时由播放器维持最近一次成功值并提示用户。
    }
    throw StateError('字幕字号保存失败');
  }

  /// 立即保存笔记标记开关；写入失败交给设置页恢复原值。
  Future<void> saveShowNoteTimeMarkers(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_noteMarkersKey, enabled)) {
      throw StateError('笔记时间标记设置保存失败');
    }
  }

  /// Saves the fullscreen two-finger switch and rejects unsuccessful disk writes.
  Future<void> saveTwoFingerVideoTransformEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_twoFingerTransformKey, enabled)) {
      throw StateError('Two-finger video transform preference was not saved');
    }
  }

  /// Saves sanitized speed choices while retaining 1x and checking disk failures.
  Future<void> savePlaybackSpeeds(List<double> speeds) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setStringList(
      _speedsKey,
      PlaybackPreferences.normalizeSpeeds(
        speeds,
      ).map((speed) => speed.toString()).toList(),
    )) {
      throw StateError('Playback speeds were not saved');
    }
  }

  /// Saves source priority and reports rejected disk writes to the settings page.
  Future<void> savePreferOfflineCache(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_preferOfflineCacheKey, enabled)) {
      throw StateError('Playback source preference was not saved');
    }
  }

  /// 保存双击手势开关，下一次进入播放器时继续沿用用户选择。
  Future<void> saveDoubleTapSeekEnabled(bool enabled) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_doubleTapSeekKey, enabled);
  }

  /// 保存 Wi-Fi 或有线网络默认清晰度，下一次打开播放器时生效。
  Future<void> saveWifiDefaultQuality(PreferredPlaybackQuality quality) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_wifiDefaultQualityKey, quality.id);
  }

  /// 保存移动网络默认清晰度，避免与 Wi-Fi 选择互相覆盖。
  Future<void> saveMobileDefaultQuality(
    PreferredPlaybackQuality quality,
  ) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_mobileDefaultQualityKey, quality.id);
  }
}
