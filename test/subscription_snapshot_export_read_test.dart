import 'dart:async';
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

const _channel = MethodChannel('com.tekartik.sqflite');

String _snapshot({bool enabled = false, bool notifications = false}) =>
    jsonEncode({
      'version': 2,
      'enabled': enabled,
      'notificationsEnabled': notifications,
      'backgroundRefreshEnabled': false,
      'sources': [],
      'feed': [],
      'checkpoints': {},
      'historyJobs': {},
      'announced': [],
      'notificationClaims': [],
    });

/// This is the entire native backend. Production Sqlite...Store and sqflite
/// method-channel code run, but no native database or real user data is opened.
class _NativeBackend {
  _NativeBackend(this.root);
  final Directory root;
  final calls = <MethodCall>[];
  final handles = <int, bool>{};
  bool exists = true;
  String? raw = _snapshot(notifications: true);
  String? failMethod;
  int nextHandle = 600;
  Completer<void>? updateEntered, updateRelease;
  bool rejectUpdate = false;

  Future<Object?> call(MethodCall call) async {
    calls.add(call);
    if (call.method == failMethod) {
      throw PlatformException(code: 'synthetic_storage_failure');
    }
    final args = call.arguments as Map? ?? const {};
    switch (call.method) {
      case 'getDatabasesPath':
        return root.path;
      case 'databaseExists':
        return exists;
      case 'openDatabase':
        final id = nextHandle++;
        handles[id] = args['readOnly'] == true;
        return id;
      case 'query':
        return [
          if (raw != null) {'value': raw},
        ];
      case 'execute':
        return null;
      case 'update':
        if (updateEntered != null) {
          updateEntered!.complete();
          await updateRelease!.future;
        }
        if (rejectUpdate) {
          throw PlatformException(code: 'synthetic_write_failure');
        }
        raw = (args['arguments'] as List).first as String;
        return 1;
      case 'closeDatabase':
        handles.remove(args['id']);
        return null;
      default:
        throw StateError(
          'Unexpected synthetic SQLite operation ${call.method}',
        );
    }
  }

  void expectPureReads({required int opens}) {
    final openCalls = calls
        .where((call) => call.method == 'openDatabase')
        .toList();
    expect(openCalls, hasLength(opens));
    for (final call in openCalls) {
      final args = call.arguments as Map;
      expect(args['readOnly'], isTrue);
      expect(args['singleInstance'], isFalse);
    }
    expect(calls.where((call) => call.method == 'execute'), isEmpty);
    expect(calls.where((call) => call.method == 'insert'), isEmpty);
    expect(calls.where((call) => call.method == 'update'), isEmpty);
    expect(calls.where((call) => call.method == 'delete'), isEmpty);
    expect(
      calls.where((call) => call.method == 'closeDatabase'),
      hasLength(opens),
    );
    expect(handles.values.where((readOnly) => readOnly), isEmpty);
    for (final call in calls.where((call) => call.method == 'query')) {
      expect(
        (call.arguments as Map)['sql'],
        'SELECT value FROM snapshot WHERE id = 1',
      );
    }
  }
}

Map _settings(UnifiedExportPackage package) {
  final archive = ZipDecoder().decodeBytes(package.bytes);
  return (jsonDecode(utf8.decode(archive.find('settings.json')!.content))
          as Map)['values']
      as Map;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  databaseFactory = databaseFactorySqflitePlugin;
  late Directory root;
  late _NativeBackend native;
  late SqliteSubscriptionSnapshotStore store;
  late SubscriptionService service;
  late ImageResourceCache images;
  var serial = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili-native-export-');
    native = _NativeBackend(root);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.call);
    store = SqliteSubscriptionSnapshotStore(
      databaseName: 'synthetic-${serial++}.db',
    );
    service = SubscriptionService(
      preferencesLoader: SharedPreferences.getInstance,
      snapshotStore: store,
      backgroundScheduler: (_, _) async {},
    );
    images = ImageResourceCache(
      directory: () async => Directory('${root.path}/focubili_images_v1'),
    );
    SharedPreferences.setMockInitialValues({
      SubscriptionService.storageKey: _snapshot(enabled: true),
    });
  });
  tearDown(() async {
    if (native.updateRelease != null && !native.updateRelease!.isCompleted) {
      native.updateRelease!.complete();
    }
    service.dispose();
    images.dispose();
    await store.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await root.delete(recursive: true);
  });
  UnifiedExportService exporter() => UnifiedExportService(
    settingsRuntimeAdapter: DeviceSettingsRuntimeAdapter(
      subscriptions: service,
      imageCache: images,
    ),
    subscriptionLoader: service.exportLocalData,
    subtitleLoader: () => [],
    diagnosticsLoader: () async => 'Synthetic diagnostics',
  );
  Set<UnifiedExportSection> sections(bool settingsOnly) => settingsOnly
      ? {UnifiedExportSection.settings}
      : {...UnifiedExportSection.values};

  for (final settingsOnly in [true, false]) {
    final label = settingsOnly ? 'settings-only' : 'all sections';
    test(
      '$label reads an existing native snapshot read-only and closes each handle',
      () async {
        // The DB flags contradict legacy, proving the production store is authoritative.
        final prefs = await SharedPreferences.getInstance();
        final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
        final package = await exporter().buildPackage(
          sections: sections(settingsOnly),
        );
        expect(
          _settings(package)[DeviceSettingsRuntimeAdapter.enabledKey],
          isFalse,
        );
        expect(
          _settings(package)[DeviceSettingsRuntimeAdapter.notificationsKey],
          isTrue,
        );
        native.expectPureReads(opens: settingsOnly ? 1 : 2);
        expect(
          service.notificationsEnabled,
          isFalse,
        ); // Cold state remains untouched.
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, before);
        expect(await root.list().toList(), isEmpty);
      },
    );

    for (final failure in ['databaseExists', 'openDatabase', 'query']) {
      test(
        '$label $failure failure blocks a package and never falls back to legacy',
        () async {
          native.failMethod = failure;
          var produced = false;
          await expectLater(
            exporter()
                .buildPackage(sections: sections(settingsOnly))
                .then((_) => produced = true),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                'synthetic_storage_failure',
              ),
            ),
          );
          expect(produced, isFalse);
          expect(
            native.calls.where((call) => call.method == 'execute'),
            isEmpty,
          );
          if (failure == 'query') {
            native.expectPureReads(opens: 1);
          } else {
            expect(native.handles, isEmpty);
          }
          expect(await root.list().toList(), isEmpty);
        },
      );
    }
  }

  test(
    'existing empty table closes its handle before legacy fallback',
    () async {
      native.raw = null;
      expect((await service.exportPreferenceFlags())['enabled'], isTrue);
      native.expectPureReads(opens: 1);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('bad raw snapshot rejects after closing the read-only handle', () async {
    for (final raw in [
      '{broken',
      '{"version":99}',
      '{"version":2,"enabled":null}',
    ]) {
      native.raw = raw;
      native.calls.clear();
      await expectLater(
        service.exportPreferenceFlags(),
        throwsA(
          anyOf(isA<FormatException>(), isA<SubscriptionStorageException>()),
        ),
      );
      native.expectPureReads(opens: 1);
    }
  });

  test('business read still initializes the writable schema', () async {
    expect(await store.read(), native.raw);
    final open = native.calls.singleWhere(
      (call) => call.method == 'openDatabase',
    );
    expect((open.arguments as Map)['readOnly'], isNot(true));
    expect(
      native.calls.where((call) => call.method == 'execute'),
      hasLength(1),
    );
    native.calls.clear();
    expect(await store.readForExport(), native.raw);
    native.expectPureReads(opens: 1);
    expect(native.handles.values, [
      false,
    ]); // Existing business handle stays open.
  });

  for (final fullContent in [false, true]) {
    for (final rejectWrite in [false, true]) {
      test(
        '${fullContent ? 'content' : 'flags'} export waits for a native ${rejectWrite ? 'failed' : 'successful'} in-flight write',
        () async {
          native.raw = _snapshot();
          await service.initialize(); // Explicit business fixture setup only.
          expect(service.storageError, isNull);
          native.updateEntered = Completer<void>();
          native.updateRelease = Completer<void>();
          native.rejectUpdate = rejectWrite;
          final write = service.setNotificationsEnabled(true);
          final failedWrite = rejectWrite
              ? expectLater(write, throwsA(isA<SubscriptionStorageException>()))
              : null;
          await native.updateEntered!.future;
          native.calls.clear();
          var finished = false;
          final export =
              (fullContent
                      ? service.exportLocalData()
                      : service.exportPreferenceFlags())
                  .whenComplete(() => finished = true);
          final failedRead = rejectWrite
              ? expectLater(
                  export,
                  throwsA(isA<SubscriptionStorageException>()),
                )
              : null;
          await Future<void>.delayed(Duration.zero);
          expect(finished, isFalse);
          expect(native.calls, isEmpty);
          native.updateRelease!.complete();
          if (rejectWrite) {
            await failedWrite;
            await failedRead;
            expect(native.calls, isEmpty);
          } else {
            await write;
            expect((await export)['notificationsEnabled'], isTrue);
            native.expectPureReads(opens: 1);
          }
        },
      );
    }
  }
}
