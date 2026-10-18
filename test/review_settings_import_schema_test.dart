import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/danmaku_preferences.dart';
import 'package:focubili/services/danmaku_preferences_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';

const _danmakuKey = DanmakuPreferencesService.storageKey;

String _envelope(Map<String, Object> values) => jsonEncode({
  'format': 'focubili-settings',
  'schemaVersion': 1,
  'settings': values,
});

class _MemoryRuntime implements SettingsRuntimeAdapter {
  int reads = 0;
  int writes = 0;
  final values = <String, Object>{
    DeviceSettingsRuntimeAdapter.enabledKey: false,
    DeviceSettingsRuntimeAdapter.notificationsKey: false,
    DeviceSettingsRuntimeAdapter.backgroundKey: false,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 256 * 1024 * 1024,
  };
  @override
  Future<Map<String, Object>> readSettings() async {
    reads++;
    return Map.of(values);
  }

  @override
  Future<void> writeSettings(Map<String, Object?> updates) async {
    writes++;
    for (final entry in updates.entries) {
      values[entry.key] = entry.value ?? false;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String previous;
  setUp(() {
    previous = jsonEncode(
      DanmakuPreferences(
        enabled: true,
        fontSize: 24,
        opacity: 0.4,
        blockedKeywords: ['synthetic-blocked'],
      ).toJson(),
    );
    SharedPreferences.setMockInitialValues({_danmakuKey: previous});
  });

  for (final direct in [false, true]) {
    test(
      'non-finite danmaku laneCount must not reset all preferences; direct=$direct',
      () async {
        const service = SettingsTransferService();
        const bad =
            '{"enabled":true,"fontSize":24,"opacity":0.4,'
            '"laneCount":1e309,"blockedKeywords":["synthetic-blocked"]}';
        expect((jsonDecode(bad) as Map)['laneCount'], double.infinity);
        Object? rejected;
        try {
          final values = direct
              ? <String, Object>{_danmakuKey: bad}
              : service.parseSettings(_envelope({_danmakuKey: bad}));
          await service.importSettings(values);
        } catch (error) {
          rejected = error;
        }
        final loaded = await DanmakuPreferencesService().load();
        expect(
          rejected,
          isA<FormatException>(),
          reason:
              'Invalid import was accepted; real load returns ${loaded.toJson()}',
        );
        expect(
          (await SharedPreferences.getInstance()).getString(_danmakuKey),
          previous,
        );
        expect(loaded.enabled, isTrue);
        expect(loaded.blockedKeywords, ['synthetic-blocked']);
      },
    );
  }

  test(
    'wrong-type danmaku keywords must not silently remove blocking',
    () async {
      const service = SettingsTransferService();
      const bad = '{"enabled":true,"blockedKeywords":false}';
      Object? rejected;
      try {
        await service.importSettings(
          service.parseSettings(_envelope({_danmakuKey: bad})),
        );
      } catch (error) {
        rejected = error;
      }
      final loaded = await DanmakuPreferencesService().load();
      expect(
        rejected,
        isA<FormatException>(),
        reason:
            'blocks(synthetic-blocked)=${loaded.blocks('synthetic-blocked')}',
      );
      expect(
        (await SharedPreferences.getInstance()).getString(_danmakuKey),
        previous,
      );
    },
  );

  test(
    'direct import must freeze validated scalar values before storage await',
    () async {
      const key = 'playback_preferences.enable_double_tap_seek';
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(key, false);
      final entered = Completer<void>();
      final release = Completer<void>();
      final service = SettingsTransferService(
        preferencesLoader: () async {
          entered.complete();
          await release.future;
          return preferences;
        },
      );
      final values = <String, Object>{key: true};
      final pending = service.importSettings(values);
      await entered.future;
      values[key] = 'synthetic-wrong-type';
      release.complete();
      await pending;
      Object? loadError;
      try {
        await const PlaybackPreferencesService().load();
      } catch (error) {
        loadError = error;
      }
      expect(
        loadError,
        isNull,
        reason:
            'validated bool was persisted as ${preferences.get(key).runtimeType}',
      );
      expect(preferences.get(key), isTrue);
    },
  );

  test('parsed speed list must be frozen before storage await', () async {
    const key = 'playback_preferences.speeds';
    final preferences = await SharedPreferences.getInstance();
    final entered = Completer<void>();
    final release = Completer<void>();
    final service = SettingsTransferService(
      preferencesLoader: () async {
        entered.complete();
        await release.future;
        return preferences;
      },
    );
    final values = service.parseSettings(
      _envelope({
        key: ['1.5', '2.5'],
      }),
    );
    final pending = service.importSettings(values);
    await entered.future;
    (values[key] as List)[0] = 'synthetic-invalid-rate';
    release.complete();
    await pending;
    final loaded = await const PlaybackPreferencesService().load();
    expect(loaded.playbackSpeeds, [1, 1.5, 2.5]);
  });

  test(
    'every known danmaku field rejects wrong types before any storage access',
    () async {
      final invalidFields = <String, Object>{
        'enabled': 1,
        'opacity': false,
        'fontSize': <Object>[],
        'laneCount': false,
        'scrollDurationSeconds': <Object>[],
        'displayArea': true,
        'strokeWidth': <Object>[],
        'showScrolling': 1,
        'showTop': <Object>[],
        'showBottom': 0,
        'mergeRepeated': <Object>[],
        'blockedKeywords': [0],
      };
      var preferenceReads = 0;
      final runtime = _MemoryRuntime();
      final service = SettingsTransferService(
        runtimeAdapter: runtime,
        preferencesLoader: () async {
          preferenceReads++;
          return SharedPreferences.getInstance();
        },
      );
      for (final entry in invalidFields.entries) {
        final values = <String, Object>{
          'appearance.theme_mode': 'light',
          DeviceSettingsRuntimeAdapter.enabledKey: true,
          _danmakuKey: jsonEncode({entry.key: entry.value}),
        };
        expect(
          () => service.parseSettings(_envelope(values)),
          throwsFormatException,
          reason: entry.key,
        );
        final future = service.importSettings(values);
        await expectLater(future, throwsFormatException, reason: entry.key);
      }
      expect(preferenceReads, 0);
      expect(runtime.reads, 0);
      expect(runtime.writes, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(_danmakuKey),
        previous,
      );
    },
  );

  test(
    'numeric danmaku fields reject overflow and retain finite integer conversion',
    () async {
      const service = SettingsTransferService();
      for (final field in [
        'opacity',
        'fontSize',
        'laneCount',
        'scrollDurationSeconds',
        'displayArea',
        'strokeWidth',
      ]) {
        final raw = '{"$field":1e309}';
        expect(
          () => service.parseSettings(_envelope({_danmakuKey: raw})),
          throwsFormatException,
          reason: field,
        );
        await expectLater(
          service.importSettings({_danmakuKey: raw}),
          throwsFormatException,
          reason: field,
        );
      }
      await service.importSettings({_danmakuKey: '{"laneCount":12.5}'});
      expect((await DanmakuPreferencesService().load()).laneCount, 12);
      await service.importSettings({_danmakuKey: '{"laneCount":12.0}'});
      expect((await DanmakuPreferencesService().load()).laneCount, 12);
    },
  );

  test(
    'legal complete and old partial danmaku exports retain roundtrip behavior',
    () async {
      final runtime = _MemoryRuntime();
      final service = SettingsTransferService(runtimeAdapter: runtime);
      final complete = DanmakuPreferences(
        enabled: true,
        opacity: 0.4,
        fontSize: 24,
        laneCount: 7,
        scrollDurationSeconds: 12,
        displayArea: 0.5,
        strokeWidth: 2,
        showScrolling: false,
        showTop: false,
        showBottom: false,
        mergeRepeated: false,
        blockedKeywords: ['synthetic-blocked'],
      ).toJson();
      await service.importSettings({_danmakuKey: jsonEncode(complete)});
      final exported = await service.exportSettings();
      await (await SharedPreferences.getInstance()).remove(_danmakuKey);
      await service.importSettings(service.parseSettings(exported));
      expect((await DanmakuPreferencesService().load()).toJson(), complete);

      await service.importSettings({_danmakuKey: '{"enabled":true}'});
      expect((await DanmakuPreferencesService().load()).enabled, isTrue);
      // Absent old fields still receive defaults; known invalid ranges fail.
      const old =
          '{"enabled":true,"opacity":-5,"fontSize":100,"laneCount":0,'
          '"scrollDurationSeconds":999,"displayArea":0,"strokeWidth":99}';
      expect(
        () => service.parseSettings(_envelope({_danmakuKey: old})),
        throwsFormatException,
      );
      expect((await DanmakuPreferencesService().load()).enabled, isTrue);
    },
  );
}
