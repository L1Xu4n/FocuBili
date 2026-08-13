import 'package:media_kit/media_kit.dart';

import 'desktop_playback_source_service.dart';

/// 保存一次 Windows DASH 打开尝试使用的视频与外部音频 CDN 地址。
class WindowsDashMediaAttempt {
  /// 创建一个已由播放源服务完成域名校验的音视频地址组合。
  const WindowsDashMediaAttempt({
    required this.videoUrl,
    required this.audioUrl,
    required this.audioCodec,
  });

  final String videoUrl;
  final String audioUrl;
  final String audioCodec;

  /// 创建携带 Cookie、Referer 等必要请求头的视频 Media。
  Media createVideoMedia(Map<String, String> headers) {
    return Media(videoUrl, httpHeaders: headers);
  }

  /// 创建并返回带请求头的外部音频 Media。
  Media createAudioMedia(Map<String, String> headers) {
    return Media(audioUrl, httpHeaders: headers);
  }

  /// 根据已保留的音频 Media 和本次尝试的唯一标题创建外部音轨，供 libmpv 稳定确认当前音轨身份。
  AudioTrack createAudioTrack(Media audioMedia, {required String title}) {
    return AudioTrack.uri(audioMedia.uri, title: title, language: 'zh');
  }
}

/// 把播放源中的主备 CDN 排成有限且去重的自动重试顺序。
abstract final class WindowsDashMediaPlan {
  /// 先尝试主视频与兼容音频，再分别轮换视频、音频，最后补充同序号备线组合。
  static List<WindowsDashMediaAttempt> build(DesktopPlaybackSources sources) {
    if (sources.videoUrls.isEmpty || sources.audioUrls.isEmpty) {
      return const <WindowsDashMediaAttempt>[];
    }
    final List<WindowsDashMediaAttempt> attempts = <WindowsDashMediaAttempt>[];
    final Set<String> keys = <String>{};
    final String primaryVideo = sources.videoUrls.first;
    final String primaryAudio = sources.audioUrls.first;

    /// 添加尚未出现的安全音视频地址组合。
    void add(String videoUrl, String audioUrl) {
      final String key = '$videoUrl\u0000$audioUrl';
      if (keys.add(key)) {
        attempts.add(
          WindowsDashMediaAttempt(
            videoUrl: videoUrl,
            audioUrl: audioUrl,
            audioCodec: sources.audioCodecByUrl[audioUrl] ?? sources.audioCodec,
          ),
        );
      }
    }

    add(primaryVideo, primaryAudio);
    for (final String audioUrl in sources.audioUrls.skip(1)) {
      add(primaryVideo, audioUrl);
    }
    for (final String videoUrl in sources.videoUrls.skip(1)) {
      add(videoUrl, primaryAudio);
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
