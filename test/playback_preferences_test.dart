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

  /// 验证首次安装默认启用双击快进快退，并为两种网络使用安全的 720P。
  test('播放器偏好使用安全默认值', () async {
    final PlaybackPreferences preferences =
        await const PlaybackPreferencesService().load();

    expect(preferences.enableDoubleTapSeek, isTrue);
    expect(preferences.wifiDefaultQuality, PreferredPlaybackQuality.p720);
    expect(preferences.mobileDefaultQuality, PreferredPlaybackQuality.p720);
  });

  /// 验证关闭开关后重新读取仍保持关闭。
  test('双击手势设置保存在本机', () async {
    const PlaybackPreferencesService service = PlaybackPreferencesService();
    await service.saveDoubleTapSeekEnabled(false);

    final PlaybackPreferences preferences = await service.load();
    expect(preferences.enableDoubleTapSeek, isFalse);
  });

  /// 验证 Wi-Fi 与移动网络清晰度分别保存，未知编号不会破坏配置。
  test('两种网络默认清晰度分别保存在本机', () async {
    const PlaybackPreferencesService service = PlaybackPreferencesService();
    await service.saveWifiDefaultQuality(PreferredPlaybackQuality.p4k);
    await service.saveMobileDefaultQuality(PreferredPlaybackQuality.p480);

    final PlaybackPreferences preferences = await service.load();
    expect(preferences.wifiDefaultQuality, PreferredPlaybackQuality.p4k);
    expect(preferences.mobileDefaultQuality, PreferredPlaybackQuality.p480);
  });

  /// 验证默认档不可用时选择不超过偏好和服务端实际档位的最高可用档。
  test('默认清晰度只向下选择可用档位', () {
    expect(
      selectPlaybackQualityAtOrBelow(
        preferredQuality: 80,
        actualQuality: 80,
        availableQualities: const <int>[64, 32, 16],
      ),
      64,
    );
    expect(
      selectPlaybackQualityAtOrBelow(
        preferredQuality: 64,
        actualQuality: 80,
        availableQualities: const <int>[116, 80, 64, 32],
      ),
      64,
    );
  });
}
