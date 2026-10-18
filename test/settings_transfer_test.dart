import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';

/// 以独立合成容器模拟事务库和图片索引，不接触机器上的实际用户目录。
class _SyntheticRuntimeSettings implements SettingsRuntimeAdapter {
  final values = <String, Object>{
    DeviceSettingsRuntimeAdapter.enabledKey: true,
    DeviceSettingsRuntimeAdapter.notificationsKey: true,
    DeviceSettingsRuntimeAdapter.backgroundKey: true,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 128 * 1024 * 1024,
  };
  bool failOnce = false;

  /// 返回可回滚的设置快照，不附加订阅源和用户内容。
  @override
  Future<Map<String, Object>> readSettings() async => Map.of(values);

  /// 恢复默认或写入指定项，可模拟一次写入过程中断。
  @override
  Future<void> writeSettings(Map<String, Object?> updates) async {
    for (final entry in updates.entries) {
      values[entry.key] =
          entry.value ??
          (entry.key == DeviceSettingsRuntimeAdapter.imageCapacityKey
              ? 256 * 1024 * 1024
              : false);
      if (failOnce) {
        failOnce = false;
        throw StateError('合成存储拒绝写入');
      }
    }
  }
}

/// 一次拒绝第二项设置写入，验证迁移服务能够恢复已经写入的第一项。
class _RejectOneSettingStore extends InMemorySharedPreferencesStore {
  /// 创建只含合成偏好的存储替身。
  _RejectOneSettingStore()
    : super.withData({
        'flutter.appearance.theme_mode': 'dark',
        'flutter.playback_preferences.long_press_speed': 2.5,
      });
  bool rejected = false;

  /// 只拒绝一次目标写入，恢复原值时正常写入。
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!rejected && key == 'flutter.playback_preferences.long_press_speed') {
      rejected = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// 验证设置白名单迁移不会携带账号或误清用户内容。
void main() {
  late SettingsTransferService service;
  late _SyntheticRuntimeSettings runtime;
  setUp(() {
    runtime = _SyntheticRuntimeSettings();
    service = SettingsTransferService(runtimeAdapter: runtime);
    SharedPreferences.setMockInitialValues({
      'appearance.theme_mode': 'dark',
      'playback_preferences.long_press_speed': 2.5,
      'app_update.ignored_release':
          '["L1Xu4n/FocuBili","windows","stable","1.7.1"]',
      'focubili_bilibili_cookie': 'synthetic-not-a-session',
      'first_launch_user_agreement_2026_07_18_accepted': true,
      'focubili_subscriptions_v1': '{"synthetic":"subscription"}',
      'focubili_notes_v1': 'synthetic-note',
    });
  });

  // 导出只包含偏好，重新导入可恢复数值与类型。
  test('设置往返保留偏好并排除用户内容', () async {
    final source = await service.exportSettings();
    expect(source, isNot(contains('synthetic')));
    final values = service.parseSettings(source);
    await service.resetSettings();
    await service.importSettings(values);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appearance.theme_mode'), 'dark');
    expect(preferences.getDouble('playback_preferences.long_press_speed'), 2.5);
    expect(
      preferences.getString('app_update.ignored_release'),
      contains('1.7.1'),
    );
    expect(preferences.getString('focubili_notes_v1'), 'synthetic-note');
    expect(runtime.values[DeviceSettingsRuntimeAdapter.enabledKey], isTrue);
    expect(
      runtime.values[DeviceSettingsRuntimeAdapter.imageCapacityKey],
      128 * 1024 * 1024,
    );
  });

  // 重置不得清空整个容器，协议和学习数据需要长期保留。
  test('重置仅移除设置白名单', () async {
    await service.resetSettings();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.get('appearance.theme_mode'), isNull);
    expect(preferences.get('playback_preferences.long_press_speed'), isNull);
    expect(preferences.get('app_update.ignored_release'), isNull);
    expect(
      preferences.getString('focubili_bilibili_cookie'),
      'synthetic-not-a-session',
    );
    expect(
      preferences.getBool('first_launch_user_agreement_2026_07_18_accepted'),
      isTrue,
    );
    expect(
      preferences.getString('focubili_subscriptions_v1'),
      contains('subscription'),
    );
    expect(preferences.getString('focubili_notes_v1'), 'synthetic-note');
    expect(runtime.values[DeviceSettingsRuntimeAdapter.enabledKey], isFalse);
    expect(
      runtime.values[DeviceSettingsRuntimeAdapter.notificationsKey],
      isFalse,
    );
    expect(runtime.values[DeviceSettingsRuntimeAdapter.backgroundKey], isFalse);
    expect(
      runtime.values[DeviceSettingsRuntimeAdapter.imageCapacityKey],
      256 * 1024 * 1024,
    );
  });

  // 事务库设置失败时，同时恢复已经改变的普通偏好和运行期设置。
  test('运行期设置部分失败恢复两个存储中的旧值', () async {
    runtime.failOnce = true;
    await expectLater(
      service.importSettings({
        'appearance.theme_mode': 'light',
        DeviceSettingsRuntimeAdapter.enabledKey: false,
      }),
      throwsStateError,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appearance.theme_mode'), 'dark');
    expect(runtime.values[DeviceSettingsRuntimeAdapter.enabledKey], isTrue);
    expect(preferences.get(DeviceSettingsRuntimeAdapter.enabledKey), isNull);
  });

  // 部分写入失败必须恢复已经改变的设置，避免用户获得混合配置。
  test('中途写入失败恢复之前配置', () async {
    SharedPreferencesStorePlatform.instance = _RejectOneSettingStore();
    SharedPreferences.resetStatic();
    await expectLater(
      service.importSettings({
        'appearance.theme_mode': 'light',
        'playback_preferences.long_press_speed': 4.0,
      }),
      throwsStateError,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appearance.theme_mode'), 'dark');
    expect(preferences.getDouble('playback_preferences.long_press_speed'), 2.5);
  });

  // 未知键、错误类型、结构损坏和版本不兼容必须在写入前拒绝。
  test('导入验证拒绝账号键和损坏类型', () async {
    for (final settings in [
      {'focubili_bilibili_cookie': 'synthetic'},
      {'appearance.theme_mode': false},
      {'appearance.layout_orientation': 'invalid'},
      {'app_update.ignored_release': '{"invalid":true}'},
      {'playback_preferences.double_tap_regions': '{"leftWidth":"bad"}'},
      {'dashboard.layout.home': '{"order":[1],"hidden":[]}'},
    ]) {
      expect(
        () => service.parseSettings(
          jsonEncode({
            'format': 'focubili-settings',
            'schemaVersion': 1,
            'settings': settings,
          }),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => service.parseSettings(
        '{"format":"focubili-settings","schemaVersion":2,"settings":{}}',
      ),
      throwsFormatException,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appearance.theme_mode'), 'dark');
  });
}
