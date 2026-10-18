import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/search_content_filter.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _search = 'search.content_filter_v2';
const _blocklist = 'content.blocklist_v1';
const _rules =
    '{"version":1,"videos":{"BV1GJ411x7h7":"Synthetic blocked video"}}';

class _Preferences extends Fake implements SharedPreferences {
  final values = <String, Object>{
    'appearance.theme_mode': 'dark',
    _blocklist: _rules,
  };
  int writes = 0;
  @override
  Object? get(String key) => values[key];
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Future<void> reload() async {}
  Future<bool> _save(String key, Object value) async {
    writes++;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) => _save(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _save(key, List.of(value));
  @override
  Future<bool> remove(String key) async {
    writes++;
    values.remove(key);
    return true;
  }
}

class _Runtime implements SettingsRuntimeAdapter {
  int reads = 0, writes = 0;
  final values = <String, Object>{
    for (final key in DeviceSettingsRuntimeAdapter.subscriptionKeys) key: false,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 123,
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
      values[entry.key] =
          entry.value ??
          (entry.key == DeviceSettingsRuntimeAdapter.imageCapacityKey
              ? 123
              : false);
    }
  }
}

String _document(Map<String, Object> values) => jsonEncode({
  'format': 'focubili-settings',
  'schemaVersion': 1,
  'settings': values,
});

void main() {
  late _Preferences prefs;
  late _Runtime runtime;
  late SettingsTransferService service;
  var loads = 0;
  setUp(() {
    prefs = _Preferences();
    runtime = _Runtime();
    loads = 0;
    service = SettingsTransferService(
      preferencesLoader: () async {
        loads++;
        return prefs;
      },
      runtimeAdapter: runtime,
    );
  });

  test('new search keywords round-trip with case and order intact', () async {
    final raw = jsonEncode({
      'learningOnly': false,
      'minimumPlayCount': 2000000000,
      'titleKeywords': ['Flutter', '数学', 'dart'],
      'ownerKeywords': ['UP主', 'OpenAI'],
    });
    await service.importSettings(
      service.parseSettings(_document({_search: raw})),
    );
    final exported = service.parseSettings(await service.exportSettings());
    expect(exported[_search], raw);
    final filter = SearchContentFilter.fromJsonStrict(
      jsonDecode(exported[_search] as String),
    );
    expect(filter.titleKeywords, ['Flutter', '数学', 'dart']);
    expect(filter.ownerKeywords, ['UP主', 'OpenAI']);
    expect(prefs.values[_blocklist], _rules);
  });

  test('legacy two-field search settings remain compatible', () async {
    const raw = '{"learningOnly":true,"minimumPlayCount":0}';
    await service.importSettings(
      service.parseSettings(_document({_search: raw})),
    );
    expect(service.parseSettings(await service.exportSettings())[_search], raw);
  });

  test(
    'strict search validation rejects every malformed field before any write',
    () async {
      final valid = <String, Object>{
        'learningOnly': false,
        'minimumPlayCount': 0,
      };
      final invalid = <Object?>[
        null,
        [],
        true,
        {...valid, 'futureField': true},
        {...valid, 'minimumPlayCount': 2000000001},
        {...valid, 'minimumPlayCount': 1.0},
        {...valid, 'minimumPlayCount': -1},
        {'minimumPlayCount': 0},
        {'learningOnly': false},
        for (final key in ['titleKeywords', 'ownerKeywords'])
          for (final value in <Object?>[
            null,
            true,
            'word',
            [1],
            ['ok', null],
            {},
          ])
            {...valid, key: value},
      ];
      for (final value in invalid) {
        final updates = <String, Object>{
          'appearance.theme_mode': 'light',
          DeviceSettingsRuntimeAdapter.enabledKey: true,
          _search: jsonEncode(value),
        };
        expect(
          () => service.parseSettings(_document(updates)),
          throwsFormatException,
        );
        await expectLater(
          service.importSettings(updates),
          throwsFormatException,
        );
        expect(prefs.values['appearance.theme_mode'], 'dark');
        expect(prefs.values[_blocklist], _rules);
        expect(prefs.writes, 0);
        expect(runtime.reads, 0);
        expect(runtime.writes, 0);
        expect(loads, 0);
      }
    },
  );

  test(
    'settings export rejects corrupted search keywords without normalizing storage',
    () async {
      const raw =
          '{"learningOnly":false,"minimumPlayCount":0,"titleKeywords":[7]}';
      prefs.values[_search] = raw;
      await expectLater(service.exportSettings(), throwsFormatException);
      expect(prefs.values[_search], raw);
      expect(prefs.writes, 0);
      expect(runtime.reads, 0);
    },
  );

  test('reset and unrelated imports retain blocklist user rules', () async {
    await service.importSettings({'appearance.theme_mode': 'light'});
    expect(prefs.values[_blocklist], _rules);
    expect(
      service.parseSettings(await service.exportSettings()),
      isNot(contains(_blocklist)),
    );
    await service.resetSettings();
    expect(prefs.values, {_blocklist: _rules});
    expect(
      () => service.parseSettings(_document({_blocklist: 'overwritten'})),
      throwsFormatException,
    );
    await expectLater(
      service.importSettings({_blocklist: 'overwritten'}),
      throwsFormatException,
    );
    expect(prefs.values[_blocklist], _rules);
  });

  test(
    'caller map mutation cannot bypass validation while storage opens',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      service = SettingsTransferService(
        preferencesLoader: () async {
          entered.complete();
          await release.future;
          return prefs;
        },
        runtimeAdapter: runtime,
      );
      final updates = <String, Object>{'appearance.theme_mode': 'light'};
      final pending = service.importSettings(updates);
      await entered.future;
      updates[_blocklist] = 'UNVALIDATED_USER_RULE_OVERWRITE';
      updates['appearance.theme_mode'] = 'system';
      release.complete();
      await pending;
      expect(prefs.values[_blocklist], _rules);
      expect(prefs.values['appearance.theme_mode'], 'light');
    },
  );

  test('caller list mutation cannot change a fully validated import', () async {
    final entered = Completer<void>(), release = Completer<void>();
    service = SettingsTransferService(
      preferencesLoader: () async {
        entered.complete();
        await release.future;
        return prefs;
      },
      runtimeAdapter: runtime,
    );
    final speeds = ['1.25', '2.0'];
    final pending = service.importSettings({
      'playback_preferences.speeds': speeds,
    });
    await entered.future;
    speeds.add('INVALID_AFTER_VALIDATION');
    release.complete();
    await pending;
    expect(prefs.values['playback_preferences.speeds'], ['1.25', '2.0']);
  });
}
