import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows 外部音轨的完播重载与播放源请求代次保护不会被后续重构移除。
void main() {
  /// media_kit 会在完播时卸载外部音轨，Windows 重播前必须重新调用 setAudioTrack。
  test('Windows 完播重播会重新挂载 DASH 外部音轨', () {
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();

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
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();

    expect(service, contains('final int generation = _beginSourceRequest();'));
    expect(service, contains('if (!_isCurrentSourceRequest(generation))'));
    expect(service, contains('generation == _sourceGeneration'));
  });

  /// media_kit 错误流来自宽泛日志，必须先核对当前音视频输出和线路身份，不能直接把正常播放切走。
  test('Windows 播放错误先核验健康状态和当前线路', () {
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();

    expect(service, contains('unawaited(\n            _verifyPlayerError('));
    expect(service, contains('_isCurrentMediaAttempt('));
    expect(service, contains('hasVideoOutput: _hasDecodedVideo()'));
    expect(service, contains('hasDecodedAudio: hasDecodedAudio'));
    expect(service, isNot(contains('_mediaErrorDuringOpen')));
  });

  /// 历史续播必须先暂停并跳转视频，再等待较慢的外部音轨挂载，避免从零播放数秒。
  test('Windows 历史位置在外部音轨挂载前恢复', () {
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();
    final int methodStart = service.indexOf('Future<void> _openMediaAttempt(');
    final int methodEnd = service.indexOf(
      'bool _needsResumePositionCorrection(',
      methodStart,
    );
    final String methodBody = service.substring(methodStart, methodEnd);
    final int pauseIndex = methodBody.indexOf('await _player.pause();');
    final int openIndex = methodBody.indexOf('await _player.open(');
    final int seekIndex = methodBody.indexOf(
      'await _player.seek(resumePosition);',
    );
    final int audioIndex = methodBody.indexOf(
      'await _player.setAudioTrack(audioTrack);',
    );

    expect(pauseIndex, greaterThanOrEqualTo(0));
    expect(openIndex, greaterThan(pauseIndex));
    expect(seekIndex, greaterThan(openIndex));
    expect(audioIndex, greaterThan(seekIndex));
    expect(
      methodBody,
      contains('_needsResumePositionCorrection(resumePosition)'),
    );
  });
}
