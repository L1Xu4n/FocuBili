import 'package:focubili/services/settings_runtime_adapter.dart';

/// Explicit synthetic values keep export tests away from device storage.
class FixtureSettingsRuntimeAdapter implements SettingsRuntimeAdapter {
  const FixtureSettingsRuntimeAdapter();

  @override
  Future<Map<String, Object>> readSettings() async => {
    DeviceSettingsRuntimeAdapter.enabledKey: false,
    DeviceSettingsRuntimeAdapter.notificationsKey: false,
    DeviceSettingsRuntimeAdapter.backgroundKey: false,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 256 * 1024 * 1024,
  };

  @override
  Future<void> writeSettings(Map<String, Object?> values) async =>
      throw StateError('Export must not write runtime settings');
}
