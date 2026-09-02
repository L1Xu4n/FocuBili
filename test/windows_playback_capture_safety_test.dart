import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows 专注和笔记取帧不会重新接回 libmpv 的进程级截图入口。
void main() {
  /// Windows 服务只能读取 Flutter 画面或公开视频雪碧图，禁止调用 Player.screenshot。
  test('Windows 播放服务不调用 media_kit 原生截图', () {
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();

    expect(service, contains('_frameCapture.capturePngBytes(pixelRatio: 1.5)'));
    expect(service, contains('_videoShotService.captureFramePngBytes('));
    expect(service, isNot(contains('_player.screenshot(')));
  });
}
