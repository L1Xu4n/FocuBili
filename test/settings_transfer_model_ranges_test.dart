import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/danmaku_preferences.dart';
import 'package:focubili/models/dashboard_layout.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/app_theme_mode_service.dart';
import 'package:focubili/services/danmaku_preferences_service.dart';
import 'package:focubili/services/dashboard_layout_service.dart';
import 'package:focubili/services/media_cache_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';

class _Runtime implements SettingsRuntimeAdapter {
  final values = <String, Object>{
    DeviceSettingsRuntimeAdapter.enabledKey: false,
    DeviceSettingsRuntimeAdapter.notificationsKey: false,
    DeviceSettingsRuntimeAdapter.backgroundKey: false,
    DeviceSettingsRuntimeAdapter.imageCapacityKey: 256 * 1024 * 1024,
  };
  @override
  Future<Map<String, Object>> readSettings() async => Map.of(values);
  @override
  Future<void> writeSettings(Map<String, Object?> updates) async {
    for (final entry in updates.entries) {
      values[entry.key] = entry.value ?? false;
    }
  }
}

String _file(Map<String, Object> values) => jsonEncode({
  'format': 'focubili-settings',
  'schemaVersion': 1,
  'settings': values,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final bad = <String, Object>{
    'playback_preferences.speeds': ['1', '0.25', '1.234'],
    'playback_preferences.long_press_speed': 5.1,
    'playback_preferences.control_scale': 0.7,
    'playback_preferences.subtitle_font_size': 37.0,
    'playback_preferences.wifi_default_quality': 1,
    'playback_preferences.mobile_default_quality': 121,
    'appearance.theme_color': 0x100000000,
    'playback_preferences.double_tap_regions':
        '{"leftWidth":0.05,"rightWidth":0.5,"height":0.2}',
    DanmakuPreferencesService.storageKey:
        '{"enabled":true,"opacity":0.1,"fontSize":31,"laneCount":25}',
    'windows_media_cache_capacity_bytes': 1,
  };
  for (final entry in bad.entries) {
    test('reject loader-changing value ${entry.key}', () async {
      const service = SettingsTransferService();
      Object? rejected;
      try {
        await service.importSettings(
          service.parseSettings(_file({entry.key: entry.value})),
        );
      } catch (error) {
        rejected = error;
      }
      Object? actual;
      if (entry.key.startsWith('playback_preferences.')) {
        final value = await const PlaybackPreferencesService().load();
        actual = {
          'speeds': value.playbackSpeeds,
          'longPress': value.longPressPlaybackSpeed,
          'scale': value.controlScale,
          'font': value.subtitleFontSize,
          'wifi': value.wifiDefaultQuality.id,
          'mobile': value.mobileDefaultQuality.id,
          'regions': value.doubleTapRegions.toMap(),
        };
      } else if (entry.key == DanmakuPreferencesService.storageKey) {
        actual = (await DanmakuPreferencesService().load()).toJson();
      } else if (entry.key == 'appearance.theme_color') {
        actual = (await const AppThemeModeService().loadColor()).toARGB32();
      } else {
        actual = await WindowsMediaCacheService().loadCapacityBytes();
      }
      expect(
        rejected,
        isA<FormatException>(),
        reason: 'accepted ${entry.value}; real loader=$actual',
      );
      expect((await SharedPreferences.getInstance()).get(entry.key), isNull);
    });
  }

  test(
    'both boundaries and model precision survive actual playback loading',
    () async {
      const service = SettingsTransferService();
      for (final settings in [
        <String, Object>{
          'playback_preferences.speeds': ['0.5', '1', '5', '1.23'],
          'playback_preferences.long_press_speed': 1.0,
          'playback_preferences.control_scale':
              PlaybackPreferences.minControlScale,
          'playback_preferences.subtitle_font_size':
              PlaybackPreferences.minSubtitleFontSize,
          'playback_preferences.double_tap_regions': jsonEncode(
            const DoubleTapRegions(
              leftWidth: 0.1,
              rightWidth: 0.45,
              height: 0.4,
            ).toMap(),
          ),
        },
        <String, Object>{
          'playback_preferences.speeds': ['5', '0.5', '5.0'],
          'playback_preferences.long_press_speed': 5.0,
          'playback_preferences.control_scale':
              PlaybackPreferences.maxControlScale,
          'playback_preferences.subtitle_font_size':
              PlaybackPreferences.maxSubtitleFontSize,
          'playback_preferences.double_tap_regions': jsonEncode(
            const DoubleTapRegions(
              leftWidth: 0.45,
              rightWidth: 0.1,
              height: 1,
            ).toMap(),
          ),
        },
      ]) {
        await service.importSettings(service.parseSettings(_file(settings)));
        final loaded = await const PlaybackPreferencesService().load();
        expect(
          loaded.longPressPlaybackSpeed,
          settings['playback_preferences.long_press_speed'],
        );
        expect(
          loaded.controlScale,
          settings['playback_preferences.control_scale'],
        );
        expect(
          loaded.subtitleFontSize,
          settings['playback_preferences.subtitle_font_size'],
        );
        expect(
          loaded.doubleTapRegions.toMap(),
          jsonDecode(
            settings['playback_preferences.double_tap_regions'] as String,
          ),
        );
      }
      // Sorting, deduplication, adding normal speed and numeric string formatting
      // are intentional list semantics, not a rejected range change.
      expect((await const PlaybackPreferencesService().load()).playbackSpeeds, [
        0.5,
        1,
        5,
      ]);
    },
  );

  test('all real quality ids and color boundaries remain accepted', () async {
    const service = SettingsTransferService();
    for (final quality in PreferredPlaybackQuality.values) {
      await service.importSettings({
        'playback_preferences.wifi_default_quality': quality.id,
        'playback_preferences.mobile_default_quality': quality.id,
      });
      final value = await const PlaybackPreferencesService().load();
      expect(value.wifiDefaultQuality, quality);
      expect(value.mobileDefaultQuality, quality);
    }
    for (final color in [1, 0xFFFFFFFF, defaultThemeSeedColorValue]) {
      await service.importSettings({'appearance.theme_color': color});
      expect((await const AppThemeModeService().loadColor()).toARGB32(), color);
    }
  });

  test(
    'valid model-produced complete export roundtrips without changing values',
    () async {
      final service = SettingsTransferService(runtimeAdapter: _Runtime());
      final valid = <String, Object>{
        'playback_preferences.speeds': [
          '0.75',
          '1.0',
          '1.25',
          '1.5',
          '2.0',
          '3.0',
        ],
        'playback_preferences.long_press_speed': 2.5,
        'playback_preferences.control_scale': 1.15,
        'playback_preferences.subtitle_font_size': 24.0,
        'playback_preferences.wifi_default_quality': 112,
        'playback_preferences.mobile_default_quality': 16,
        'appearance.theme_mode': 'dark',
        'appearance.theme_color': Colors.blue.toARGB32(),
        'appearance.layout_orientation': 'adaptive',
        'playback_preferences.double_tap_regions': jsonEncode(
          const DoubleTapRegions().toMap(),
        ),
        DanmakuPreferencesService.storageKey: jsonEncode(
          DanmakuPreferences(
            enabled: true,
            fontSize: 15.5,
            opacity: 0.4,
            laneCount: 8,
            blockedKeywords: ['synthetic-blocked'],
          ).toJson(),
        ),
        'dashboard.layout.home':
            '{"version":1,"order":["unknown-old-card"],"hidden":[]}',
        'dashboard.layout.profile':
            '{"version":1,"order":[],"hidden":["unknown-old-card"]}',
        'windows_media_cache_capacity_bytes': supportedMediaCacheBytes.first,
      };
      await service.importSettings(service.parseSettings(_file(valid)));
      final export = await service.exportSettings();
      await service.resetSettings();
      await service.importSettings(service.parseSettings(export));
      final preferences = await SharedPreferences.getInstance();
      for (final entry in valid.entries) {
        expect(preferences.get(entry.key), entry.value, reason: entry.key);
      }
      expect((await DanmakuPreferencesService().load()).fontSize, 15.5);
    },
  );

  test(
    'each playback bound and precision mismatch rejects before storage reads',
    () async {
      var reads = 0;
      final service = SettingsTransferService(
        preferencesLoader: () async {
          reads++;
          return SharedPreferences.getInstance();
        },
      );
      final cases = <String, List<Object>>{
        'playback_preferences.speeds': [
          ['0.49'],
          ['5.01'],
          ['1.234'],
          ['NaN'],
          ['Infinity'],
        ],
        'playback_preferences.long_press_speed': [0.99, 5.01, 2.1],
        'playback_preferences.control_scale': [0.79, 2.01, 1.03],
        'playback_preferences.subtitle_font_size': [11.99, 36.01, 16.5],
        'playback_preferences.wifi_default_quality': [
          0,
          17,
          0x7fffffffffffffff,
        ],
        'playback_preferences.mobile_default_quality': [
          0,
          17,
          0x7fffffffffffffff,
        ],
        'appearance.theme_color': [0, 0x100000000],
        'windows_media_cache_capacity_bytes': [0, 1, 0x7fffffffffffffff],
      };
      for (final entry in cases.entries) {
        for (final value in entry.value) {
          final settings = {entry.key: value};
          expect(
            () => service.parseSettings(_file(settings)),
            throwsFormatException,
            reason: '${entry.key}=$value',
          );
          await expectLater(
            service.importSettings(settings),
            throwsFormatException,
            reason: '${entry.key}=$value',
          );
        }
      }
      for (final entry in <String, List<double>>{
        'leftWidth': [0.099, 0.451],
        'rightWidth': [0.099, 0.451],
        'height': [0.399, 1.001],
      }.entries) {
        for (final value in entry.value) {
          final regions = {
            ...const DoubleTapRegions().toMap(),
            entry.key: value,
          };
          final settings = {
            'playback_preferences.double_tap_regions': jsonEncode(regions),
          };
          expect(
            () => service.parseSettings(_file(settings)),
            throwsFormatException,
          );
          await expectLater(
            service.importSettings(settings),
            throwsFormatException,
          );
        }
      }
      expect(reads, 0);
    },
  );

  test(
    'danmaku lower upper and fractional values use the actual model domain',
    () async {
      const service = SettingsTransferService();
      final limits = <String, List<num>>{
        'opacity': [
          DanmakuPreferences.minOpacity,
          DanmakuPreferences.maxOpacity,
        ],
        'fontSize': [
          DanmakuPreferences.minFontSize,
          DanmakuPreferences.maxFontSize,
        ],
        'laneCount': [
          DanmakuPreferences.minLaneCount,
          DanmakuPreferences.maxLaneCount,
        ],
        'scrollDurationSeconds': [
          DanmakuPreferences.minScrollDurationSeconds,
          DanmakuPreferences.maxScrollDurationSeconds,
        ],
        'displayArea': [
          DanmakuPreferences.minDisplayArea,
          DanmakuPreferences.maxDisplayArea,
        ],
        'strokeWidth': [
          DanmakuPreferences.minStrokeWidth,
          DanmakuPreferences.maxStrokeWidth,
        ],
      };
      for (final entry in limits.entries) {
        for (final value in entry.value) {
          await service.importSettings({
            DanmakuPreferencesService.storageKey: jsonEncode({
              entry.key: value,
            }),
          });
          expect(
            (await DanmakuPreferencesService().load()).toJson()[entry.key],
            value,
          );
        }
        final invalid = entry.key == 'laneCount'
            ? [entry.value.first - 1, entry.value.last + 1]
            : [entry.value.first - 0.01, entry.value.last + 0.01];
        for (final value in invalid) {
          final settings = {
            DanmakuPreferencesService.storageKey: jsonEncode({
              entry.key: value,
            }),
          };
          expect(
            () => service.parseSettings(_file(settings)),
            throwsFormatException,
          );
          await expectLater(
            service.importSettings(settings),
            throwsFormatException,
          );
        }
      }
      await service.importSettings({
        DanmakuPreferencesService.storageKey:
            '{"fontSize":15.5,"laneCount":24.9,"opacity":0.45}',
      });
      final loaded = await DanmakuPreferencesService().load();
      expect(loaded.fontSize, 15.5);
      expect(loaded.laneCount, 24);
      expect(loaded.opacity, 0.45);
      for (final capacity in supportedMediaCacheBytes) {
        await service.importSettings({
          'windows_media_cache_capacity_bytes': capacity,
        });
        expect(await WindowsMediaCacheService().loadCapacityBytes(), capacity);
      }
    },
  );

  test(
    'all schema booleans reject non-bool values and preserve both valid states',
    () async {
      final keys = [
        'app_behavior.account_read_only',
        'app_behavior.search_history_enabled',
        'app_behavior.watch_history_enabled',
        'app_behavior.wbi_signing_enabled',
        'app_update.check_on_start',
        'windows_clipboard_link_detection.enabled',
        'focus_preferences.enable_do_not_disturb',
        'playback_preferences.enable_double_tap_seek',
        'playback_preferences.action_animation',
        'playback_preferences.show_note_time_markers',
        'playback_preferences.two_finger_video_transform',
        'playback_preferences.prefer_offline_cache',
        DeviceSettingsRuntimeAdapter.enabledKey,
        DeviceSettingsRuntimeAdapter.notificationsKey,
        DeviceSettingsRuntimeAdapter.backgroundKey,
      ];
      var reads = 0;
      final runtime = _Runtime();
      final service = SettingsTransferService(
        runtimeAdapter: runtime,
        preferencesLoader: () async {
          reads++;
          return SharedPreferences.getInstance();
        },
      );
      for (final key in keys) {
        for (final invalid in <Object>[0, 'true', <String>[]]) {
          expect(
            () => service.parseSettings(_file({key: invalid})),
            throwsFormatException,
          );
          await expectLater(
            service.importSettings({key: invalid}),
            throwsFormatException,
          );
        }
      }
      expect(reads, 0);
      for (final value in [true, false]) {
        await service.importSettings(
          service.parseSettings(_file({for (final key in keys) key: value})),
        );
        final preferences = await SharedPreferences.getInstance();
        for (final key in keys) {
          expect(
            DeviceSettingsRuntimeAdapter.keys.contains(key)
                ? runtime.values[key]
                : preferences.getBool(key),
            value,
            reason: key,
          );
        }
        final playback = await const PlaybackPreferencesService().load();
        expect(playback.enableDoubleTapSeek, value);
        expect(playback.showPlaybackActionAnimation, value);
        expect(playback.showNoteTimeMarkers, value);
        expect(playback.enableTwoFingerVideoTransform, value);
        expect(playback.preferOfflineCache, value);
      }
    },
  );

  test(
    'layout limits preserve intentional reconciliation and unknown old ids',
    () async {
      const service = SettingsTransferService();
      final cards = [
        DashboardCardDefinition(
          id: 'core',
          title: 'core',
          icon: Icons.home,
          required: true,
          builder: (_) => const SizedBox(),
        ),
        DashboardCardDefinition(
          id: 'known',
          title: 'known',
          icon: Icons.home,
          builder: (_) => const SizedBox(),
        ),
      ];
      for (final id in ['home', 'profile']) {
        final key = 'dashboard.layout.$id';
        await service.importSettings({
          key:
              '{"order":["unknown-old-card","known","known",""],"hidden":["core","known"]}',
        });
        final layout = await DashboardLayoutService().load(id, cards);
        expect(layout.order, ['unknown-old-card', 'known', 'core']);
        expect(layout.hidden, {'known'});
        await service.importSettings({
          key: jsonEncode({
            'order': List.generate(100, (index) => 'unknown-$index'),
            'hidden': <String>[],
          }),
        });
        expect(
          (await DashboardLayoutService().load(id, cards)).order.length,
          102,
        );
        for (final badOrder in [
          List.generate(101, (i) => '$i'),
          <Object>[1],
        ]) {
          final settings = {
            key: jsonEncode({'order': badOrder, 'hidden': <String>[]}),
          };
          expect(
            () => service.parseSettings(_file(settings)),
            throwsFormatException,
          );
          await expectLater(
            service.importSettings(settings),
            throwsFormatException,
          );
        }
      }
    },
  );
}
