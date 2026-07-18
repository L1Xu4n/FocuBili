import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_preferences.dart';

/// 在设备本地读取和保存播放器个性化配置，不会上传任何用户偏好。
class PlaybackPreferencesService {
  /// 创建播放器配置服务；默认通过 SharedPreferences 保存开关。
  const PlaybackPreferencesService();

  static const String _doubleTapSeekKey =
      'playback_preferences.enable_double_tap_seek';

  /// 读取播放器配置；首次安装或旧版本没有该字段时默认开启双击快进快退。
  Future<PlaybackPreferences> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return PlaybackPreferences(
      enableDoubleTapSeek: preferences.getBool(_doubleTapSeekKey) ?? true,
    );
  }

  /// 保存双击手势开关，下一次进入播放器时继续沿用用户选择。
  Future<void> saveDoubleTapSeekEnabled(bool enabled) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_doubleTapSeekKey, enabled);
  }
}
