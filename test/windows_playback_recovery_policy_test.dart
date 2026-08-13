import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/windows_playback_recovery_policy.dart';

/// 验证 Windows 底层错误不会覆盖已经正常输出的音视频线路。
void main() {
  /// 音视频都已解码且播放器未缓冲时，宽泛错误事件应被视为可忽略的旧事件或非致命日志。
  test('正常播放时底层错误不会触发备用线路', () {
    final bool shouldSwitch =
        WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
          isOpening: false,
          isBuffering: false,
          hasVideoOutput: true,
          hasDecodedAudio: true,
        );

    expect(shouldSwitch, isFalse);
  });

  /// 当前仍在同步打开时由打开流程自行判断成功或超时，错误监听不能并发启动第二套换线流程。
  test('线路打开期间错误监听不会并发触发备用线路', () {
    final bool shouldSwitch =
        WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
          isOpening: true,
          isBuffering: true,
          hasVideoOutput: false,
          hasDecodedAudio: false,
        );

    expect(shouldSwitch, isFalse);
  });

  /// 打开结束后只要缓冲持续或任一音视频输出缺失，就允许既有恢复流程切换到下一组合。
  test('音频视频或缓冲异常仍会触发备用线路', () {
    expect(
      WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
        isOpening: false,
        isBuffering: true,
        hasVideoOutput: true,
        hasDecodedAudio: true,
      ),
      isTrue,
    );
    expect(
      WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
        isOpening: false,
        isBuffering: false,
        hasVideoOutput: false,
        hasDecodedAudio: true,
      ),
      isTrue,
    );
    expect(
      WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
        isOpening: false,
        isBuffering: false,
        hasVideoOutput: true,
        hasDecodedAudio: false,
      ),
      isTrue,
    );
  });
}
