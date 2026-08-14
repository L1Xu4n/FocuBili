/// 提供跨 Flutter 播放后端共享的续播位置校验规则。
abstract final class PlaybackResumePolicy {
  static const Duration completedRemainingThreshold = Duration(seconds: 3);

  /// 校验本机保存的进度：时长未知、位置越界或距结尾三秒时统一从头播放。
  static Duration normalizeStoredPosition(
    Duration position,
    Duration duration,
  ) {
    if (position <= Duration.zero || duration <= Duration.zero) {
      return Duration.zero;
    }
    final Duration clampedPosition = position > duration ? duration : position;
    if (duration - clampedPosition <= completedRemainingThreshold) {
      return Duration.zero;
    }
    return clampedPosition;
  }

  /// 校验用户明确指定的位置；只拦截负数，最终上限交给掌握真实时长的播放器裁剪。
  static Duration normalizeRequestedPosition(Duration position) {
    if (position <= Duration.zero) {
      return Duration.zero;
    }
    return position;
  }
}
