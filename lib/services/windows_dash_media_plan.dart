import 'package:media_kit/media_kit.dart';

import 'desktop_playback_source_service.dart';

/// 保存一次 Windows DASH 打开尝试使用的视频与可选外部音频 CDN 地址。
class WindowsDashMediaAttempt {
  /// 创建一个已由播放源服务完成域名校验的音视频地址组合。
  const WindowsDashMediaAttempt({
    required this.videoUrl,
    required this.audioUrl,
  });

  final String videoUrl;
  final String? audioUrl;

  /// 创建携带 Cookie、Referer 等必要请求头的视频 Media。
  Media createVideoMedia(Map<String, String> headers) {
    return Media(videoUrl, httpHeaders: headers);
  }

  /// 注册外部音频 URI 的请求头并创建轨道；没有独立音频时返回空。
  AudioTrack? createAudioTrack(Map<String, String> headers) {
    final String? url = audioUrl;
    if (url == null || url.isEmpty) {
      return null;
    }
    // media_kit 会按 URI 从 Media 缓存读取请求头，再由 mpv 的 on_load 钩子传给 audio-add。
    Media(url, httpHeaders: headers);
    return AudioTrack.uri(url, title: 'B站 DASH 音频', language: 'zh');
  }
}

/// 把播放源中的主备 CDN 排成有限且去重的自动重试顺序。
abstract final class WindowsDashMediaPlan {
  /// 先尝试主视频与主音频，再分别轮换视频、音频，最后补充同序号备线组合。
  static List<WindowsDashMediaAttempt> build(DesktopPlaybackSources sources) {
    if (sources.videoUrls.isEmpty) {
      return const <WindowsDashMediaAttempt>[];
    }
    final List<WindowsDashMediaAttempt> attempts = <WindowsDashMediaAttempt>[];
    final Set<String> keys = <String>{};
    final String primaryVideo = sources.videoUrls.first;
    final String? primaryAudio = sources.audioUrls.isEmpty
        ? null
        : sources.audioUrls.first;

    /// 添加尚未出现的安全地址组合，空音频使用空字符串参与去重但不会交给播放器。
    void add(String videoUrl, String? audioUrl) {
      final String key = '$videoUrl\u0000${audioUrl ?? ''}';
      if (keys.add(key)) {
        attempts.add(
          WindowsDashMediaAttempt(videoUrl: videoUrl, audioUrl: audioUrl),
        );
      }
    }

    add(primaryVideo, primaryAudio);
    for (final String videoUrl in sources.videoUrls.skip(1)) {
      add(videoUrl, primaryAudio);
    }
    for (final String audioUrl in sources.audioUrls.skip(1)) {
      add(primaryVideo, audioUrl);
    }
    final int pairedBackupCount =
        sources.videoUrls.length < sources.audioUrls.length
        ? sources.videoUrls.length
        : sources.audioUrls.length;
    for (int index = 1; index < pairedBackupCount; index += 1) {
      add(sources.videoUrls[index], sources.audioUrls[index]);
    }
    return List<WindowsDashMediaAttempt>.unmodifiable(attempts);
  }
}
