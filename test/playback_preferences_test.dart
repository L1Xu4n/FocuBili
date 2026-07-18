import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/playback_preferences_service.dart';

/// 验证播放器个性化开关的默认值和本机持久化。
void main() {
  /// 每个测试从空白本地偏好开始，避免用例相互影响。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证首次安装默认启用双击快进快退。
  test('双击快进快退默认启用', () async {
    final PlaybackPreferences preferences =
        await const PlaybackPreferencesService().load();

    expect(preferences.enableDoubleTapSeek, isTrue);
  });

  /// 验证关闭开关后重新读取仍保持关闭。
  test('双击手势设置保存在本机', () async {
    const PlaybackPreferencesService service = PlaybackPreferencesService();
    await service.saveDoubleTapSeekEnabled(false);

    final PlaybackPreferences preferences = await service.load();
    expect(preferences.enableDoubleTapSeek, isFalse);
  });
}
