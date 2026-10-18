import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;

const _enabled = DeviceSettingsRuntimeAdapter.enabledKey;
const _notifications = DeviceSettingsRuntimeAdapter.notificationsKey;
const _background = DeviceSettingsRuntimeAdapter.backgroundKey;
const _capacity = DeviceSettingsRuntimeAdapter.imageCapacityKey;
const _runtimeValues = <String, Object>{
  _enabled: false,
  _notifications: true,
  _background: false,
  _capacity: 8192,
};

class _Preferences extends Fake implements SharedPreferences {
  _Preferences(this.values);
  final Map<String, Object> values;
  int writes = 0;
  @override
  Future<void> reload() async {}
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Object? get(String key) => values[key];
  @override
  String? getString(String key) => values[key] as String?;
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    throw StateError('Export must not write preferences');
  }

  @override
  Future<bool> remove(String key) async {
    writes++;
    throw StateError('Export must not remove preferences');
  }
}

class _Snapshots extends CountingSnapshots {
  int recoveries = 0;
  bool failRead = false;
  @override
  Future<String?> read() {
    if (failRead) {
      reads++;
      throw StateError('Synthetic database read failure');
    }
    return super.read();
  }

  @override
  Future<String?> recover(bool Function(String) validate) async {
    recoveries++;
    throw StateError('Export must not recover snapshots');
  }
}

class _NoHistory implements SubscriptionHistoryStore {
  int calls = 0;
  @override
  Future<SubscriptionHistoryBatch?> read(String job, int batch) async {
    calls++;
    throw StateError('Fixture must not access history pages');
  }

  @override
  Future<void> write(
    String job,
    int batch,
    SubscriptionHistoryBatch value,
  ) async {
    calls++;
    throw StateError('Fixture must not write history');
  }
}

class _NoNetwork extends Fake implements BilibiliPublicContentService {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Export must not access network');
  }
}

class _ColdSubscriptions extends SubscriptionService {
  _ColdSubscriptions({
    required super.preferencesLoader,
    required super.snapshotStore,
    required super.historyStore,
    required super.contentService,
    required super.backgroundScheduler,
  });
  int initializations = 0;
  @override
  Future<void> initialize() async {
    initializations++;
    throw StateError('Export must not initialize subscriptions');
  }
}

class _Adapter implements SettingsRuntimeAdapter {
  _Adapter(this.values);
  final Map<String, Object> values;
  int reads = 0;
  Object? error;
  @override
  Future<Map<String, Object>> readSettings() async {
    reads++;
    if (error != null) throw error!;
    return values;
  }

  @override
  Future<void> writeSettings(Map<String, Object?> values) async =>
      throw StateError('Export must not write runtime settings');
}

Map<String, dynamic> _values(UnifiedExportPackage package) {
  final archive = ZipDecoder().decodeBytes(package.bytes);
  return (jsonDecode(utf8.decode(archive.find('settings.json')!.content))
          as Map)['values']
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, cacheDirectory;
  late _Preferences prefs;
  late _Snapshots snapshots;
  late _ColdSubscriptions subscriptions;
  late ImageResourceCache images;
  late _NoHistory history;
  late _NoNetwork network;
  var schedules = 0, notifications = 0, downloads = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili-runtime-export-');
    cacheDirectory = Directory('${root.path}/focubili_images_v1');
    prefs = _Preferences({
      'appearance.theme_mode': 'dark',
      'content.blocklist_v1': '{"version":1,"videos":{}}',
      // Stale copies, including bad types, must never be read as runtime settings.
      for (final key in DeviceSettingsRuntimeAdapter.keys) key: 'STALE_VALUE',
      SubscriptionService.storageKey: '{broken legacy snapshot',
    });
    final document = Map<String, dynamic>.from(
      jsonDecode(feedFixture(count: 0, sourceCount: 0)) as Map,
    );
    document.addAll({
      'version': 2,
      'enabled': false,
      'notificationsEnabled': true,
      'backgroundRefreshEnabled': false,
    });
    snapshots = _Snapshots()..value = jsonEncode(document);
    history = _NoHistory();
    network = _NoNetwork();
    schedules = notifications = downloads = 0;
    subscriptions = _ColdSubscriptions(
      preferencesLoader: () async => prefs,
      snapshotStore: snapshots,
      historyStore: history,
      contentService: network,
      backgroundScheduler: (_, _) async => schedules++,
    )..addListener(() => notifications++);
    images = ImageResourceCache(
      directory: () async => cacheDirectory,
      defaultCapacity: 8192,
      request: (_, _) async {
        downloads++;
        throw StateError('Export must not download images');
      },
    )..addListener(() => notifications++);
  });
  tearDown(() async {
    expect(subscriptions.initializations, 0);
    expect(prefs.writes, 0);
    expect(snapshots.transactions, 0);
    expect(snapshots.saves, 0);
    expect(snapshots.recoveries, 0);
    expect(history.calls, 0);
    expect(network.calls, 0);
    expect(schedules, 0);
    expect(notifications, 0);
    expect(downloads, 0);
    images.dispose();
    subscriptions.dispose();
    await root.delete(recursive: true);
  });

  UnifiedExportService exporter({SettingsRuntimeAdapter? adapter}) =>
      UnifiedExportService(
        preferencesLoader: () async => prefs,
        settingsRuntimeAdapter:
            adapter ??
            DeviceSettingsRuntimeAdapter(
              subscriptions: subscriptions,
              imageCache: images,
            ),
        subscriptionLoader: subscriptions.exportLocalData,
        subtitleLoader: () => [],
        diagnosticsLoader: () async => 'Synthetic diagnostics',
      );

  test(
    'settings-only wires real cold services, ignores stale prefs and writes nothing',
    () async {
      final snapshot = snapshots.value;
      final before = Map.of(prefs.values);
      final package = await exporter().buildPackage(
        sections: {UnifiedExportSection.settings},
      );
      expect(_values(package), {
        ..._runtimeValues,
        'appearance.theme_mode': 'dark',
        'content.blocklist_v1': '{"version":1,"videos":{}}',
      });
      expect(snapshots.reads, 1);
      expect(snapshots.value, snapshot);
      expect(prefs.values, before);
      expect(subscriptions.notificationsEnabled, isFalse); // Remains cold.
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'all sections preserve runtime flags and existing cache bytes without repair',
    () async {
      await cacheDirectory.create();
      final index = File('${cacheDirectory.path}/index.json');
      const raw = '{"capacity":77,"entries":"unrelated bad content"}';
      await index.writeAsString(raw);
      final package = await exporter().buildPackage();
      expect(_values(package)[_capacity], 77);
      expect(_values(package)[_notifications], true);
      expect(
        snapshots.reads,
        2,
      ); // One flags read and one selected content export.
      expect(await index.readAsString(), raw);
      expect(await File('${cacheDirectory.path}/cache.lock').exists(), isFalse);
      expect(
        ZipDecoder().decodeBytes(package.bytes).find('subscriptions.json'),
        isNotNull,
      );
    },
  );

  test(
    'unselected settings never reads adapter or cold backing stores',
    () async {
      final adapter = _Adapter({})..error = StateError('unselected');
      final package = await exporter(
        adapter: adapter,
      ).buildPackage(sections: {UnifiedExportSection.learning});
      expect(adapter.reads, 0);
      expect(snapshots.reads, 0);
      expect(
        ZipDecoder().decodeBytes(package.bytes).find('settings.json'),
        isNull,
      );
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'only four runtime keys are accepted and unknown adapter keys never leak',
    () async {
      final adapter = _Adapter({
        ..._runtimeValues,
        'private.future_key': 'SYNTHETIC_DO_NOT_EXPORT',
        'appearance.theme_mode': 'STALE_ADAPTER_VALUE',
        'bilibili_cookie': 'SYNTHETIC_DO_NOT_EXPORT',
      });
      final package = await exporter(
        adapter: adapter,
      ).buildPackage(sections: {UnifiedExportSection.settings});
      expect(adapter.reads, 1);
      expect(_values(package)['appearance.theme_mode'], 'dark');
      expect(
        _values(
          package,
        ).keys.where(DeviceSettingsRuntimeAdapter.keys.contains).toSet(),
        DeviceSettingsRuntimeAdapter.keys,
      );
      for (final entry in ZipDecoder().decodeBytes(package.bytes).files) {
        expect(
          utf8.decode(entry.content),
          isNot(contains('SYNTHETIC_DO_NOT_EXPORT')),
        );
        expect(utf8.decode(entry.content), isNot(contains('STALE_')));
      }
    },
  );

  for (final key in DeviceSettingsRuntimeAdapter.keys) {
    test('missing or wrongly typed $key blocks a successful package', () async {
      for (final value in <Object?>[
        null,
        'true',
        [],
        {},
        if (key == _capacity) ...[false, -1, 2.0, 1.5] else ...[0, 1],
      ]) {
        final values = Map.of(_runtimeValues)..remove(key);
        if (value != null) values[key] = value;
        final adapter = _Adapter(values);
        var produced = false;
        await expectLater(
          exporter(adapter: adapter)
              .buildPackage(sections: {UnifiedExportSection.settings})
              .then((_) => produced = true),
          throwsFormatException,
        );
        expect(produced, isFalse);
      }
    });
  }

  test(
    'adapter storage errors block the package without successful fallback',
    () async {
      final adapter = _Adapter(_runtimeValues)
        ..error = StateError('synthetic storage failure');
      await expectLater(
        exporter(
          adapter: adapter,
        ).buildPackage(sections: {UnifiedExportSection.settings}),
        throwsStateError,
      );
      subscriptions.storageError = 'synthetic unavailable snapshot';
      await expectLater(
        exporter().buildPackage(sections: {UnifiedExportSection.settings}),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(snapshots.reads, 0);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'authoritative database failure does not fall back to legacy or emit a package',
    () async {
      snapshots.failRead = true;
      prefs.values[SubscriptionService.storageKey] = '{"version":2}';
      await expectLater(
        exporter().buildPackage(sections: {UnifiedExportSection.settings}),
        throwsStateError,
      );
      expect(snapshots.reads, 1);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('bad persisted capacity blocks export and remains unchanged', () async {
    await cacheDirectory.create();
    final index = File('${cacheDirectory.path}/index.json');
    const raw = '{"capacity":"broken"}';
    await index.writeAsString(raw);
    await expectLater(
      exporter().buildPackage(sections: {UnifiedExportSection.settings}),
      throwsFormatException,
    );
    expect(await index.readAsString(), raw);
    expect(await File('${cacheDirectory.path}/cache.lock').exists(), isFalse);
  });

  test(
    'bad unselected feed permits settings but selected content stays strict',
    () async {
      snapshots.value = jsonEncode({
        'version': 2,
        'notificationsEnabled': true,
        'feed': 'UNSELECTED_MALFORMED_CONTENT',
      });
      final package = await exporter().buildPackage(
        sections: {UnifiedExportSection.settings},
      );
      expect(_values(package)[_notifications], true);
      await expectLater(
        exporter().buildPackage(),
        throwsA(isA<SubscriptionStorageException>()),
      );
    },
  );

  test(
    'legacy snapshot maps flags without migrating and absent storage defaults',
    () async {
      snapshots.value = null;
      prefs.values[SubscriptionService.storageKey] = jsonEncode({
        'version': 1,
        'enabled': true,
        'backgroundRefreshEnabled': true,
        'feed': 'unselected',
      });
      final adapter = DeviceSettingsRuntimeAdapter(
        subscriptions: subscriptions,
        imageCache: images,
      );
      expect(await adapter.readSettings(), {
        _enabled: true,
        _notifications: false,
        _background: true,
        _capacity: 8192,
      });
      prefs.values.remove(SubscriptionService.storageKey);
      expect(await adapter.readSettings(), {
        _enabled: false,
        _notifications: false,
        _background: false,
        _capacity: 8192,
      });
      expect(snapshots.value, isNull);
      expect(await root.list().toList(), isEmpty);
    },
  );
}
