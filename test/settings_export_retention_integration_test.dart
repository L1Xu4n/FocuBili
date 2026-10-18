import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/native_playback_progress_export.dart';
import 'package:focubili/services/native_subscription_scheduler.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/subscription_snapshot_store.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'subscription_performance_probe_test.dart' show feedFixture;

class _NoNetwork extends Fake implements BilibiliPublicContentService {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Export must not request content');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  databaseFactory = databaseFactorySqflitePlugin;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const sqlChannel = MethodChannel('com.tekartik.sqflite');
  final now = DateTime.utc(2026, 10, 18, 12);
  var serial = 0;
  for (final platform in [
    AppPlatform.windows,
    AppPlatform.ios,
    AppPlatform.android,
  ]) {
    for (final mode in ['settings', 'unified-settings', 'unified-full']) {
      test(
        '${platform.name} $mode cold export preserves expired rows and never schedules or migrates',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'focubili-cold-settings-',
          );
          final data = Map<String, dynamic>.from(
            jsonDecode(feedFixture(count: 2, sourceCount: 1)) as Map,
          );
          data['version'] =
              1; // Normal initialize would write the pre-beta4 backup.
          data['enabled'] = true;
          data['notificationsEnabled'] = true;
          data['backgroundRefreshEnabled'] = true;
          data['feed'][0]['readAt'] = now
              .subtract(const Duration(days: 8))
              .toIso8601String();
          data['feed'][0]['title'] = 'EXPIRED_READ_ROW_MUST_SURVIVE_EXPORT';
          final raw = jsonEncode(data);
          final calls = <MethodCall>[];
          final handles = <int>{};
          var nextId = 300;
          messenger.setMockMethodCallHandler(sqlChannel, (call) async {
            calls.add(call);
            final args = call.arguments as Map? ?? const {};
            switch (call.method) {
              case 'getDatabasesPath':
                return root.path;
              case 'databaseExists':
                return true;
              case 'openDatabase':
                expect(args['readOnly'], isTrue);
                expect(args['singleInstance'], isFalse);
                final id = nextId++;
                handles.add(id);
                return id;
              case 'query':
                expect(args['sql'], 'SELECT value FROM snapshot WHERE id = 1');
                return [
                  {'value': raw},
                ];
              case 'closeDatabase':
                handles.remove(args['id']);
                return null;
              default:
                throw StateError(
                  'Cold export attempted native SQL mutation: ${call.method}',
                );
            }
          });
          final schedulerChannel = MethodChannel(
            'test/cold-export-native-${serial++}',
          );
          final scheduling = <MethodCall>[];
          messenger.setMockMethodCallHandler(schedulerChannel, (call) async {
            scheduling.add(call);
            return {
              'available': true,
              'accepted': true,
              'status': 'ready',
              'mode': 'process',
            };
          });
          final native = NativeSubscriptionScheduler(
            platform: platform,
            channel: schedulerChannel,
          );
          SharedPreferences.setMockInitialValues({
            'appearance.theme_mode': 'dark',
            'content.blocklist_v1': '{"version":1,"videos":{}}',
            SubscriptionService.storageKey: raw,
          });
          final prefs = await SharedPreferences.getInstance();
          final before = {
            for (final key in prefs.getKeys()) key: prefs.get(key),
          };
          final store = SqliteSubscriptionSnapshotStore(
            databaseName: 'synthetic-cold-${serial++}.db',
          );
          final network = _NoNetwork();
          final service = SubscriptionService(
            contentService: network,
            preferencesLoader: () async => prefs,
            snapshotStore: store,
            clock: () => now,
            platform: platform,
            nativeScheduler: native,
          );
          final imageDirectory = await Directory(
            '${root.path}/focubili_images_v1',
          ).create();
          final index = File('${imageDirectory.path}/index.json');
          const imageRaw =
              '{"capacity":42,"entries":"unrelated malformed index"}';
          await index.writeAsString(imageRaw);
          final orphan = File('${imageDirectory.path}/orphan.part');
          await orphan.writeAsString('keep');
          final images = ImageResourceCache(
            directory: () async => imageDirectory,
          );
          final adapter = DeviceSettingsRuntimeAdapter(
            subscriptions: service,
            imageCache: images,
          );
          var notifications = 0;
          service.addListener(() => notifications++);
          images.addListener(() => notifications++);
          addTearDown(() async {
            // Any desktop cancellation here is disposal, after export assertions.
            await native.dispose();
            service.dispose();
            images.dispose();
            await store.close();
            messenger.setMockMethodCallHandler(schedulerChannel, null);
            messenger.setMockMethodCallHandler(sqlChannel, null);
            await root.delete(recursive: true);
          });
          if (mode == 'settings') {
            final transfer = SettingsTransferService(
              preferencesLoader: () async => prefs,
              runtimeAdapter: adapter,
            );
            final values = transfer.parseSettings(
              await transfer.exportSettings(),
            );
            expect(values[DeviceSettingsRuntimeAdapter.enabledKey], isTrue);
            expect(values[DeviceSettingsRuntimeAdapter.imageCapacityKey], 42);
            expect(values, isNot(contains('content.blocklist_v1')));
          } else {
            final package =
                await UnifiedExportService(
                  preferencesLoader: () async => prefs,
                  settingsRuntimeAdapter: adapter,
                  subscriptionLoader: service.exportLocalData,
                  subtitleLoader: () => [],
                  diagnosticsLoader: () async => 'Synthetic diagnostics',
                  platform: platform,
                  nativePlaybackProgressLoader: () async => {
                    'format': NativePlaybackProgressExport.format,
                    'version': 1,
                    'lastParts': <Object?>[],
                    'parts': <Object?>[],
                  },
                ).buildPackage(
                  sections: mode == 'unified-settings'
                      ? {UnifiedExportSection.settings}
                      : {...UnifiedExportSection.values},
                );
            final archive = ZipDecoder().decodeBytes(package.bytes);
            final settings =
                jsonDecode(utf8.decode(archive.find('settings.json')!.content))
                    as Map;
            expect(
              (settings['values']
                  as Map)[DeviceSettingsRuntimeAdapter.enabledKey],
              isTrue,
            );
            if (mode == 'unified-full') {
              final subscriptions =
                  jsonDecode(
                        utf8.decode(
                          archive.find('subscriptions.json')!.content,
                        ),
                      )
                      as Map;
              expect(
                (subscriptions['feed'] as List).any(
                  (row) =>
                      row['title'] == 'EXPIRED_READ_ROW_MUST_SURVIVE_EXPORT',
                ),
                isTrue,
              );
            }
          }
          expect(handles, isEmpty);
          expect(
            calls.where((call) => call.method == 'openDatabase'),
            hasLength(mode == 'unified-full' ? 2 : 1),
          );
          expect(scheduling, isEmpty);
          expect(network.calls, 0);
          expect(
            native.available,
            isFalse,
          ); // No native status/init was requested.
          expect(notifications, 0);
          expect(
            service.feed,
            isEmpty,
          ); // No initialize/retention cleanup in memory.
          expect(service.sources, isEmpty);
          await prefs.reload();
          expect({
            for (final key in prefs.getKeys()) key: prefs.get(key),
          }, before);
          expect(await index.readAsString(), imageRaw);
          expect(await orphan.readAsString(), 'keep');
          expect(
            await File('${imageDirectory.path}/cache.lock').exists(),
            isFalse,
          );
        },
      );
    }
  }
}
