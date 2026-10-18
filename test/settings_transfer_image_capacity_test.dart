import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/subscription_service.dart';

const _imageKey = DeviceSettingsRuntimeAdapter.imageCapacityKey;
const _mib = 1024 * 1024;

class _CountingRuntime implements SettingsRuntimeAdapter {
  final values = <String, Object>{
    DeviceSettingsRuntimeAdapter.enabledKey: true,
    DeviceSettingsRuntimeAdapter.notificationsKey: true,
    DeviceSettingsRuntimeAdapter.backgroundKey: false,
    _imageKey: 128,
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

String _document(Map<String, Object?> values) => jsonEncode({
  'format': 'focubili-settings',
  'schemaVersion': 1,
  'settings': values,
});

Map<String, Object?> _snapshot(SharedPreferences preferences) => {
  for (final key in preferences.getKeys()) key: preferences.get(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final maximum =
      ImageResourceCache.capacities.reduce((a, b) => a > b ? a : b) * _mib;
  late SharedPreferences preferences;
  late _CountingRuntime runtime;
  late SettingsTransferService transfer;
  late int preferenceLoads;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'appearance.theme_mode': 'dark',
      'playback_preferences.long_press_speed': 2.5,
      'playback_preferences.speeds': <String>['1.0', '2.0'],
      'search.content_filter_v2':
          '{"learningOnly":false,"minimumPlayCount":321}',
      'first_launch_user_agreement_2026_07_18_accepted': true,
      'focubili_notes_v1': 'synthetic-note',
      'synthetic.unrelated': <String>['keep'],
    });
    preferences = await SharedPreferences.getInstance();
    runtime = _CountingRuntime();
    preferenceLoads = 0;
    transfer = SettingsTransferService(
      preferencesLoader: () async {
        preferenceLoads++;
        return preferences;
      },
      runtimeAdapter: runtime,
    );
  });

  for (final capacity in <int>{
    0,
    1,
    128,
    for (final mib in ImageResourceCache.capacities) mib * _mib,
  }) {
    test(
      'schema 1 roundtrip retains capacity $capacity in real runtime',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'focubili-image-setting-',
        );
        final directory = Directory('${root.path}/focubili_images_v1');
        var requests = 0;
        final images = ImageResourceCache(
          directory: () async => directory,
          request: (_, _) async {
            requests++;
            return ImageCacheResponse(
              200,
              Uint8List.fromList([1, 2, 3]),
              const {'cache-control': 'max-age=60'},
            );
          },
        );
        final subscriptions = SubscriptionService(
          preferencesLoader: () async => preferences,
          backgroundScheduler: (_, _) async {},
        );
        addTearDown(() async {
          subscriptions.dispose();
          images.dispose();
          await root.delete(recursive: true);
        });
        final actual = SettingsTransferService(
          preferencesLoader: () async => preferences,
          runtimeAdapter: DeviceSettingsRuntimeAdapter(
            subscriptions: subscriptions,
            imageCache: images,
          ),
        );
        expect(images.defaultCapacity, 256 * _mib);
        expect((await images.status()).capacityBytes, images.defaultCapacity);
        const url = 'https://i0.hdslb.com/synthetic-capacity-test.png';
        if (capacity == 0) {
          await images.load(url);
          expect((await images.status()).objects, 1);
        }

        await actual.importSettings({_imageKey: capacity});
        final exported = await actual.exportSettings();
        final decoded = jsonDecode(exported) as Map<String, dynamic>;
        expect(decoded['schemaVersion'], 1);
        expect((decoded['settings'] as Map)[_imageKey], capacity);
        final parsed = actual.parseSettings(exported);
        expect(parsed[_imageKey], capacity);
        await images.setCapacity(capacity == 0 ? images.defaultCapacity : 0);
        await actual.importSettings(parsed);

        final reopened = ImageResourceCache(directory: () async => directory);
        addTearDown(reopened.dispose);
        expect((await reopened.status()).capacityBytes, capacity);
        expect(preferences.getString('appearance.theme_mode'), 'dark');
        expect(preferences.getString('focubili_notes_v1'), 'synthetic-note');
        if (capacity == 0) {
          expect((await images.status()).objects, 0);
          await images.load(url);
          await images.load(url);
          expect(requests, 3);
          expect((await images.status()).objects, 0);
          expect((await images.status()).usedBytes, 0);
          expect(
            await directory
                .list()
                .where((entry) => entry.path.endsWith('.bin'))
                .length,
            0,
          );
        }
      },
    );
  }

  final invalid = <String, Object>{
    'negative': -1,
    'maximum plus one': maximum + 1,
    'one GiB': 1024 * _mib,
    '64 bit maximum': 0x7fffffffffffffff,
    'double': maximum.toDouble(),
    'string': '$maximum',
    'boolean': true,
    'list': <int>[maximum],
    'map': <String, int>{'bytes': maximum},
  };
  for (final entry in invalid.entries) {
    Map<String, Object> updates() => {
      // Valid ordinary and runtime updates precede the invalid last item.
      'appearance.theme_mode': 'light',
      'playback_preferences.long_press_speed': 4.0,
      DeviceSettingsRuntimeAdapter.enabledKey: false,
      _imageKey: entry.value,
    };

    void expectUnchanged(
      Map<String, Object?> before,
      Map<String, Object> oldRuntime,
    ) {
      expect(_snapshot(preferences), before);
      expect(runtime.values, oldRuntime);
      expect(preferenceLoads, 0);
      expect(runtime.reads, 0);
      expect(runtime.writes, 0);
    }

    test('parse rejects ${entry.key} before any preference/runtime access', () {
      final before = _snapshot(preferences);
      final oldRuntime = Map.of(runtime.values);
      expect(
        () => transfer.parseSettings(_document(updates())),
        throwsFormatException,
      );
      expectUnchanged(before, oldRuntime);
    });
    test('direct import rejects ${entry.key} before partial writes', () async {
      final before = _snapshot(preferences);
      final oldRuntime = Map.of(runtime.values);
      await expectLater(
        transfer.importSettings(updates()),
        throwsFormatException,
      );
      expectUnchanged(before, oldRuntime);
    });
  }

  test('parse rejects a null image capacity before accessing storage', () {
    final before = _snapshot(preferences);
    expect(
      () => transfer.parseSettings(_document({_imageKey: null})),
      throwsFormatException,
    );
    expect(_snapshot(preferences), before);
    expect(preferenceLoads, 0);
    expect(runtime.reads, 0);
    expect(runtime.writes, 0);
  });
}
