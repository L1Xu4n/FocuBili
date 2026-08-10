import 'dart:io';

import 'native_playback_service.dart';
import 'windows_playback_service.dart';

/// 根据当前系统创建 Android Media3 或 Windows media_kit 播放服务。
PlaybackService createDefaultPlaybackService() {
  if (Platform.isWindows) {
    return WindowsPlaybackService();
  }
  return NativePlaybackService();
}
