import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'listening_playback_test.dart' show ListeningPlayer;

/// Presents deterministic native open failures before allowing successful decode.
class _RecoveryPlayer extends ListeningPlayer {
  final seen = <Media>[];
  final Map<String, String> failures = {};

  /// Records the real Media.start value even when this attempt cannot open.
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    seen.add(media);
    final failure = failures[Uri.parse(media.uri).path];
    if (failure != null) throw StateError(failure);
    await super.open(playable, play: play);
  }
}

/// 验证 Windows 外部音轨的完播重载与播放源请求代次保护不会被后续重构移除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('播放入口复用清晰度和听视频的 DASH 会话并保留暂停位置', () async {
    var requests = 0;
    final player = _RecoveryPlayer();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: BilibiliDesktopPlaybackSourceService(
        requestJson: (_, _) async {
          requests++;
          return _dashPayload();
        },
      ),
    );
    addTearDown(service.dispose);
    const position = Duration(seconds: 42);
    await service.openVideo(
      VideoPreview.placeholder(),
      initialPosition: position,
    );
    expect(player.seen.single.start, position);
    await service.pause();
    await service.selectQuality(64);
    expect(player.seen, hasLength(1));
    await service.setAudioOnly(true);
    await service.setAudioOnly(false);
    await service.selectQuality(32);
    expect(requests, 1);
    expect(player.seen.map((media) => Uri.parse(media.uri).path), [
      '/64-avc',
      '/audio',
      '/64-avc',
      '/32-avc',
    ]);
    expect(player.seen.every((media) => media.start == position), isTrue);
    expect(player.state.playing, isFalse);
  });

  test('首次打开合并过期刷新，明确解码失败后换同档 AVC', () async {
    var requests = 0;
    final player = _RecoveryPlayer()
      ..failures.addAll({
        '/expired': 'HTTP error 403 Forbidden',
        '/64-hevc': 'Failed to initialize a video decoder',
      });
    final service = WindowsPlaybackService(
      player: player,
      sourceService: BilibiliDesktopPlaybackSourceService(
        requestJson: (_, _) async => _dashPayload(expired: ++requests == 1),
      ),
    );
    addTearDown(service.dispose);
    const position = Duration(seconds: 42);
    await service.openVideo(
      VideoPreview.placeholder(),
      initialPosition: position,
      codecPreference: PlaybackCodecPreference.dataSaver,
    );
    expect(player.seen.map((media) => Uri.parse(media.uri).path), [
      '/expired',
      '/64-hevc',
      '/64-avc',
    ]);
    expect(player.seen.every((media) => media.start == position), isTrue);
    await service.setAudioOnly(true);
    await service.setAudioOnly(false);
    expect(Uri.parse(player.seen.last.uri).path, '/64-avc');
    expect(requests, 2);
  });

  /// media_kit 会在完播时卸载外部音轨，Windows 重播前必须重新调用 setAudioTrack。
  test('Windows 完播重播会重新挂载 DASH 外部音轨', () {
    final String service = _readWindowsPlaybackService();

    expect(
      service,
      contains('_externalAudioNeedsReload = _activeAudioMedia != null'),
    );
    expect(
      service,
      contains('await _reloadExternalAudioAfterCompletion(generation);'),
    );
    expect(service, contains('await _player.setAudioTrack(audioTrack);'));
    expect(service, contains('await _waitForDecodedAudio(generation)'));
    expect(service, contains('_player.state.audioParams'));
    expect(service, contains('params.channelCount'));
    expect(service, contains("'current-tracks/audio/title'"));
    expect(service, contains("'current-tracks/audio/external'"));
    expect(service, contains("'current-tracks/audio/selected'"));
    expect(service, contains('activeTitle == _activeAudioTrackToken'));
    expect(service, contains('_hasAudioOutput(params)'));
    expect(service, isNot(contains('activeFilename == expectedFilename')));
    expect(service, isNot(contains("'current-tracks/audio/decoder'")));
  });

  /// 新分P或清晰度请求必须先使旧请求失效，并在网络返回后再次核对代次。
  test('Windows 播放源使用请求代次阻止旧分P覆盖新分P', () {
    final String service = _readWindowsPlaybackService();

    expect(service, contains('final int generation = _beginSourceRequest();'));
    expect(service, contains('if (!_isCurrentSourceRequest(generation))'));
    expect(service, contains('generation == _sourceGeneration'));
  });

  /// media_kit 错误流来自宽泛日志，必须先核对当前音视频输出和线路身份，不能直接把正常播放切走。
  test('Windows 播放错误先核验健康状态和当前线路', () {
    final String service = _readWindowsPlaybackService();

    expect(service, contains('_verifyPlayerError('));
    expect(service, contains('_isCurrentMediaAttempt('));
    expect(service, contains('hasVideoOutput: _hasDecodedVideo()'));
    expect(service, contains('hasDecodedAudio: hasDecodedAudio'));
    expect(service, isNot(contains('_mediaErrorDuringOpen')));
  });

  /// 视频画面已经解码但音频仍缺失时应缩短等待，尽快进入下一条媒体组合。
  test('Windows 首次有画面无声音时两秒内开始切换备用线路', () {
    final String service = _readWindowsPlaybackService();

    expect(
      service,
      contains('_audioAfterVideoReadyTimeout = Duration(seconds: 2)'),
    );
    expect(service, contains('DateTime? videoReadyAt;'));
    expect(service, contains('videoReadyAt ??= DateTime.now();'));
    expect(service, contains('videoReadyAt.add(_audioAfterVideoReadyTimeout)'));
  });

  /// 视频必须携带起播位置，再挂载音轨并保留解码后的定位纠偏。
  test('Windows 历史位置在外部音轨挂载前恢复', () {
    final String service = _readWindowsPlaybackService();
    final int methodStart = service.indexOf('Future<void> _openMediaAttempt(');
    final int methodEnd = service.indexOf(
      'bool _needsResumePositionCorrection(',
      methodStart,
    );
    // 听视频新增了独立纯音频分支；这项契约只检查后续视频与外部音轨分支。
    final int videoBranchStart = service.indexOf(
      'final AudioTrack audioTrack =',
      methodStart,
    );
    expect(videoBranchStart, greaterThan(methodStart));
    final String methodBody = service.substring(videoBranchStart, methodEnd);
    final int pauseIndex = methodBody.indexOf('await _player.pause();');
    final int openIndex = methodBody.indexOf('await _openPlayerMedia(');
    final int startIndex = methodBody.indexOf(
      'attempt.createVideoMedia(_activeMediaHeaders, start: start)',
    );
    final int audioIndex = methodBody.indexOf(
      'await _player.setAudioTrack(audioTrack);',
    );
    final int decoderReadyIndex = methodBody.indexOf(
      'await _waitForDecodedAudio(generation)',
    );
    final int finalCorrectionIndex = methodBody.indexOf(
      'await _restoreResumePositionAfterDecode(generation, resumePosition);',
    );

    expect(pauseIndex, greaterThanOrEqualTo(0));
    expect(openIndex, greaterThan(pauseIndex));
    expect(startIndex, greaterThan(openIndex));
    expect(audioIndex, greaterThan(startIndex));
    expect(decoderReadyIndex, greaterThan(audioIndex));
    expect(finalCorrectionIndex, greaterThan(decoderReadyIndex));
    expect(
      methodBody,
      contains('_needsResumePositionCorrection(resumePosition)'),
    );
    expect(service, contains('_pendingResumePositionAfterDecode'));
    expect(service, contains('_shouldPlayAfterFallback'));
    expect(
      service,
      contains(
        'await _player.pause();\n'
        '    if (!_isCurrentSourceRequest(generation))',
      ),
    );
  });

  /// Flutter 观看记录提供的位置必须优先于 Windows 后端旧位置，确保搜索入口恢复同一份进度。
  test('Windows 打开视频优先使用调用方初始位置', () {
    final String service = _readWindowsPlaybackService();

    expect(
      service,
      contains(
        'final SavedPlaybackState? savedState = initialPosition == null',
      ),
    );
    expect(
      service,
      contains('_restoredPosition =\n        initialPosition ??'),
    );
    expect(service, contains('initialPosition?.isNegative ?? false'));
  });

  /// Windows 每次异步写入必须先固定视频身份与位置，再按调用顺序进入保存队列。
  test('Windows 播放进度使用固定快照串行保存', () {
    final String service = _readWindowsPlaybackService();

    expect(service, contains('WindowsPlaybackProgressSnapshot('));
    expect(service, contains('_progressSaveQueue = _progressSaveQueue.then'));
    expect(service, contains('await _progressStore.save(progress);'));
    expect(
      service,
      contains(
        '_opening ||\n'
        '        _restoringPosition ||\n'
        '        _currentVideo == null',
      ),
    );
    expect(
      service,
      contains('if (!force && pendingResumePosition > Duration.zero)'),
    );
    expect(
      service,
      contains('position: pendingResumePosition > Duration.zero'),
    );
    expect(service, contains('if (duration <= Duration.zero)'));
  });
}

/// Provides two qualities and separate video encodings without real requests.
String _dashPayload({bool expired = false}) {
  /// Creates a trusted fixture URL and the representation metadata.
  Map<String, Object> track(int id, String path, String codec, int bandwidth) =>
      {
        'id': id,
        'base_url': 'https://test.bilivideo.com/$path',
        'codecs': codec,
        'bandwidth': bandwidth,
      };
  return jsonEncode({
    'code': 0,
    'data': {
      'quality': 64,
      'dash': {
        'video': [
          track(64, '64-avc', 'avc1', 300000),
          track(64, expired ? 'expired' : '64-hevc', 'hev1', 150000),
          track(32, '32-avc', 'avc1', 120000),
        ],
        'audio': [track(30280, 'audio', 'mp4a.40.2', 120000)],
      },
    },
  });
}

/// 读取 Windows 播放服务并统一换行，避免 CRLF 与 LF 差异制造源码契约测试假失败。
String _readWindowsPlaybackService() {
  return File(
    'lib/services/windows_playback_service.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
}
