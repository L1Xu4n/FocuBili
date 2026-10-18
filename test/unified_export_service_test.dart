import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/cached_player_overlay_service.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:focubili/services/windows_playback_progress_store.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';
import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'fixtures/settings_runtime_fixture.dart';

Map<String, dynamic> _document(Archive archive, String name) =>
    jsonDecode(utf8.decode(archive.find(name)!.content))
        as Map<String, dynamic>;

class _UnreadableDiagnostics extends Fake implements SharedPreferences {
  @override
  Future<void> reload() async {}

  @override
  Set<String> getKeys() => {};

  @override
  String? getString(String key) => throw StateError('synthetic read failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all sections retain data while credentials and unknown preferences stay out',
    () async {
      SharedPreferences.setMockInitialValues({
        'appearance.theme_mode': 'dark',
        'content.blocklist_v1': '{"version":1,"videos":{}}',
        'focubili_learning_list_v2':
            '{"schemaVersion":3,"folders":[{"id":"math"}],"entries":[]}',
        'focubili_focus_history': '[{"id":"old-focus-record"}]',
        'app_favorites.folders_v1': '[{"id":"favorite-1"}]',
        'app_favorites.items_v1.favorite-1': '[{"bvid":"BV1GJ411x7h7"}]',
        'focubili_watch_history': '[{"bvid":"BV1GJ411x7h7"}]',
        'windows_playback_state_BV1GJ411x7h7_cid_100': '{"positionMs":1234}',
        'windows_playback_state_CHEESE:SS968174948_cid_102':
            '{"positionMs":47000}',
        // Synthetic values only. These ensure new broad export code cannot read
        // auth stores or accidentally turn getKeys() into an unfiltered dump.
        'bilibili_cookie': 'SYNTHETIC_COOKIE_DO_NOT_EXPORT',
        'bilibili_auth_session': 'SYNTHETIC_SESSION_DO_NOT_EXPORT',
        'unknown_future_key': 'SYNTHETIC_UNKNOWN_DO_NOT_EXPORT',
        'appearance.auth_token': 'SYNTHETIC_NESTED_DO_NOT_EXPORT',
      });
      final package = await UnifiedExportService(
        settingsRuntimeAdapter: const FixtureSettingsRuntimeAdapter(),
        subscriptionLoader: () async => {'sources': [], 'feed': []},
        subtitleLoader: () => [],
        diagnosticsLoader: () async => 'Fixture diagnostics, no credentials',
        clock: () => DateTime.utc(2026, 10, 18),
      ).buildPackage();
      final archive = ZipDecoder().decodeBytes(package.bytes);
      final allText = archive.files
          .where((file) => file.isFile)
          .map((file) => utf8.decode(file.content))
          .join('\n');
      expect(allText, isNot(contains('DO_NOT_EXPORT')));
      expect(
        _document(archive, 'manifest.json')['credentialsIncluded'],
        isFalse,
      );
      expect(
        _document(archive, 'settings.json')['values'],
        containsPair('appearance.theme_mode', 'dark'),
      );
      final learning = _document(archive, 'learning.json')['values'] as Map;
      expect(
        jsonDecode(learning['focubili_learning_list_v2'] as String)['folders'],
        isNotEmpty,
      );
      expect(learning['focubili_focus_history'], contains('old-focus-record'));
      expect(
        _document(archive, 'favorites.json')['values'],
        contains('app_favorites.items_v1.favorite-1'),
      );
      expect(
        _document(archive, 'history.json')['values'],
        contains('windows_playback_state_BV1GJ411x7h7_cid_100'),
      );
      expect(
        _document(archive, 'history.json')['values'],
        contains('windows_playback_state_CHEESE:SS968174948_cid_102'),
      );
      expect(package.warnings, hasLength(1));
      expect(archive.find('diagnostics.txt'), isNotNull);
    },
  );

  test(
    'selection is honored and unselected loaders are never invoked',
    () async {
      SharedPreferences.setMockInitialValues({
        'appearance.theme_mode': 'light',
      });
      final package = await UnifiedExportService(
        settingsRuntimeAdapter: const FixtureSettingsRuntimeAdapter(),
        subscriptionLoader: () async => throw StateError('unselected'),
        subtitleLoader: () => throw StateError('unselected'),
      ).buildPackage(sections: {UnifiedExportSection.settings});
      final archive = ZipDecoder().decodeBytes(package.bytes);
      expect(
        archive.files.map((file) => file.name),
        unorderedEquals(['settings.json', 'manifest.json', 'README.txt']),
      );
      expect(package.sections, [UnifiedExportSection.settings]);
    },
  );

  test(
    'note package embeds screenshot files and relative structured references',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'focubili-unified-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final frame = File('${directory.path}/frame.png');
      await frame.writeAsBytes([137, 80, 78, 71]);
      await VideoNoteService().saveNote(
        VideoNote(
          id: 'n1',
          bvid: 'BV1GJ411x7h7',
          videoTitle: 'Fixture video',
          ownerName: 'Fixture owner',
          partCid: 100,
          partPageNumber: 1,
          partTitle: 'part',
          title: 'Fixture note',
          body: 'contents',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          position: const Duration(seconds: 5),
          framePath: frame.path,
        ),
      );
      final package = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.notes},
      );
      final archive = ZipDecoder().decodeBytes(package.bytes);
      expect(archive.find('notes/focubili_notes.json'), isNotNull);
      expect(archive.find('notes/focubili_notes.md'), isNotNull);
      expect(
        archive.files.where((file) => file.name.startsWith('notes/images/')),
        hasLength(1),
      );
      expect(
        _document(archive, 'notes/focubili_notes.json')['notes'],
        hasLength(1),
      );
      expect(await frame.exists(), isTrue);
    },
  );

  test(
    'cache exports only live parsed cues and clears them on invalidation',
    () {
      final cache = SubtitleMemoryCache();
      addTearDown(cache.dispose);
      final now = DateTime.utc(2026);
      final result = SubtitleCueLoadResult(
        status: SubtitleLoadStatus.available,
        message: '',
        cues: const [
          SubtitleCue(
            from: Duration.zero,
            to: Duration(seconds: 2),
            content: '知识点',
          ),
        ],
      );
      cache.put(
        Object(),
        result,
        now,
        bvid: 'BV1GJ411x7h7',
        cid: 100,
        trackId: '1',
      );
      final exported = cache.exportCues(now);
      expect(
        exported.single.keys,
        unorderedEquals(['bvid', 'cid', 'trackId', 'cues']),
      );
      expect((exported.single['cues'] as List).single['content'], '知识点');
      expect(cache.exportCues(now.add(const Duration(minutes: 6))), isEmpty);
      cache.clear();
      expect(cache.exportCues(now), isEmpty);
    },
  );

  test(
    'empty selection fails instead of saving a misleading empty backup',
    () async {
      await expectLater(
        UnifiedExportService().buildPackage(sections: {}),
        throwsArgumentError,
      );
    },
  );

  test('loaded subtitles include SRT and readable timeline files', () async {
    SharedPreferences.setMockInitialValues({});
    final package = await UnifiedExportService(
      subtitleLoader: () => [
        {
          'bvid': 'BV1GJ411x7h7',
          'cid': 100,
          'trackId': '1',
          'cues': [
            {'fromMs': 1250, 'toMs': 3000, 'content': '知识点'},
          ],
        },
      ],
    ).buildPackage(sections: {UnifiedExportSection.subtitles});
    final archive = ZipDecoder().decodeBytes(package.bytes);
    expect(
      utf8.decode(archive.find('subtitles/track_1.srt')!.content),
      contains('00:00:01,250 --> 00:00:03,000'),
    );
    expect(
      utf8.decode(archive.find('subtitles/track_1.txt')!.content),
      contains('知识点'),
    );
    expect(package.warnings, isEmpty);
  });

  test(
    'subscription export omits runtime lease and source lifecycle tokens',
    () async {
      SharedPreferences.setMockInitialValues({
        SubscriptionService.storageKey: feedFixture(count: 2, sourceCount: 2),
      });
      final service = SubscriptionService(
        preferencesLoader: SharedPreferences.getInstance,
      );
      addTearDown(service.dispose);
      final data = await service.exportLocalData();
      expect(data['sources'], hasLength(2));
      expect(data['feed'], hasLength(2));
      expect(data.containsKey('leaseOwner'), isFalse);
      expect(
        (data['sources'] as List).every(
          (source) => !(source as Map).containsKey('token'),
        ),
        isTrue,
      );
    },
  );

  test('corrupt notes never become a successful empty export', () async {
    for (final raw in ['not-json', '{}', '[{"id":"unsupported"}]']) {
      SharedPreferences.setMockInitialValues({
        VideoNoteService.storageKey: raw,
      });
      await expectLater(
        UnifiedExportService().buildPackage(
          sections: {UnifiedExportSection.notes},
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'preferences read failure blocks export instead of reporting empty success',
    () async {
      await expectLater(
        UnifiedExportService(
          preferencesLoader: () async =>
              throw StateError('fixture read failed'),
        ).buildPackage(sections: {UnifiedExportSection.notes}),
        throwsStateError,
      );
    },
  );

  test(
    'missing note frames are explicitly reported without losing text',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'focubili-missing-export-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await VideoNoteService().saveNote(
        VideoNote(
          id: 'missing1',
          bvid: 'BV1GJ411x7h7',
          videoTitle: 'Fixture',
          ownerName: 'Fixture',
          partCid: 100,
          partPageNumber: 1,
          partTitle: 'A',
          title: 'Text stays',
          body: 'contents',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          position: const Duration(seconds: 5),
          framePath: '${directory.path}/missing.png',
        ),
      );
      final package = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.notes},
      );
      expect(package.warnings.single, contains('1 张笔记截图'));
      final archive = ZipDecoder().decodeBytes(package.bytes);
      final notes =
          _document(archive, 'notes/focubili_notes.json')['notes'] as List;
      expect(notes.single['body'], 'contents');
      expect(notes.single['frames'].single['path'], isNull);
    },
  );

  test(
    'real course progress storage keys and per-chapter positions are exported',
    () async {
      SharedPreferences.setMockInitialValues({});
      const store = WindowsPlaybackProgressStore();
      for (final cid in [101, 102]) {
        await store.save(
          WindowsPlaybackProgressSnapshot(
            bvid: 'cheese:ss968174948',
            cid: cid,
            pageNumber: cid - 100,
            position: const Duration(seconds: 47),
            duration: const Duration(minutes: 10),
          ),
        );
      }
      final package = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.history},
      );
      final values =
          _document(
                ZipDecoder().decodeBytes(package.bytes),
                'history.json',
              )['values']
              as Map;
      expect(
        values.keys,
        containsAll([
          'windows_playback_state_CHEESE:SS968174948',
          'windows_playback_state_CHEESE:SS968174948_cid_101',
          'windows_playback_state_CHEESE:SS968174948_cid_102',
        ]),
      );
      expect(
        jsonDecode(
          values['windows_playback_state_CHEESE:SS968174948_cid_102'],
        )['positionMs'],
        47000,
      );
    },
  );

  test('valid duplicate note identities block partial backup', () async {
    SharedPreferences.setMockInitialValues({});
    final note = VideoNote(
      id: 'duplicate',
      bvid: 'BV1GJ411x7h7',
      videoTitle: 'Fixture',
      ownerName: 'Fixture',
      partCid: 100,
      partPageNumber: 1,
      partTitle: 'A',
      title: 'Fixture',
      body: '',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      position: Duration.zero,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      VideoNoteService.storageKey,
      jsonEncode([note.toJson(), note.toJson()]),
    );
    await expectLater(
      UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.notes},
      ),
      throwsFormatException,
    );
  });

  test(
    'malformed note frames cannot disappear in a successful backup',
    () async {
      SharedPreferences.setMockInitialValues({});
      final note = VideoNote(
        id: 'frames',
        bvid: 'BV1GJ411x7h7',
        videoTitle: 'Fixture',
        ownerName: 'Fixture',
        partCid: 100,
        partPageNumber: 1,
        partTitle: 'A',
        title: 'Fixture',
        body: 'Keep this text',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        position: Duration.zero,
      ).toJson();
      final prefs = await SharedPreferences.getInstance();
      final malformed = <Map<String, Object?>>[
        {'frames': 'unsupported-list'},
        {
          'frames': [null],
        },
        {
          'frames': [
            {'path': '', 'positionMs': 100},
          ],
        },
        {
          'frames': [
            {'path': 'fixture.png', 'positionMs': -1},
          ],
        },
        {
          'frames': [
            {'path': 'fixture.png', 'positionMs': 1.5},
          ],
        },
        {
          'frames': [
            {'path': 'fixture.png', 'positionMs': 604800001},
          ],
        },
        {'framePath': 42},
        {'positionMs': -1},
        {'partCid': 123.5},
        {'partPageNumber': 2.9},
        {'videoCoverUrl': 42},
        {
          'futureAttachments': ['unsupported'],
        },
        {
          'frames': [
            {'path': 'fixture.png', 'positionMs': 0, 'futureType': 'unknown'},
          ],
        },
      ];
      for (final invalid in malformed) {
        final raw = jsonEncode([
          {...note, ...invalid},
        ]);
        await prefs.setString(VideoNoteService.storageKey, raw);
        await expectLater(
          UnifiedExportService().buildPackage(
            sections: {UnifiedExportSection.notes},
          ),
          throwsFormatException,
          reason: invalid.keys.join(','),
        );
        expect(prefs.getString(VideoNoteService.storageKey), raw);
      }
    },
  );

  test(
    'raw local sections preserve damaged storage instead of normalizing it',
    () async {
      final records = <String, Object>{
        'focubili_learning_list_v2': '{damaged-learning-document',
        'focubili_focus_history': '[damaged-focus-document',
        'focubili_watch_history': '{unknown-future-history-document',
      };
      SharedPreferences.setMockInitialValues(records);
      final package = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.learning, UnifiedExportSection.history},
      );
      final archive = ZipDecoder().decodeBytes(package.bytes);
      final learning = _document(archive, 'learning.json')['values'] as Map;
      final history = _document(archive, 'history.json')['values'] as Map;
      expect(
        learning['focubili_learning_list_v2'],
        records['focubili_learning_list_v2'],
      );
      expect(
        learning['focubili_focus_history'],
        records['focubili_focus_history'],
      );
      expect(
        history['focubili_watch_history'],
        records['focubili_watch_history'],
      );
    },
  );

  test(
    'subscription export rejects duplicate rows even after browsing dedupes them',
    () async {
      for (final kind in ['sources', 'feed', 'pending', 'paused']) {
        final document =
            jsonDecode(feedFixture(count: 1, sourceCount: 1)) as Map;
        document['version'] = 2;
        if (kind == 'pending') {
          document['checkpoints']['creator:1']['pending'] = [
            document['feed'].first,
            document['feed'].first,
          ];
        } else if (kind == 'paused') {
          document['sources'].first['paused'] = 'invalid-boolean';
        } else {
          (document[kind] as List).add((document[kind] as List).first);
        }
        SharedPreferences.setMockInitialValues({
          SubscriptionService.storageKey: jsonEncode(document),
        });
        final service = SubscriptionService(
          preferencesLoader: SharedPreferences.getInstance,
        );
        try {
          await service.initialize();
          await expectLater(
            service.exportLocalData(),
            throwsA(isA<SubscriptionStorageException>()),
            reason: kind,
          );
        } finally {
          service.dispose();
        }
      }
    },
  );

  for (final duplicate in [false, true]) {
    test(
      'cold subscription export ${duplicate ? 'rejects duplicate raw rows' : 'reads valid legacy data'} without migration or cleanup writes',
      () async {
        final document =
            jsonDecode(feedFixture(count: 1, sourceCount: 1)) as Map;
        // An expired read row also exercises v1.8's initialization cleanup after
        // integration. Export must validate the original bytes before any such
        // browsing-side normalization, including SQLite's first migration.
        document['feed'].first['readAt'] = DateTime.utc(2020).toIso8601String();
        if (duplicate) {
          (document['feed'] as List).add(
            Map<String, dynamic>.from(document['feed'].first as Map),
          );
        }
        final raw = jsonEncode(document);
        SharedPreferences.setMockInitialValues({
          SubscriptionService.storageKey: raw,
        });
        final snapshots = CountingSnapshots();
        final service = SubscriptionService(
          preferencesLoader: SharedPreferences.getInstance,
          snapshotStore: snapshots,
          clock: () => DateTime.utc(2026, 10, 18),
        );
        addTearDown(service.dispose);
        if (duplicate) {
          await expectLater(
            service.exportLocalData(),
            throwsA(isA<SubscriptionStorageException>()),
          );
        } else {
          final exported = await service.exportLocalData();
          expect(exported['feed'], hasLength(1));
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(SubscriptionService.storageKey), raw);
        expect(prefs.getKeys(), {SubscriptionService.storageKey});
        expect(snapshots.value, isNull);
        expect(snapshots.transactions, 0);
        expect(snapshots.saves, 0);
      },
    );
  }

  test(
    'subscription export verifies committed history IDs and retains rewound or orphan histories',
    () async {
      final seed = jsonDecode(feedFixture(count: 3, sourceCount: 1)) as Map;
      final entries = [
        for (final row in seed['feed'] as List)
          SubscriptionFeedItem.fromJson(Map<String, dynamic>.from(row)),
      ];
      for (final mode in ['missing', 'rewound', 'orphan']) {
        final document =
            jsonDecode(
                  feedFixture(count: 0, sourceCount: mode == 'orphan' ? 0 : 1),
                )
                as Map;
        document['version'] = 2;
        final key = mode == 'orphan' ? 'creator:99' : 'creator:1';
        final job = SubscriptionHistoryJob(
          id: 'fixture-history',
          sourceKey: key,
          sourceToken: 'synthetic-lifecycle',
          batches: 1,
          ids: {entries[0].bvid, entries[1].bvid},
        );
        document['historyJobs'] = {key: job.toJson()};
        SharedPreferences.setMockInitialValues({
          SubscriptionService.storageKey: jsonEncode(document),
        });
        final history = MemorySubscriptionHistoryStore();
        await history.write(
          job.id,
          0,
          SubscriptionHistoryBatch(
            page: 1,
            items: [entries[0]],
            hasMore: true,
            signature: 'fixture',
          ),
        );
        if (mode != 'missing') {
          await history.write(
            job.id,
            1,
            SubscriptionHistoryBatch(
              page: 2,
              items: [entries[1], entries[2]],
              hasMore: false,
              signature: 'reused',
            ),
          );
        }
        final service = SubscriptionService(
          preferencesLoader: SharedPreferences.getInstance,
          historyStore: history,
        );
        try {
          if (mode == 'missing') {
            await expectLater(
              service.exportLocalData(),
              throwsA(isA<SubscriptionStorageException>()),
            );
          } else {
            final exported = await service.exportLocalData();
            final rows = (exported['history'] as Map)[key] as List;
            expect(rows.map((row) => row['bvid']), [
              entries[0].bvid,
              entries[1].bvid,
            ]);
            expect(
              jsonEncode(exported),
              isNot(contains('synthetic-lifecycle')),
            );
          }
        } finally {
          service.dispose();
        }
      }
    },
  );

  test(
    'diagnostic corruption blocks unified export instead of reporting no records',
    () async {
      final valid = {
        'occurredAt': DateTime.utc(2026).toIso8601String(),
        'category': 'fixture',
        'operation': 'fixture',
        'description': 'safe fixture',
      };
      for (final raw in [
        '{invalid',
        '{}',
        jsonEncode([valid, 42]),
        jsonEncode([
          {...valid, 'additionalInfo': 42},
        ]),
        jsonEncode([
          {...valid, 'hasErrorCode': true, 'errorCode': 'broken'},
        ]),
        jsonEncode([
          {
            ...valid,
            'additionalInfo': {'state': 42},
          },
        ]),
        jsonEncode([
          {...valid, 'futureField': 'unknown'},
        ]),
      ]) {
        SharedPreferences.setMockInitialValues({
          'focubili_problem_diagnostics_v1': raw,
        });
        await expectLater(
          UnifiedExportService().buildPackage(
            sections: {UnifiedExportSection.diagnostics},
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('diagnostic read failure is strict only for export', () async {
    final prefs = _UnreadableDiagnostics();
    expect(
      await ProblemDiagnosticsService(
        preferencesLoader: () async => prefs,
      ).loadRecentErrors(),
      isEmpty,
    );
    await expectLater(
      UnifiedExportService(
        preferencesLoader: () async => prefs,
      ).buildPackage(sections: {UnifiedExportSection.diagnostics}),
      throwsFormatException,
    );
  });

  test(
    'raw history file corruption cannot be normalized during export',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focubili-export-history-',
      );
      addTearDown(() => root.delete(recursive: true));
      final document = jsonDecode(feedFixture(count: 1, sourceCount: 1)) as Map;
      document['version'] = 2;
      final item = Map<String, dynamic>.from(document['feed'].first);
      item['collectionAdded'] = 'malformed-boolean';
      final job = SubscriptionHistoryJob(
        id: 'fixture-history',
        sourceKey: 'creator:1',
        sourceToken: 'synthetic',
        batches: 1,
        ids: {item['bvid'] as String},
      );
      document['historyJobs'] = {'creator:1': job.toJson()};
      final folder = await Directory(
        '${root.path}/subscription-history/${job.id}/0',
      ).create(recursive: true);
      await File('${folder.path}/page.json').writeAsString(
        jsonEncode({
          'page': 1,
          'items': [item],
          'hasMore': false,
          'signature': 'fixture',
          'total': 1,
        }),
      );
      final history = FileSubscriptionHistoryStore(directory: () async => root);
      expect(
        (await history.read(job.id, 0))!.items.single.collectionAdded,
        isFalse,
      );
      SharedPreferences.setMockInitialValues({
        SubscriptionService.storageKey: jsonEncode(document),
      });
      final service = SubscriptionService(
        preferencesLoader: SharedPreferences.getInstance,
        historyStore: history,
      );
      addTearDown(service.dispose);
      await expectLater(service.exportLocalData(), throwsFormatException);
    },
  );
}
