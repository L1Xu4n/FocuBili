import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:focubili/services/unified_settings_restore.dart';
import 'package:focubili/services/video_tag_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _theme = 'appearance.theme_mode';
const _speeds = 'playback_preferences.speeds';
const _opacity = 'playback_preferences.subtitle_opacity';
const _blocklist = ContentBlocklistService.storageKey;
const _runtime = {
  DeviceSettingsRuntimeAdapter.enabledKey: true,
  DeviceSettingsRuntimeAdapter.notificationsKey: true,
  DeviceSettingsRuntimeAdapter.backgroundKey: true,
  DeviceSettingsRuntimeAdapter.wifiOnlyBackgroundKey: true,
  DeviceSettingsRuntimeAdapter.imageCapacityKey: 64 * 1024 * 1024,
};

class _ExportRuntime implements SettingsRuntimeAdapter {
  @override
  Future<Map<String, Object>> readSettings() async => _runtime;

  @override
  Future<void> writeSettings(Map<String, Object?> values) async =>
      fail('Export must not modify runtime settings');
}

class _NoRuntime implements SettingsRuntimeAdapter {
  @override
  Future<Map<String, Object>> readSettings() async =>
      fail('Restore must not read runtime settings');

  @override
  Future<void> writeSettings(Map<String, Object?> values) async =>
      fail('Restore must not modify runtime settings');
}

class _RejectBlocklistWrite extends InMemorySharedPreferencesStore {
  _RejectBlocklistWrite() : super.withData({'flutter.unrelated': 'untouched'});

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.$_blocklist') return Future.value(false);
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UnifiedSettingsRestore restore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    restore = UnifiedSettingsRestore(
      settingsTransfer: SettingsTransferService(runtimeAdapter: _NoRuntime()),
    );
  });

  test(
    'v1 ZIP settings roundtrip sets only absent portable preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        _theme: 'dark',
        _speeds: ['1.0', '2.0'],
        _opacity: 0.75,
        'search.content_filter_v2':
            '{"learningOnly":true,"minimumPlayCount":75}',
        'app_behavior.account_read_only': false,
        'app_behavior.wbi_signing_enabled': true,
        'focus_preferences.enable_do_not_disturb': true,
        'windows_clipboard_link_detection.enabled': true,
        'app_update.check_on_start': false,
        'app_update.ignored_release': '["a","b","c","d"]',
        'windows_media_cache_capacity_bytes': 128 * 1024 * 1024,
      });
      const blocklistService = ContentBlocklistService();
      await blocklistService.blockVideo('BV1234567890', '测试视频');
      await blocklistService.blockCreator(42, '测试作者');
      final export = await UnifiedExportService(
        settingsRuntimeAdapter: _ExportRuntime(),
      ).buildPackage(sections: {UnifiedExportSection.settings});
      final settings = ZipDecoder()
          .decodeBytes(export.bytes)
          .find('settings.json')!;
      final values =
          (jsonDecode(utf8.decode(settings.content)) as Map)['values']
              as Map<String, dynamic>;

      SharedPreferences.setMockInitialValues({
        _theme: 'system',
        'app_behavior.account_read_only': true,
        'focubili_bilibili_cookie': 'local synthetic session',
        'first_launch_user_agreement_2026_07_18_accepted': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final plan = restore.validate(values);
      expect(plan.candidateCount, 5);
      expect(plan.skippedCount, 12);
      expect(preferences.get(_speeds), isNull);

      final result = await restore.apply(plan);
      expect(result.added, 4);
      expect(result.retained, 1);
      expect(result.skipped, 12);
      expect(preferences.getString(_theme), 'system');
      expect(preferences.getDouble(_opacity), 0.75);
      expect(preferences.getStringList(_speeds), ['1.0', '2.0']);
      expect(
        (await blocklistService.load()).blocks(
          bvid: 'BV1234567890',
          ownerMid: 0,
        ),
        isTrue,
      );
      expect((await blocklistService.load()).blocksCreator(uid: 42), isTrue);
      expect(preferences.getBool('app_behavior.account_read_only'), isTrue);
      expect(
        preferences.getString('focubili_bilibili_cookie'),
        'local synthetic session',
      );
      expect(
        preferences.getBool('first_launch_user_agreement_2026_07_18_accepted'),
        isTrue,
      );
      for (final key in values.keys) {
        if (!SettingsTransferService.isPortableZipKey(key) &&
            key != 'app_behavior.account_read_only') {
          expect(preferences.get(key), isNull, reason: key);
        }
      }

      final repeated = await restore.apply(plan);
      expect(repeated.added, 0);
      expect(repeated.retained, plan.candidateCount);
    },
  );

  test(
    'excluded and unfamiliar keys are skipped without touching storage',
    () async {
      final restore = UnifiedSettingsRestore(
        settingsTransfer: SettingsTransferService(
          preferencesLoader: () async => fail('Nothing should be loaded'),
          runtimeAdapter: _NoRuntime(),
        ),
      );
      final result = await restore.restore({
        ..._runtime,
        'unknown': {'accountToken': 'synthetic'},
        'appearance.text_scale': 1.15, // JSON-only, not in v1 ZIP.
      });
      expect(result.skipped, 7);
      expect(result.added, 0);
      expect(result.retained, 0);
    },
  );

  test(
    'plan freezes a list; commit respects a later existing preference',
    () async {
      final speeds = ['1.0', '2.0'];
      final plan = restore.validate({_theme: 'light', _speeds: speeds});
      speeds[0] = 'invalid';
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_theme, 'dark');

      final result = await restore.apply(plan);
      expect(result.retained, 1);
      expect(preferences.getStringList(_speeds), ['1.0', '2.0']);
      expect(preferences.getString(_theme), 'dark');
    },
  );

  test('malformed portable settings fail before a preference write', () async {
    for (final bad in [
      {_opacity: null},
      {_opacity: '0.6'},
      {_blocklist: '{"version":1,"videos":{}}'},
      {_blocklist: '{"version":1,"videos":{"bad":"x"},"creators":{}}'},
      {_blocklist: '{"version":1,"videos":{},"creators":{"0":"x"}}'},
      {
        _blocklist:
            '{"version":1,"videos":{},"creators":{},"rules":{"videoTag":[""]}}',
      },
      {
        _blocklist:
            '{"version":1,"videos":{},"creators":{},"rules":{"videoTag":["x","X"]}}',
      },
    ]) {
      await expectLater(
        restore.restore({_theme: 'dark', ...bad}),
        throwsFormatException,
      );
    }
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), isEmpty);
  });

  test('rollback removes an earlier addition if a later write fails', () async {
    SharedPreferencesStorePlatform.instance = _RejectBlocklistWrite();
    SharedPreferences.resetStatic();
    final changes = ContentBlocklistService.changes.value;
    await expectLater(
      restore.restore({
        _theme: 'dark',
        _blocklist: '{"version":1,"videos":{},"creators":{}}',
      }),
      throwsStateError,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), {'unrelated'});
    expect(preferences.get('unrelated'), 'untouched');
    expect(ContentBlocklistService.changes.value, changes);
    expect((await restore.restore({_theme: 'dark'})).added, 1);
  });

  test(
    'pending blocklist edit is retained, not overwritten by restore',
    () async {
      const blocklistService = ContentBlocklistService();
      final plan = restore.validate({
        _blocklist: '{"version":1,"videos":{},"creators":{"42":"older"}}',
      });
      final edit = blocklistService.blockCreator(43, 'newer');
      final result = await restore.apply(plan);
      await edit;
      expect(result.retained, 1);
      expect(result.added, 0);
      expect((await blocklistService.load()).creators, {43: 'newer'});
    },
  );

  test('restore does not start live tag or blocklist listeners', () async {
    final tagChanges = VideoTagPreferences.changes.value;
    final blocklistChanges = ContentBlocklistService.changes.value;
    final result = await restore.restore({
      VideoTagPreferences.key: 'expanded',
      _blocklist: '{"version":1,"videos":{},"creators":{}}',
    });
    expect(result.added, 2);
    expect(await VideoTagPreferences.load(), VideoTagMode.expanded);
    expect(VideoTagPreferences.changes.value, tagChanges);
    expect(ContentBlocklistService.changes.value, blocklistChanges);
  });
}
