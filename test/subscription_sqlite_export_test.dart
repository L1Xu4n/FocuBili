import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/subscription_snapshot_store.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  databaseFactory = databaseFactorySqflitePlugin;
  const channel = MethodChannel('com.tekartik.sqflite');

  for (final settingsOnly in [true, false]) {
    test(
      'review: ${settingsOnly ? 'settings-only' : 'full'} export never creates a cold SQLite database',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'focubili-review-sqlite-',
        );
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return switch (call.method) {
                'getDatabasesPath' => root.path,
                'databaseExists' => false,
                'openDatabase' => 917,
                'execute' || 'closeDatabase' => null,
                'query' => <Map<String, Object?>>[],
                _ => throw StateError(
                  'Unexpected synthetic SQLite call: ${call.method}',
                ),
              };
            });
        final store = SqliteSubscriptionSnapshotStore(
          databaseName: 'review-only.db',
        );
        final service = SubscriptionService(
          preferencesLoader: SharedPreferences.getInstance,
          snapshotStore: store,
        );
        final images = ImageResourceCache(
          directory: () async => Directory('${root.path}/focubili_images_v1'),
        );
        addTearDown(() async {
          service.dispose();
          images.dispose();
          await store.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await root.delete(recursive: true);
        });
        SharedPreferences.setMockInitialValues({
          SubscriptionService.storageKey: jsonEncode({
            'version': 2,
            'enabled': true,
            'sources': [],
            'feed': [],
            'checkpoints': {},
            'historyJobs': {},
          }),
        });
        final package =
            await UnifiedExportService(
              settingsRuntimeAdapter: DeviceSettingsRuntimeAdapter(
                subscriptions: service,
                imageCache: images,
              ),
              subscriptionLoader: service.exportLocalData,
              subtitleLoader: () => [],
              diagnosticsLoader: () async => 'Synthetic diagnostics only',
            ).buildPackage(
              sections: settingsOnly
                  ? {UnifiedExportSection.settings}
                  : {...UnifiedExportSection.values},
            );
        final archive = ZipDecoder().decodeBytes(package.bytes);
        final settings =
            jsonDecode(utf8.decode(archive.find('settings.json')!.content))
                as Map;
        expect(
          (settings['values'] as Map)[DeviceSettingsRuntimeAdapter.enabledKey],
          isTrue,
        );
        if (!settingsOnly) {
          final subscriptions =
              jsonDecode(
                    utf8.decode(archive.find('subscriptions.json')!.content),
                  )
                  as Map;
          expect(subscriptions['enabled'], isTrue);
        }
        // This handler is the entire SQLite backend: no real database is opened.
        // Capturing native calls verifies the production Sqlite...Store path.
        expect(
          calls.where((call) => call.method == 'execute'),
          isEmpty,
          reason: 'A read-only export must not execute schema creation',
        );
        expect(
          calls.where((call) => call.method == 'openDatabase'),
          isEmpty,
          reason: 'A missing database should not be created for export',
        );
        expect(await root.list().toList(), isEmpty);
      },
    );
  }
}
