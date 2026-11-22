import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:focubili/services/unified_restore_preferences.dart';

const _learning = 'focubili_learning_list_v2';
const _legacy = 'focubili_learning_list_v1';
const _history = 'focubili_focus_history';
const _active = 'focubili_focus_active_session';
const _folders = 'app_favorites.folders_v1';
const _watch = 'focubili_watch_history';
const _search = 'focubili_search_history';
const _allParts = 'windows_playback_state_BV1GJ411X7H7';
const _part = '${_allParts}_cid_11';
const _bv = 'BV1GJ411x7h7';
const _other = 'BV1AC411x7h7';
const _third = 'BV1CC411x7h7';
const _now = '2026-10-18T02:03:04.000Z';

UnifiedRestorePreferencePlan _read(
  UnifiedExportSection section,
  Map<String, Object> values,
) => UnifiedRestorePreferences.inspect(section, {
  'format': 'focubili.local.${section.name}',
  'version': 1,
  'values': values,
});

Map<String, Object> _entry(
  String bvid,
  int cid, {
  String? folder,
  int position = 30,
  int order = 0,
}) => {
  'bvid': bvid,
  'title': 'Task',
  'ownerName': 'Author',
  'partCid': cid,
  'partPageNumber': 1,
  'partTitle': '',
  'positionMs': position,
  'durationMs': 1200,
  'status': 'learning',
  'addedAt': _now,
  'updatedAt': _now,
  'sortOrder': order,
  'folderId': ?folder,
};

String _learningDoc(List<Object> entries, List<Object> folders) =>
    jsonEncode({'schemaVersion': 3, 'entries': entries, 'folders': folders});

Map<String, Object> _folder(String id, String name) => {
  'id': id,
  'name': name,
  'createdAt': _now,
  'updatedAt': _now,
};

Map<String, Object> _favorite(
  String id,
  String bvid,
  int index, {
  String cover = '',
}) => {
  'folderId': id,
  'bvid': bvid,
  'title': 'Favorite',
  'addedAt': _now,
  'coverUrl': cover,
  'sortIndex': index,
};

Map<String, Object> _group(
  String id,
  int remote,
  List<int> members, {
  List<int> excluded = const [],
}) => {
  'id': id,
  'name': id,
  'remoteId': remote,
  'excluded': excluded,
  'members': [
    for (final mid in members) {'mid': mid, 'name': 'Creator $mid'},
  ],
};

String _groupDoc(List<Object> groups, List<int> deleted, {bool? sync}) =>
    jsonEncode({'groups': groups, 'deleted': deleted, 'autoSync': ?sync});

Map<String, Object> _homeChoice(String kind, String id) => {
  'kind': kind,
  'id': id,
  'label': id,
};

String _homeDoc(List<Object> items, {bool custom = true}) =>
    jsonEncode({'custom': custom, 'items': items});

Map<String, Object> _watched(String bvid, int ms) => {
  'bvid': bvid,
  'title': 'Video',
  'ownerName': 'Author',
  'lastPartTitle': 'Segment',
  'lastPartPageNumber': 1,
  'watchedAt': _now,
  'lastPositionMs': ms,
};

String _progress(int cid, int position) => jsonEncode({
  'cid': cid,
  'pageNumber': 1,
  'positionMs': position,
  'durationMs': 1000,
  'savedAtMs': 1000,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('consumes the original version-one exporter output', () async {
    const groups = 'following_groups.v1.89';
    const home = 'home_collection.v1.followings.89';
    final seed = {
      _learning: _learningDoc([_entry(_bv, 33)], []),
      _history: 'recoverable learning is independent of damaged focus data',
      _folders: jsonEncode([_folder('local_folder', 'Portable')]),
      'app_favorites.items_v1.local_folder': jsonEncode([
        _favorite('local_folder', _bv, 0),
      ]),
      groups: _groupDoc(
        [
          _group('remote_-10', -10, [54]),
        ],
        [],
        sync: true,
      ),
      home: _homeDoc([_homeChoice('group', 'remote_-10')]),
      _watch: jsonEncode([_watched(_bv, 44)]),
      _search: ['first item'],
      _allParts: _progress(11, 90),
      _part: _progress(11, 90),
    };
    SharedPreferences.setMockInitialValues(seed);
    final package = await UnifiedExportService().buildPackage(
      sections: UnifiedRestorePreferences.sections,
    );
    final zip = ZipDecoder().decodeBytes(package.bytes);
    final parsed = [
      for (final section in UnifiedRestorePreferences.sections)
        UnifiedRestorePreferences.inspect(
          section,
          jsonDecode(utf8.decode(zip.find('${section.name}.json')!.content))
              as Map<String, dynamic>,
        ),
    ];
    final result = UnifiedRestorePreferences.planWrites(parsed, {});
    expect(result.added, 11);
    expect(result.skipped, 0);
    expect(
      result.values.keys,
      unorderedEquals(seed.keys.where((key) => key != _history)),
    );
    expect(result.values[_search], ['first item']);
    expect(
      jsonDecode(result.values[groups]! as String),
      isNot(contains('autoSync')),
    );
    final reapplied = UnifiedRestorePreferences.planWrites(
      parsed,
      result.values,
    );
    expect(reapplied.added, 0);
    expect(reapplied.values, isEmpty);
  });
  test('imports v1 and v3 learning lists without moving local tasks', () {
    final backup = _read(UnifiedExportSection.learning, {
      _learning: _learningDoc(
        [
          _entry(_bv, 1, position: 10, folder: 'shared'),
          _entry(_other, 3, folder: 'new', order: 8),
          _entry(_other, 2, folder: 'shared', order: 7),
        ],
        [
          {'id': 'shared', 'name': 'source name'},
          {'id': 'new', 'name': 'Source folder'},
        ],
      ),
    });
    final result = UnifiedRestorePreferences.planWrites(
      [backup],
      {
        _learning: _learningDoc(
          [
            {
              ..._entry(_bv, 1, position: 55, folder: 'shared', order: 9),
              'knownToLocalVersionOnly': true,
            },
          ],
          [
            {'id': 'shared', 'name': 'local name'},
          ],
        ),
      },
    );
    final doc = jsonDecode(result.values[_learning]! as String) as Map;
    final entries = doc['entries'] as List;
    expect(backup.itemCount, 5);
    expect(result.added, 3);
    expect(result.skipped, 2);
    expect(entries.map((row) => row['partCid']), [1, 2, 3]);
    expect(entries.map((row) => row['sortOrder']), [9, 10, 11]);
    expect(entries.first['positionMs'], 55);
    expect(entries.first['knownToLocalVersionOnly'], isTrue);
    expect(doc['folders'].map((row) => row['name']), [
      'local name',
      'Source folder',
    ]);

    final v1 = _read(UnifiedExportSection.learning, {
      _legacy: jsonEncode([
        _entry(_bv, 1, order: 12),
        _entry(_bv, 2, order: 4),
      ]),
    });
    final fresh = UnifiedRestorePreferences.planWrites([v1], {});
    expect(fresh.values.containsKey(_legacy), isFalse);
    final restored = jsonDecode(fresh.values[_learning]! as String)['entries'];
    expect(restored.map((row) => row['partCid']), [2, 1]);
    expect(restored.map((row) => row['sortOrder']), [0, 1]);
  });

  test('never restores focus state or its source-machine paths', () {
    final plan = _read(UnifiedExportSection.learning, {
      _active: '{"sourceFramePath":"/local/private.png"}',
      _history: '[{"sourceFramePath":"/local/private.png"}]',
    });
    final result = UnifiedRestorePreferences.planWrites(
      [plan],
      {_active: 'current active timer', _history: 'current history'},
    );
    expect(plan.itemCount, 0);
    expect(plan.warnings, hasLength(2));
    expect(result.values, isEmpty);
  });

  test(
    'favorites and homepage preserve local folder identity and item order',
    () {
      final favorites = _read(UnifiedExportSection.favorites, {
        _folders: jsonEncode([
          _folder('folder1', 'backup'),
          _folder('empty', 'Empty'),
        ]),
        'app_favorites.items_v1.folder1': jsonEncode([
          _favorite('folder1', _bv, 0),
          _favorite('folder1', _other, 3, cover: 'https://example.com/beacon'),
          _favorite('folder1', _third, 2, cover: '//i0.hdslb.com/source.jpg'),
        ]),
      });
      final homes = _read(UnifiedExportSection.followingGroups, {
        'home_collection.v1.favorites.0': _homeDoc([
          _homeChoice('local', 'folder1'),
          _homeChoice('local', 'empty'),
          _homeChoice('local', 'missing'),
        ]),
      });
      final result = UnifiedRestorePreferences.planWrites(
        [homes, favorites],
        {
          _folders: jsonEncode([_folder('folder1', 'local')]),
          'app_favorites.items_v1.folder1': jsonEncode([
            _favorite('folder1', _bv, 12),
          ]),
        },
      );
      final folderRows = jsonDecode(result.values[_folders]! as String) as List;
      final items =
          jsonDecode(result.values['app_favorites.items_v1.folder1']! as String)
              as List;
      final home = jsonDecode(
        result.values['home_collection.v1.favorites.0']! as String,
      );
      expect(folderRows.map((row) => row['name']), ['local', 'Empty']);
      expect(items.map((row) => row['bvid']), [_bv, _third, _other]);
      expect(items.map((row) => row['sortIndex']), [12, 13, 14]);
      expect(items[1]['coverUrl'], 'https://i0.hdslb.com/source.jpg');
      expect(items[2]['coverUrl'], isNull);
      expect(home['items'].map((row) => row['id']), ['folder1', 'empty']);
      expect(result.added, 6);
      expect(result.skipped, 3);
      expect(UnifiedRestorePreferences.planWrites([homes], {}).skipped, 3);
    },
  );

  test('old orphan favorite keys do not resurrect a deleted source folder', () {
    const orphanItems = 'app_favorites.items_v1.deleted';
    const keptItems = 'app_favorites.items_v1.kept';
    final favorites = _read(UnifiedExportSection.favorites, {
      orphanItems: jsonEncode([_favorite('deleted', _bv, 0)]),
      keptItems: jsonEncode([_favorite('kept', _other, 0)]),
      _folders: jsonEncode([_folder('kept', 'Kept')]),
    });
    final result = UnifiedRestorePreferences.planWrites(
      [favorites],
      {
        _folders: jsonEncode([_folder('deleted', 'Unrelated local folder')]),
      },
    );
    expect(favorites.itemCount, 2);
    expect(result.added, 2);
    expect(result.values.keys, unorderedEquals([_folders, keptItems]));
    expect(result.warnings.single, contains('找不到所属文件夹'));

    final whollyOrphan = _read(UnifiedExportSection.favorites, {
      orphanItems: 'interrupted favorite write',
    });
    final empty = UnifiedRestorePreferences.planWrites([whollyOrphan], {});
    expect(empty.values, isEmpty);
    expect(empty.warnings.single, contains('找不到所属文件夹'));
  });

  test(
    'following groups stay scoped, preserving deletions and sync settings',
    () {
      const key = 'following_groups.v1.11';
      const home = 'home_collection.v1.followings.11';
      const otherHome = 'home_collection.v1.followings.12';
      final backup = _read(UnifiedExportSection.followingGroups, {
        key: _groupDoc(
          [
            _group('source', 5, [21, 22, 23]),
            _group('deleted', -10, [22]),
            _group('fresh', 6, [21]),
          ],
          [7],
          sync: true,
        ),
        home: _homeDoc([
          _homeChoice('group', 'source'),
          _homeChoice('group', 'deleted'),
          _homeChoice('group', 'fresh'),
        ]),
        otherHome: _homeDoc([_homeChoice('group', 'fresh')]),
      });
      final result = UnifiedRestorePreferences.planWrites(
        [backup],
        {
          key: _groupDoc(
            [
              _group('existing', 5, [21], excluded: [22]),
            ],
            [-10],
            sync: false,
          ),
          home: _homeDoc([_homeChoice('creator', '21')], custom: false),
        },
      );
      final groupDoc = jsonDecode(result.values[key]! as String);
      final groups = groupDoc['groups'] as List;
      final localHome = jsonDecode(result.values[home]! as String);
      final otherAccount = jsonDecode(result.values[otherHome]! as String);
      expect(groups.map((row) => row['id']), ['existing', 'fresh']);
      expect(groups.first['members'].map((row) => row['mid']), [21, 23]);
      expect(groupDoc['deleted'], [-10, 7]);
      expect(groupDoc['autoSync'], isFalse);
      expect(localHome['custom'], isFalse);
      expect(localHome['items'].map((row) => row['id']), [
        '21',
        'existing',
        'fresh',
      ]);
      expect(otherAccount['items'], isEmpty);
      expect(result.warnings, contains('关注分组自动同步开关不恢复；本机设置不变。'));
      final fresh = UnifiedRestorePreferences.planWrites([backup], {});
      expect(
        jsonDecode(fresh.values[key]! as String),
        isNot(contains('autoSync')),
      );
    },
  );

  test('keeps local history and protects the Windows implicit part record', () {
    final backup = _read(UnifiedExportSection.history, {
      _watch: jsonEncode([_watched(_bv, 10), _watched(_other, 14)]),
      _search: ['current', 'new', 'over capacity'],
      'windows_playback_state_BV1GJ411x7h7': _progress(11, 15),
      'windows_playback_state_BV1GJ411x7h7_cid_11': _progress(11, 15),
      '${_allParts}_cid_12': _progress(12, 20),
    });
    final localSearch = ['current', for (var i = 0; i < 10; i++) 'local-$i'];
    final result = UnifiedRestorePreferences.planWrites(
      [backup],
      {
        _watch: jsonEncode([_watched(_bv, 999)]),
        _search: localSearch,
        _allParts: _progress(11, 120),
      },
    );
    final watched = jsonDecode(result.values[_watch]! as String);
    expect(watched.map((row) => row['lastPositionMs']), [999, 14]);
    expect(result.values[_search], [...localSearch, 'new']);
    expect(result.values, isNot(contains(_allParts)));
    expect(result.values, isNot(contains(_part)));
    expect(result.values['${_allParts}_cid_12'], _progress(12, 20));
    expect(result.added, 3);
    expect(result.skipped, 5);
    expect(result.warnings.single, contains('搜索历史上限'));
  });

  test(
    'rejects unsupported data, cross-folder rows, and malformed progress',
    () {
      final cases = [
        () => _read(UnifiedExportSection.history, {'bilibili_cookie': 'fake'}),
        () => _read(UnifiedExportSection.history, {
          _search: ['ok', 123],
        }),
        () => _read(UnifiedExportSection.history, {_part: _progress(12, 30)}),
        () => _read(UnifiedExportSection.history, {
          _allParts: _progress(11, 20),
          'windows_playback_state_BV1GJ411x7h7': _progress(11, 20),
        }),
        () => _read(UnifiedExportSection.history, {
          _watch: jsonEncode([
            {..._watched(_bv, 10), 'cookie': 'fake'},
          ]),
        }),
        () => _read(UnifiedExportSection.favorites, {
          _folders: jsonEncode([_folder('folder1', 'Folder')]),
          'app_favorites.items_v1.folder1': jsonEncode([
            _favorite('folder2', _bv, 0),
          ]),
        }),
        () => _read(UnifiedExportSection.followingGroups, {
          'home_collection.v1.followings.0': _homeDoc([
            _homeChoice('creator', '19'),
          ]),
        }),
        () => _read(UnifiedExportSection.learning, {
          _learning: _learningDoc([_entry(_bv, 2, folder: 'missing')], []),
        }),
      ];
      for (final invalid in cases) {
        expect(invalid, throwsFormatException);
      }
    },
  );

  test(
    'corrupt local domain is skipped while a separate domain can restore',
    () {
      final learning = _read(UnifiedExportSection.learning, {
        _legacy: jsonEncode([_entry(_bv, 1)]),
      });
      final history = _read(UnifiedExportSection.history, {
        _search: ['restore me'],
      });
      final result = UnifiedRestorePreferences.planWrites(
        [learning, history],
        {_learning: '{"format":"future"}'},
      );
      expect(result.values, {
        _search: ['restore me'],
      });
      expect(result.added, 1);
      expect(result.skipped, 1);
      expect(result.warnings.single, contains('本机学习清单'));
    },
  );
}
