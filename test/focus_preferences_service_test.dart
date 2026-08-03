import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/focus_preferences_service.dart';

/// 注册专注设置默认值和本机持久化测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 验证勿扰开关默认关闭，用户开启后能从同一设备恢复。
  test('专注勿扰开关默认关闭并可持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService service = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );

    expect((await service.load()).enableDoNotDisturb, isFalse);
    expect((await service.load()).hasSeenPlayerDoNotDisturbGuide, isFalse);
    expect((await service.load()).hasSeenBackgroundReminderGuide, isFalse);
    expect(await service.saveDoNotDisturbEnabled(true), isTrue);
    expect(await service.markPlayerDoNotDisturbGuideSeen(), isTrue);
    expect(await service.markBackgroundReminderGuideSeen(), isTrue);
    expect((await service.load()).enableDoNotDisturb, isTrue);
    expect((await service.load()).hasSeenPlayerDoNotDisturbGuide, isTrue);
    expect((await service.load()).hasSeenBackgroundReminderGuide, isTrue);
  });
}
