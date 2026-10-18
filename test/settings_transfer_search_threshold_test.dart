import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/search_content_filter.dart';
import 'package:focubili/services/search_content_filter_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';

class _SyntheticRuntime implements SettingsRuntimeAdapter {
  final values = <String, Object>{
    DeviceSettingsRuntimeAdapter.enabledKey: true,
    DeviceSettingsRuntimeAdapter.notificationsKey: true,
    DeviceSettingsRuntimeAdapter.backgroundKey: false,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 128,
  };
  int reads = 0;
  int writes = 0;

  @override
  Future<Map<String, Object>> readSettings() async {
    reads++;
    return Map.of(values);
  }

  @override
  Future<void> writeSettings(Map<String, Object?> updates) async {
    writes++;
    for (final entry in updates.entries) {
      values[entry.key] = entry.value!;
    }
  }
}

String _filter(Object? minimum) =>
    jsonEncode({'learningOnly': false, 'minimumPlayCount': minimum});

String _settings(Map<String, Object> values) => jsonEncode({
  'format': 'focubili-settings',
  'schemaVersion': 1,
  'settings': values,
});

Map<String, Object?> _snapshot(SharedPreferences preferences) => {
  for (final key in preferences.getKeys()) key: preferences.get(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _SyntheticRuntime runtime;
  late SettingsTransferService transfer;
  late int preferenceLoads;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'appearance.theme_mode': 'dark',
      'playback_preferences.long_press_speed': 2.5,
      'playback_preferences.speeds': <String>['1.0', '2.0'],
      SearchContentFilterService.storageKey: _filter(321),
      'focubili_notes_v1': 'synthetic-note',
    });
    preferences = await SharedPreferences.getInstance();
    runtime = _SyntheticRuntime();
    preferenceLoads = 0;
    transfer = SettingsTransferService(
      preferencesLoader: () async {
        preferenceLoads++;
        return preferences;
      },
      runtimeAdapter: runtime,
    );
  });

  for (final minimum in [0, SearchContentFilter.maximumPlayCount]) {
    test(
      'imported threshold $minimum survives filter loading exactly',
      () async {
        final values = transfer.parseSettings(
          _settings({SearchContentFilterService.storageKey: _filter(minimum)}),
        );
        await transfer.importSettings(values);

        final loaded = await SearchContentFilterService(
          preferencesLoader: () async => preferences,
        ).load();
        expect(loaded.minimumPlayCount, minimum);
        expect(loaded.learningOnly, isFalse);
        expect(
          jsonDecode(
            preferences.getString(SearchContentFilterService.storageKey)!,
          ),
          {'learningOnly': false, 'minimumPlayCount': minimum},
        );
        expect(runtime.reads, 0);
        expect(runtime.writes, 0);
      },
    );
  }

  final invalid = <String, Object?>{
    'maximum plus one': SearchContentFilter.maximumPlayCount + 1,
    'negative': -1,
    'double': 1.0,
    'string': '123',
    'boolean': true,
    'null': null,
  };
  for (final entry in invalid.entries) {
    Map<String, Object> updates() => {
      // Valid updates precede the bad filter to exercise whole-file validation.
      'appearance.theme_mode': 'light',
      DeviceSettingsRuntimeAdapter.enabledKey: false,
      SearchContentFilterService.storageKey: _filter(entry.value),
    };

    test('parse rejects ${entry.key} without changing any setting', () {
      final oldPreferences = _snapshot(preferences);
      final oldRuntime = Map.of(runtime.values);
      expect(
        () => transfer.parseSettings(_settings(updates())),
        throwsFormatException,
      );
      expect(_snapshot(preferences), oldPreferences);
      expect(runtime.values, oldRuntime);
      expect(preferenceLoads, 0);
      expect(runtime.reads, 0);
      expect(runtime.writes, 0);
    });

    test(
      'direct import rejects ${entry.key} before any partial write',
      () async {
        final oldPreferences = _snapshot(preferences);
        final oldRuntime = Map.of(runtime.values);
        await expectLater(
          transfer.importSettings(updates()),
          throwsFormatException,
        );
        expect(_snapshot(preferences), oldPreferences);
        expect(runtime.values, oldRuntime);
        expect(preferenceLoads, 0);
        expect(runtime.reads, 0);
        expect(runtime.writes, 0);
      },
    );
  }
}
