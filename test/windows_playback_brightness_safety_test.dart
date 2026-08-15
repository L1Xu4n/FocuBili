import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 Windows 播放服务不会再次接入会修改物理显示器的亮度插件。
void main() {
  /// Windows 亮度只由 Flutter 画面覆盖层处理，服务不能读取、设置或重置显示器硬件。
  test('Windows 播放服务不调用物理显示器亮度 API', () {
    final String service = File(
      'lib/services/windows_playback_service.dart',
    ).readAsStringSync();

    expect(service, isNot(contains("package:screen_brightness")));
    expect(service, isNot(contains('ScreenBrightness.instance')));
    expect(service, isNot(contains('resetApplicationScreenBrightness')));
    expect(service, contains('brightness: 1'));
  });

  /// 亮度手势必须落在画面层的覆盖色上，而不是写入窗口所在的物理显示器。
  test('播放器页面提供软件亮度覆盖层', () {
    final String page = File(
      'lib/features/player/player_page_view.dart',
    ).readAsStringSync();

    expect(page, contains("Key('software-brightness-overlay')"));
    expect(page, contains('_appPlatform == AppPlatform.windows'));
    expect(page, contains('Colors.black.withValues(alpha: 1 - _brightness)'));
  });
}
