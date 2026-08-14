/// 判断 Windows 播放器收到宽泛底层错误后是否真的需要切换 DASH 线路。
abstract final class WindowsPlaybackRecoveryPolicy {
  /// 音视频已经解码且没有缓冲时保留当前线路；打开中或任一输出失效时才允许恢复流程介入。
  static bool shouldSwitchAfterPlayerError({
    required bool isOpening,
    required bool isBuffering,
    required bool hasVideoOutput,
    required bool hasDecodedAudio,
  }) {
    if (isOpening) {
      return false;
    }
    return isBuffering || !hasVideoOutput || !hasDecodedAudio;
  }
}
