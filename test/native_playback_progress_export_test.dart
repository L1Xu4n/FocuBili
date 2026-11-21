import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_progress_export.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/unified_export_service.dart';

const bv = 'BV1GJ411x7h7';
const course = 'CHEESE:SS968174948';
const channel = MethodChannel('com.focubili.app/playback');
const sentinel = 'SYNTHETIC_PRIVATE_DO_NOT_EXPORT';

Map<String, Object?> document() => {
  'format': NativePlaybackProgressExport.format,
  'version': 1,
  'lastParts': <Object?>[
    {'bvid': bv, 'cid': 202, 'pageNumber': 2},
    {'bvid': course, 'cid': 302, 'pageNumber': 1},
  ],
  'parts': <Object?>[
    {
      'bvid': bv,
      'cid': 101,
      'positionMs': 12000,
      'durationMs': 90000,
      'savedAtMs': 1700000000000,
    },
    {'bvid': bv, 'cid': 202, 'positionMs': 24000, 'durationMs': 120000},
    {'bvid': bv, 'cid': 103, 'savedAtMs': 1700000001000},
    {
      'bvid': course,
      'cid': 302,
      'positionMs': 36000,
      'durationMs': 120000,
      'savedAtMs': 1700000002000,
    },
  ],
};

Map<String, dynamic> jsonFile(Archive archive, String name) =>
    jsonDecode(utf8.decode(archive.find(name)!.content))
        as Map<String, dynamic>;

Future<Archive> historyPackage({
  AppPlatform platform = AppPlatform.android,
}) async => ZipDecoder().decodeBytes(
  (await UnifiedExportService(
    platform: platform,
  ).buildPackage(sections: {UnifiedExportSection.history})).bytes,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'real Android history package contains all parts, classroom and cleared timestamps without touching preferences',
    () async {
      final stored = <String, Object>{
        'focubili_watch_history': '[{"bvid":"$bv"}]',
        'windows_playback_state_${bv}_cid_101': '{"positionMs":4000}',
        'bilibili_cookie': sentinel,
        'unknown_native_progress': sentinel,
      };
      SharedPreferences.setMockInitialValues(stored);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return document();
      });
      final archive = await historyPackage();
      expect(calls.single.method, 'exportSavedPlaybackProgress');
      expect(calls.single.arguments, isNull);
      expect(
        archive.files.map((e) => e.name),
        containsAll([
          'manifest.json',
          'history.json',
          'native_playback_progress.json',
        ]),
      );
      final native = jsonFile(archive, 'native_playback_progress.json');
      final rows = native['parts'] as List;
      expect(rows.length, 4);
      expect(rows.where((row) => row['bvid'] == bv).map((row) => row['cid']), [
        101,
        103,
        202,
      ]);
      expect(rows.singleWhere((row) => row['cid'] == 103), {
        'bvid': bv,
        'cid': 103,
        'savedAtMs': 1700000001000,
      });
      expect(rows.last['bvid'], course);
      expect((native['lastParts'] as List).first['pageNumber'], 2);
      expect(rows.every((row) => !row.containsKey('pageNumber')), isTrue);
      final history = jsonFile(archive, 'history.json')['values'] as Map;
      expect(
        history['windows_playback_state_${bv}_cid_101'],
        stored['windows_playback_state_${bv}_cid_101'],
      );
      expect(jsonFile(archive, 'manifest.json')['sections'], ['history']);
      expect(
        archive.files
            .where((e) => e.isFile)
            .map((e) => utf8.decode(e.content))
            .join(),
        isNot(contains(sentinel)),
      );
      final prefs = await SharedPreferences.getInstance();
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, stored);
    },
  );

  test('valid empty native storage is an explicit empty document', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'format': NativePlaybackProgressExport.format,
        'version': 1,
        'lastParts': [],
        'parts': [],
      },
    );
    expect(
      jsonFile(
        await historyPackage(),
        'native_playback_progress.json',
      )['parts'],
      isEmpty,
    );
  });

  test(
    'actual native open contract preserves all historical BV prefix variants',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final service = NativePlaybackService();
      final ids = [
        'BV',
        'Bv',
        'bV',
        'bv',
      ].map((prefix) => '${prefix}1gJ411X7h7').toList();
      try {
        for (final id in ids) {
          await service.openVideo(
            VideoPreview(
              bvid: id,
              cid: 101,
              title: 'Synthetic lesson',
              ownerName: 'Synthetic author',
              parts: const [
                VideoPart(
                  pageNumber: 1,
                  cid: 101,
                  title: 'Words',
                  duration: Duration(seconds: 90),
                ),
              ],
            ),
          );
        }
        expect(
          calls
              .where((call) => call.method == 'open')
              .map((call) => (call.arguments as Map)['bvid']),
          ids,
        );
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'history package preserves coexisting BV prefix variants and case-sensitive bodies',
    () async {
      final ids = [
        'BV',
        'Bv',
        'bV',
        'bv',
      ].map((prefix) => '${prefix}1gJ411X7h7').toList();
      final raw = document();
      raw['lastParts'] = [
        for (final id in ids) {'bvid': id, 'cid': 101, 'pageNumber': 1},
      ];
      raw['parts'] = [
        for (var i = 0; i < ids.length; i++)
          {
            'bvid': ids[i],
            'cid': 101,
            'positionMs': 12000 + i,
            'durationMs': 90000,
          },
      ];
      messenger.setMockMethodCallHandler(channel, (_) async => raw);
      final exported = jsonFile(
        await historyPackage(),
        'native_playback_progress.json',
      );
      final rows = exported['parts'] as List;
      expect(rows.map((row) => row['bvid']).toSet(), ids.toSet());
      expect((exported['lastParts'] as List).length, 4);
      for (var i = 0; i < ids.length; i++) {
        expect(
          rows.singleWhere((row) => row['bvid'] == ids[i])['positionMs'],
          12000 + i,
        );
      }
    },
  );

  test(
    'legacy zero position without timestamp survives the actual history package',
    () async {
      final raw = document();
      (raw['parts'] as List).add({
        'bvid': bv,
        'cid': 909,
        'positionMs': 0,
        'durationMs': 90000,
      });
      messenger.setMockMethodCallHandler(channel, (_) async => raw);
      final rows =
          jsonFile(
                await historyPackage(),
                'native_playback_progress.json',
              )['parts']
              as List;
      expect(rows.singleWhere((row) => row['cid'] == 909), {
        'bvid': bv,
        'cid': 909,
        'positionMs': 0,
        'durationMs': 90000,
      });
    },
  );

  for (final platform in AppPlatform.values.where(
    (p) => p != AppPlatform.android,
  )) {
    test(
      '$platform history keeps Windows prefs and never invokes native loader or channel',
      () async {
        SharedPreferences.setMockInitialValues({
          'windows_playback_state_${bv}_cid_101': '{"positionMs":1000}',
        });
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          throw StateError('Must not call channel');
        });
        final package = await UnifiedExportService(
          platform: platform,
          nativePlaybackProgressLoader: () async {
            calls++;
            throw StateError('Must not load native progress');
          },
        ).buildPackage(sections: {UnifiedExportSection.history});
        final archive = ZipDecoder().decodeBytes(package.bytes);
        expect(calls, 0);
        expect(archive.find('native_playback_progress.json'), isNull);
        expect(
          (jsonFile(archive, 'history.json')['values'] as Map).keys,
          contains('windows_playback_state_${bv}_cid_101'),
        );
      },
    );
  }

  test(
    'default host detection never treats a Windows/Linux test host as Android',
    () async {
      expect(AppPlatformDetector.current, isNot(AppPlatform.android));
      var calls = 0;
      final package = await UnifiedExportService(
        nativePlaybackProgressLoader: () async {
          calls++;
          return document();
        },
      ).buildPackage(sections: {UnifiedExportSection.history});
      expect(calls, 0);
      expect(
        ZipDecoder()
            .decodeBytes(package.bytes)
            .find('native_playback_progress.json'),
        isNull,
      );
    },
  );

  test(
    'Android export without selected history never invokes native progress',
    () async {
      var calls = 0;
      await UnifiedExportService(
        platform: AppPlatform.android,
        nativePlaybackProgressLoader: () async {
          calls++;
          throw StateError('Unexpected loader');
        },
      ).buildPackage(sections: {UnifiedExportSection.favorites});
      expect(calls, 0);
    },
  );

  for (final missingPlugin in [false, true]) {
    test(
      'unavailable native progress blocks the whole package; missingPlugin=$missingPlugin',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (missingPlugin) throw MissingPluginException();
          throw PlatformException(
            code: 'progress_export_failed',
            message: sentinel,
            details: sentinel,
          );
        });
        await expectLater(
          historyPackage(),
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'safe message',
              isNot(contains(sentinel)),
            ),
          ),
        );
      },
    );
  }

  final badParts = <String, Map<String, Object?>>{
    'arbitrary BX prefix': {'bvid': 'BX1gJ411X7h7', 'cid': 909, 'savedAtMs': 1},
    'arbitrary VB prefix': {'bvid': 'VB1gJ411X7h7', 'cid': 909, 'savedAtMs': 1},
    'unknown request URL': {
      'bvid': bv,
      'cid': 909,
      'savedAtMs': 1,
      'url': sentinel,
    },
    'unknown cookie': {
      'bvid': bv,
      'cid': 909,
      'savedAtMs': 1,
      'cookie': sentinel,
    },
    'URL identity': {
      'bvid': 'https://example.invalid/$sentinel',
      'cid': 909,
      'savedAtMs': 1,
    },
    'invalid namespace': {'bvid': 'CHEESE:SS0', 'cid': 909, 'savedAtMs': 1},
    'overflow season': {
      'bvid': 'CHEESE:SS999999999999999999999',
      'cid': 909,
      'savedAtMs': 1,
    },
    'zero CID': {'bvid': bv, 'cid': 0, 'savedAtMs': 1},
    'fractional CID': {'bvid': bv, 'cid': 9.5, 'savedAtMs': 1},
    'negative position': {
      'bvid': bv,
      'cid': 909,
      'positionMs': -1,
      'durationMs': 100,
    },
    'fractional position': {
      'bvid': bv,
      'cid': 909,
      'positionMs': 1.5,
      'durationMs': 100,
    },
    'nonfinite position': {
      'bvid': bv,
      'cid': 909,
      'positionMs': double.nan,
      'durationMs': 100,
    },
    'zero duration': {'bvid': bv, 'cid': 909, 'positionMs': 0, 'durationMs': 0},
    'position beyond duration': {
      'bvid': bv,
      'cid': 909,
      'positionMs': 101,
      'durationMs': 100,
    },
    'missing duration': {'bvid': bv, 'cid': 909, 'positionMs': 50},
    'missing position': {'bvid': bv, 'cid': 909, 'durationMs': 100},
    'empty part': {'bvid': bv, 'cid': 909},
    'null timestamp': {'bvid': bv, 'cid': 909, 'savedAtMs': null},
    'future invalid timestamp': {
      'bvid': bv,
      'cid': 909,
      'savedAtMs': 253402300800000,
    },
    'duplicate part': {'bvid': bv, 'cid': 101, 'savedAtMs': 1},
  };
  for (final entry in badParts.entries) {
    test(
      '${entry.key} blocks valid plus invalid native rows instead of partial export',
      () async {
        final raw = document();
        (raw['parts'] as List).add(entry.value);
        messenger.setMockMethodCallHandler(channel, (_) async => raw);
        await expectLater(historyPackage(), throwsFormatException);
      },
    );
  }

  for (final mode in [
    'unknown envelope',
    'future version',
    'bad last CID',
    'bad last page',
    'duplicate last',
    'unknown last',
    'missing native',
    'wrong list',
  ]) {
    test(
      '$mode cannot become a successful empty or partial history package',
      () async {
        final raw = document();
        switch (mode) {
          case 'unknown envelope':
            raw['headers'] = sentinel;
          case 'future version':
            raw['version'] = 2;
          case 'bad last CID':
            (raw['lastParts'] as List).add({
              'bvid': bv,
              'cid': -1,
              'pageNumber': 1,
            });
          case 'bad last page':
            (raw['lastParts'] as List).add({
              'bvid': bv,
              'cid': 909,
              'pageNumber': 1.5,
            });
          case 'duplicate last':
            (raw['lastParts'] as List).add({
              'bvid': bv,
              'cid': 909,
              'pageNumber': 1,
            });
          case 'unknown last':
            (raw['lastParts'] as List).add({
              'bvid': bv,
              'cid': 909,
              'pageNumber': 1,
              'token': sentinel,
            });
          case 'wrong list':
            raw['parts'] = {};
        }
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => mode == 'missing native' ? null : raw,
        );
        await expectLater(historyPackage(), throwsFormatException);
      },
    );
  }

  test(
    'an injected loader is held to the same strict native document whitelist',
    () async {
      final raw = document()..['session'] = sentinel;
      await expectLater(
        UnifiedExportService(
          platform: AppPlatform.android,
          nativePlaybackProgressLoader: () async => raw,
        ).buildPackage(sections: {UnifiedExportSection.history}),
        throwsFormatException,
      );
    },
  );
}
