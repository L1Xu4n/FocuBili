/// Distinguishes errors that require different actions within one media session.
enum WindowsPlaybackFailure { route, expired, videoDecoder, accessDenied }

/// 判断 Windows 播放器收到宽泛底层错误后是否真的需要切换 DASH 线路。
abstract final class WindowsPlaybackRecoveryPolicy {
  static const maxSourceRefreshes = 1;
  static final _httpStatus = RegExp(
    r'\b(?:http(?:/\d+(?:\.\d+)?)?(?:\s+(?:error|status(?:\s+code)?|returned))?\s*[:=]?\s*|server returned\s+)(401|403|410|451)\b',
  );
  static final _decoderFailure = RegExp(
    r'(?:could not|cannot|failed to|unable to|error (?:while )?)\s*(?:open|init(?:ialize|ialise)?|find)\b[^\n]*(?:decoder|codec)|'
    r'(?:decoder|codec)\b[^\n]*(?:initiali[sz]ation failed|failed to (?:init|open)|not found|not supported)|'
    r'failed to initialize a decoder for codec',
  );

  /// Uses HTTP status and explicitly video-scoped decoder errors only.
  static WindowsPlaybackFailure classify(String message, {String prefix = ''}) {
    final text = message.toLowerCase();
    switch (_httpStatus.firstMatch(text)?.group(1)) {
      case '403':
      case '410':
        return WindowsPlaybackFailure.expired;
      case '401':
      case '451':
        return WindowsPlaybackFailure.accessDenied;
    }
    final videoScoped =
        prefix.toLowerCase().split('/').last == 'vd' ||
        RegExp(r'\b(?:video|hevc|h26[45]|av1|av01|avc[13]?)\b').hasMatch(text);
    if (videoScoped &&
        !RegExp(
          r'\b(?:http|network|connection|timed? ?out|audio decoder)\b',
        ).hasMatch(text) &&
        _decoderFailure.hasMatch(text)) {
      return WindowsPlaybackFailure.videoDecoder;
    }
    return WindowsPlaybackFailure.route;
  }

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
