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
  Media createVideoMedia(Map<String, String> headers, {Duration? start}) {
    return Media(videoUrl, httpHeaders: headers, start: start);
  }

  /// 创建并返回带请求头的外部音频 Media。
  Media createAudioMedia(Map<String, String> headers, {Duration? start}) {
    return Media(audioUrl, httpHeaders: headers, start: start);
  }

  /// 根据已保留的音频 Media 和本次尝试的唯一标题创建外部音轨，供 libmpv 稳定确认当前音轨身份。
  AudioTrack createAudioTrack(Media audioMedia, {required String title}) {
    return AudioTrack.uri(audioMedia.uri, title: title, language: 'zh');
  }
}

/// 把播放源中的主备 CDN 排成有限且去重的自动重试顺序。
abstract final class WindowsDashMediaPlan {
  // Each failed media attempt can involve a decoder timeout. Keep the extra
  // work bounded even when the API supplies many CDNs or audio representations.
  static const _maxMixedBackupAttempts = 4;

  /// 先尝试首选、同序备线和单侧替换，再有限地补试不同序号的备线。
  static List<WindowsDashMediaAttempt> build(
    DesktopPlaybackSources sources, {
    DesktopVideoAlternative? video,
  }) {
    final videos = (video?.urls ?? sources.videoUrls).toSet().toList();
    final audios = sources.audioUrls.toSet().toList();
    if (sources.videoCodec == 'muxed' && audios.isEmpty) {
      return List.unmodifiable([
        for (final url in videos)
          WindowsDashMediaAttempt(videoUrl: url, audioUrl: '', audioCodec: ''),
      ]);
    }
    if (videos.isEmpty || audios.isEmpty) {
      return const <WindowsDashMediaAttempt>[];
    }
    final List<WindowsDashMediaAttempt> attempts = <WindowsDashMediaAttempt>[];
    final String primaryVideo = videos.first;
    final String primaryAudio = audios.first;

    /// Adds a route for this representation with the selected audio's codec.
    void add(String videoUrl, String audioUrl) {
      attempts.add(
        WindowsDashMediaAttempt(
          videoUrl: videoUrl,
          audioUrl: audioUrl,
          audioCodec: sources.audioCodecByUrl[audioUrl] ?? sources.audioCodec,
        ),
      );
    }

    add(primaryVideo, primaryAudio);
    final int pairedCount = videos.length < audios.length
        ? videos.length
        : audios.length;
    for (int index = 1; index < pairedCount; index += 1) {
      add(videos[index], audios[index]);
    }
    for (final String audioUrl in audios.skip(1)) {
      add(primaryVideo, audioUrl);
    }
    for (final String videoUrl in videos.skip(1)) {
      add(videoUrl, primaryAudio);
    }
    var mixedBackups = 0;
    // Iterate by combined rank, not by a full Cartesian product.
    if (videos.length > 1 && audios.length > 1) {
      crossBackup:
      for (var sum = 3; sum <= videos.length + audios.length - 2; sum++) {
        final firstVideo = (sum - audios.length + 1).clamp(1, videos.length);
        for (var v = firstVideo; v < videos.length && v < sum; v++) {
          final a = sum - v;
          if (v == a) continue;
          add(videos[v], audios[a]);
          if (++mixedBackups == _maxMixedBackupAttempts) break crossBackup;
        }
      }
    }
    return List<WindowsDashMediaAttempt>.unmodifiable(attempts);
  }
}
