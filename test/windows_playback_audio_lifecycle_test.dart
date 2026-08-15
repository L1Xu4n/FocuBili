import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows 外部音轨的完播重载与播放源请求代次保护不会被后续重构移除。
void main() {
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

    expect(service, contains('unawaited(\n            _verifyPlayerError('));
    expect(service, contains('_isCurrentMediaAttempt('));
    expect(service, contains('hasVideoOutput: _hasDecodedVideo()'));
    expect(service, contains('hasDecodedAudio: hasDecodedAudio'));
    expect(service, isNot(contains('_mediaErrorDuringOpen')));
  });

  /// 历史续播必须先暂停并跳转视频，再等待较慢的外部音轨挂载，避免从零播放数秒。
  test('Windows 历史位置在外部音轨挂载前恢复', () {
    final String service = _readWindowsPlaybackService();
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
    final int decoderReadyIndex = methodBody.indexOf(
      'await _waitForDecodedAudio(generation)',
    );
    final int finalCorrectionIndex = methodBody.indexOf(
      'await _restoreResumePositionAfterDecode(generation, resumePosition);',
    );

    expect(pauseIndex, greaterThanOrEqualTo(0));
    expect(openIndex, greaterThan(pauseIndex));
    expect(seekIndex, greaterThan(openIndex));
    expect(audioIndex, greaterThan(seekIndex));
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

/// 读取 Windows 播放服务并统一换行，避免 CRLF 与 LF 差异制造源码契约测试假失败。
String _readWindowsPlaybackService() {
  return File(
    'lib/services/windows_playback_service.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
}
