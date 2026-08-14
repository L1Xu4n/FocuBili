import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_dash_media_plan.dart';

/// 创建带两条视频和两条音频线路的固定播放源，测试不会访问真实网络。
DesktopPlaybackSources _createSources() {
  return const DesktopPlaybackSources(
    videoUrls: <String>[
      'https://video-main.bilivideo.com/video.m4s',
      'https://video-backup.bilivideo.cn/video.m4s',
    ],
    audioUrls: <String>[
      'https://audio-main.bilivideo.com/audio.m4s',
      'https://audio-backup.bilivideo.cn/audio.m4s',
    ],
    audioCodecByUrl: <String, String>{
      'https://audio-main.bilivideo.com/audio.m4s': 'mp4a.40.2',
      'https://audio-backup.bilivideo.cn/audio.m4s': 'ec-3',
    },
    referer: 'https://www.bilibili.com/video/BV1GJ411x7h7',
    cookieHeader: 'SESSDATA=test-session',
    actualQuality: 64,
    qualities: <PlaybackQuality>[PlaybackQuality(id: 64, label: '高清 720P')],
    videoCodec: 'avc1.64001F',
    audioCodec: 'mp4a.40.2',
  );
}

/// 验证 Windows DASH 地址轮换顺序与外部音频请求头注册行为。
void main() {
  test('主备 CDN 组合有限去重并优先轮换单侧故障', () {
    final List<WindowsDashMediaAttempt> attempts = WindowsDashMediaPlan.build(
      _createSources(),
    );

    expect(attempts, hasLength(4));
    expect(attempts[0].videoUrl, contains('video-main'));
    expect(attempts[0].audioUrl, contains('audio-main'));
    expect(attempts[0].audioCodec, 'mp4a.40.2');
    expect(attempts[1].videoUrl, contains('video-main'));
    expect(attempts[1].audioUrl, contains('audio-backup'));
    expect(attempts[1].audioCodec, 'ec-3');
    expect(attempts[2].videoUrl, contains('video-backup'));
    expect(attempts[2].audioUrl, contains('audio-main'));
    expect(attempts[3].videoUrl, contains('video-backup'));
    expect(attempts[3].audioUrl, contains('audio-backup'));
  });

  test('视频与外部音轨都能从 Media 缓存取得同一组安全请求头', () {
    final DesktopPlaybackSources sources = _createSources();
    final WindowsDashMediaAttempt attempt = WindowsDashMediaPlan.build(
      sources,
    ).first;

    final Media videoMedia = attempt.createVideoMedia(sources.mediaHeaders);
    final Media audioMedia = attempt.createAudioMedia(sources.mediaHeaders);
    final AudioTrack audioTrack = attempt.createAudioTrack(
      audioMedia,
      title: 'FocuBili audio 1:0',
    );

    expect(videoMedia.httpHeaders, sources.mediaHeaders);
    expect(audioMedia.httpHeaders, sources.mediaHeaders);
    expect(audioTrack.id, attempt.audioUrl);
    expect(audioTrack.title, 'FocuBili audio 1:0');
    expect(Media(audioTrack.id).httpHeaders, sources.mediaHeaders);
    expect(
      Media(audioTrack.id).httpHeaders!['Cookie'],
      'SESSDATA=test-session',
    );
    expect(Media(audioTrack.id).httpHeaders!['Referer'], sources.referer);
  });

  test('缺少外部音频时不生成会静默播放的纯视频尝试', () {
    final DesktopPlaybackSources sources = _createSources();
    final DesktopPlaybackSources withoutAudio = DesktopPlaybackSources(
      videoUrls: sources.videoUrls,
      audioUrls: const <String>[],
      audioCodecByUrl: const <String, String>{},
      referer: sources.referer,
      cookieHeader: sources.cookieHeader,
      actualQuality: sources.actualQuality,
      qualities: sources.qualities,
      videoCodec: sources.videoCodec,
      audioCodec: '',
    );

    expect(WindowsDashMediaPlan.build(withoutAudio), isEmpty);
  });
}
