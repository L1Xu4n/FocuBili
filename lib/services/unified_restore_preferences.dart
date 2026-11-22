import 'dart:convert';

import '../models/learning_list_entry.dart';
import '../models/learning_subject_folder.dart';
import '../models/watch_history_entry.dart';
import 'bilibili_course_link.dart';
import 'learning_list_service.dart';
import 'unified_export_service.dart';
import 'watch_history_service.dart';

/// Fully validated, detached data from one preference-backed export section.
class UnifiedRestorePreferencePlan {
  UnifiedRestorePreferencePlan._(
    this.section,
    this._data,
    this.itemCount,
    Iterable<String> warnings,
  ) : warnings = List.unmodifiable(warnings);

  final UnifiedExportSection section;
  final Map<String, Object> _data;
  final int itemCount;
  final List<String> warnings;
}

/// Only application-owned, validated preference values, ready to commit.
class UnifiedRestorePreferenceWrites {
  UnifiedRestorePreferenceWrites._(
    Map<String, Object> values,
    this.added,
    this.skipped,
    Iterable<String> warnings,
  ) : values = Map.unmodifiable(values),
      warnings = List.unmodifiable(warnings);

  final Map<String, Object> values;
  final int added;
  final int skipped;
  final List<String> warnings;
}

/// Converts v1 export envelopes to typed local records without loading services,
/// resolving account identity, or changing anything before confirmation.
abstract final class UnifiedRestorePreferences {
  static const sections = {
    UnifiedExportSection.learning,
    UnifiedExportSection.favorites,
    UnifiedExportSection.followingGroups,
    UnifiedExportSection.history,
  };
  static const _learning = 'focubili_learning_list_v2';
  static const _legacyLearning = 'focubili_learning_list_v1';
  static const _focus = 'focubili_focus_history';
  static const _active = 'focubili_focus_active_session';
  static const _folders = 'app_favorites.folders_v1';
  static const _items = 'app_favorites.items_v1.';
  static const _groups = 'following_groups.v1.';
  static const _home = 'home_collection.v1.';
  static const _watch = 'focubili_watch_history';
  static const _search = 'focubili_search_history';
  static const _searchLimit = 12;
  static const _dayMs = 86400000;
  static const _progressLimit = 1 << 31;
  static const _progressPrefix = 'windows_playback_state_';
  static final _progressKey = RegExp(
    r'^windows_playback_state_(BV[0-9A-Za-z]{10}|CHEESE:SS[1-9][0-9]*)(?:_cid_([0-9]+))?$',
  );
  static final _bv = RegExp(r'^BV[0-9A-Za-z]{10}$');
  static final _id = RegExp(r'^[a-zA-Z0-9_-]+$');

  static UnifiedRestorePreferencePlan inspect(
    UnifiedExportSection section,
    Map<String, dynamic> document,
  ) {
    if (!sections.contains(section) ||
        document.keys.any(
          (key) => !const {'format', 'version', 'values'}.contains(key),
        ) ||
        document['format'] != 'focubili.local.${section.name}' ||
        document['version'] is! int ||
        document['version'] != 1) {
      throw FormatException('${section.label}：不支持的备份格式。');
    }
    try {
      final values = _map(document['values']);
      final data = <String, Object>{};
      final parser = _PreferenceParser(incoming: true);
      final warnings = <String>{};
      var count = 0;
      final favoriteIds = <Object?>{};
      if (section == UnifiedExportSection.favorites &&
          values.containsKey(_folders)) {
        final folders = parser.favoriteFolders(values[_folders]);
        data[_folders] = folders;
        favoriteIds.addAll(folders.map((folder) => folder['id']));
        count += folders.length;
      }
      for (final entry in values.entries) {
        final key = entry.key;
        if (!UnifiedExportService.includesKey(section, key)) _invalid();
        if (key == _active) {
          // v1 packages may contain a live timer. Its payload is never used.
          warnings.add('备份中的活动专注计时不恢复；本机活动计时不变。');
          continue;
        }
        final value = entry.value;
        if (key == _learning || key == _legacyLearning) {
          final parsed = parser.learning(value, legacy: key == _legacyLearning);
          data[key] = parsed;
          count += parsed.entries.length + parsed.folders.length;
        } else if (key == _focus) {
          // The running focus controller can persist an older in-memory
          // history on app exit; reporting raw preference writes as restored
          // would be misleading. Leave both live and historical data alone.
          if (value != '[]') {
            warnings.add('专注历史暂不支持恢复；本机专注历史不变。');
          }
        } else if (key == _folders) {
          continue;
        } else if (key.startsWith(_items)) {
          final folderId = key.substring(_items.length);
          // Older exports can capture an orphan after a partially completed
          // folder deletion. It is not part of a surviving source folder.
          if (!favoriteIds.contains(folderId)) {
            warnings.add('备份中找不到所属文件夹的收藏记录未恢复。');
            continue;
          }
          final parsed = parser.favoriteItems(value, folderId);
          data[key] = parsed;
          count += parsed.length;
        } else if (key.startsWith(_groups)) {
          _requireUid(key.substring(_groups.length));
          final parsed = parser.groups(value);
          data[key] = parsed;
          count += parsed.count;
        } else if (key.startsWith(_home)) {
          final scope = _homeScope(key);
          final parsed = parser.home(value, scope);
          data[key] = parsed;
          count += 1 + parsed.items.length;
        } else if (key == _watch) {
          final parsed = parser.watch(value);
          data[key] = parsed;
          count += parsed.length;
        } else if (key == _search) {
          final parsed = parser.search(value);
          data[key] = parsed;
          count += parsed.length;
        } else if (key.startsWith(_progressPrefix)) {
          final canonical = _canonicalProgressKey(key);
          if (data.containsKey(canonical)) _invalid();
          data[canonical] = parser.progress(value, canonical);
          count++;
        } else {
          _invalid();
        }
      }
      return UnifiedRestorePreferencePlan._(
        section,
        Map.unmodifiable(data),
        count,
        {...warnings, ...parser.warnings},
      );
    } on FormatException {
      throw FormatException('${section.label}：备份包含未知字段或无效记录。');
    }
  }

  /// Local values win on conflicts; existing data never gets evicted to make
  /// room. Plan all selected sections together to keep references resolvable.
  static UnifiedRestorePreferenceWrites planWrites(
    Iterable<UnifiedRestorePreferencePlan> plans,
    Map<String, Object?> local,
  ) {
    final merge = _PreferenceMerge(local);
    final data = <String, Object>{};
    final seen = <UnifiedExportSection>{};
    for (final plan in plans) {
      if (!seen.add(plan.section)) _invalid();
      data.addAll(plan._data);
      merge.warnings.addAll(plan.warnings);
    }
    if (data.containsKey(_learning) || data.containsKey(_legacyLearning)) {
      final current = data[_learning] as _LearningData?;
      final legacy = data[_legacyLearning] as _LearningData?;
      if (current != null && legacy != null) {
        merge.skip(
          legacy.entries.length + legacy.folders.length,
          '备份同时包含新旧学习清单，旧版副本未重复导入。',
        );
      }
      merge.learning(current ?? legacy!);
    }
    if (data[_folders] case final List<_Row> rows) merge.favorites(rows, data);
    for (final entry in data.entries) {
      if (entry.key.startsWith(_groups)) {
        merge.groups(entry.key, entry.value as _GroupData);
      }
    }
    for (final entry in data.entries) {
      if (entry.key.startsWith(_home)) {
        merge.home(entry.key, entry.value as _HomeData);
      }
    }
    if (data[_watch] case final List<_Row> rows) merge.watch(rows);
    if (data[_search] case final List<String> rows) merge.search(rows);
    merge.progress({
      for (final entry in data.entries)
        if (entry.key.startsWith(_progressPrefix))
          entry.key: entry.value as _Row,
    });
    return UnifiedRestorePreferenceWrites._(
      merge.writes,
      merge.added,
      merge.skipped,
      merge.warnings,
    );
  }

  static String _canonicalProgressKey(String key) {
    final match = _progressKey.firstMatch(key);
    if (match == null) _invalid();
    final id = match.group(1)!.toUpperCase();
    if (id.startsWith('CHEESE:') &&
        !BilibiliCourseLink.isStorageKey(id.toLowerCase())) {
      _invalid();
    }
    final cid = match.group(2);
    if (cid == null) return '$_progressPrefix$id';
    final parsed = _requireUid(cid);
    return '$_progressPrefix${id}_cid_$parsed';
  }

  static ({bool favorites, int mid}) _homeScope(String key) {
    final suffix = key.substring(_home.length).split('.');
    if (suffix.length != 2 ||
        (suffix.first != 'favorites' && suffix.first != 'followings')) {
      _invalid();
    }
    final mid = suffix.last == '0' ? 0 : _requireUid(suffix.last);
    return (favorites: suffix.first == 'favorites', mid: mid);
  }
}

typedef _Row = Map<String, dynamic>;

Never _invalid() => throw const FormatException('Invalid local backup record');

_Row _map(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

List<dynamic> _list(Object? value) {
  if (value is! List) _invalid();
  return value;
}

Object? _decode(Object? value) {
  if (value is! String) _invalid();
  return jsonDecode(value);
}

int _int(Object? value, {int min = 0, int? max}) {
  if (value is! int || value < min || (max != null && value > max)) _invalid();
  return value;
}

String _text(Object? value, {bool nonEmpty = false}) {
  if (value is! String || (nonEmpty && value.trim().isEmpty)) _invalid();
  return value;
}

String _stableId(Object? value) {
  final id = _text(value, nonEmpty: true);
  if (!UnifiedRestorePreferences._id.hasMatch(id)) _invalid();
  return id;
}

int _requireUid(String value) {
  final id = int.tryParse(value);
  if (id == null || id <= 0 || id.toString() != value) _invalid();
  return id;
}

bool _videoId(Object? value) =>
    value is String &&
    (UnifiedRestorePreferences._bv.hasMatch(value) ||
        BilibiliCourseLink.isStorageKey(value));

DateTime _date(Object? value) {
  final parsed = DateTime.tryParse(_text(value));
  if (parsed == null) _invalid();
  return parsed;
}

void _unique<T>(Iterable<T> ids) {
  final seen = <T>{};
  if (ids.any((id) => !seen.add(id))) _invalid();
}

class _LearningData {
  const _LearningData(this.entries, this.folders);
  final List<_Row> entries;
  final List<_Row> folders;
}

class _GroupData {
  const _GroupData(this.groups, this.deleted, {this.autoSync});
  final List<_Row> groups;
  final List<int> deleted;
  final bool? autoSync;
  int get count =>
      deleted.length +
      groups.fold<int>(
        0,
        (sum, group) => sum + 1 + (group['members'] as List).length,
      );
}

class _HomeData {
  const _HomeData(this.custom, this.items);
  final bool custom;
  final List<_Row> items;
}

class _PreferenceParser {
  _PreferenceParser({required this.incoming});
  final bool incoming;
  final warnings = <String>{};

  void _fields(_Row row, Set<String> allowed, {bool root = false}) {
    if ((incoming || root) && row.keys.any((key) => !allowed.contains(key))) {
      _invalid();
    }
  }

  // Untrusted backups must not turn a preview/restore into requests to
  // arbitrary hosts, or install local paths, signed URLs or URL credentials.
  void _image(_Row row, String key) {
    if (row[key] == null) return;
    final value = _text(row[key]);
    if (!incoming || value.isEmpty) return;
    final candidate = value.trim();
    final uri = Uri.tryParse(
      candidate.startsWith('//') ? 'https:$candidate' : candidate,
    );
    const publicHosts = {'hdslb.com', 'biliimg.com'};
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !publicHosts.any(
          (suffix) => uri.host == suffix || uri.host.endsWith('.$suffix'),
        ) ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      row.remove(key);
      warnings.add('非公开缩略图或头像地址已略过，不影响关联记录。');
      return;
    }
    row[key] = uri.toString();
  }

  _LearningData learning(Object? value, {bool legacy = false}) {
    final decoded = _decode(value);
    final List<dynamic> rows;
    final List<_Row> folders;
    if (decoded is List) {
      rows = decoded;
      folders = [];
    } else {
      final root = _map(decoded);
      _fields(root, {'schemaVersion', 'entries', 'folders'}, root: true);
      if (_int(root['schemaVersion']) != 3) _invalid();
      rows = _list(root['entries']);
      folders = _list(root['folders']).map((raw) {
        final row = _map(raw);
        _fields(row, {'id', 'name', 'iconId', 'colorId'});
        _stableId(row['id']);
        if (row['iconId'] != null) _text(row['iconId'], nonEmpty: true);
        if (row['colorId'] != null) _text(row['colorId'], nonEmpty: true);
        if (LearningSubjectFolder.tryParse(row) == null) _invalid();
        return row;
      }).toList();
    }
    _unique(folders.map((row) => row['id']));
    final ids = {for (final folder in folders) folder['id']};
    final entries = <_Row>[];
    for (final raw in rows) {
      final row = _map(raw);
      _fields(row, {
        'bvid',
        'title',
        'ownerName',
        'thumbnailUrl',
        'partCid',
        'partPageNumber',
        'partTitle',
        'positionMs',
        'durationMs',
        'status',
        'addedAt',
        'updatedAt',
        'sortOrder',
        'folderId',
      });
      if (!_videoId(row['bvid'])) _invalid();
      _int(row['partCid'], min: 1);
      _int(row['partPageNumber'], min: 1);
      final duration = _int(
        row['durationMs'],
        max: UnifiedRestorePreferences._dayMs,
      );
      _int(
        row['positionMs'],
        max: duration > 0 ? duration : UnifiedRestorePreferences._dayMs,
      );
      if (row.containsKey('sortOrder')) {
        _int(row['sortOrder'], max: UnifiedRestorePreferences._progressLimit);
      }
      if (row['status'] != null &&
          !LearningListStatus.values.any(
            (status) => status.name == row['status'],
          )) {
        _invalid();
      }
      if (row['folderId'] != null &&
          !ids.contains(_stableId(row['folderId']))) {
        _invalid();
      }
      _image(row, 'thumbnailUrl');
      if (LearningListEntry.tryParse(row) == null) _invalid();
      entries.add(row);
    }
    _unique(entries.map(_learningId));
    if (legacy) {
      // The application rebuilds v1 ranks from its old display order.
      entries.sort(_compareLearning);
      for (var i = 0; i < entries.length; i++) {
        entries[i]['sortOrder'] = i;
      }
    }
    return _LearningData(entries, folders);
  }

  List<_Row> favoriteFolders(Object? value) {
    final rows = _list(_decode(value)).map((raw) {
      final row = _map(raw);
      _fields(row, {'id', 'name', 'createdAt', 'updatedAt'});
      _stableId(row['id']);
      _text(row['name'], nonEmpty: true);
      _date(row['createdAt']);
      _date(row['updatedAt']);
      return row;
    }).toList();
    _unique(rows.map((row) => row['id']));
    return rows;
  }

  List<_Row> favoriteItems(Object? value, String folderId) {
    final rows = _list(_decode(value)).map((raw) {
      final row = _map(raw);
      _fields(row, {
        'folderId',
        'bvid',
        'title',
        'coverUrl',
        'ownerName',
        'durationText',
        'addedAt',
        'partCount',
        'sortIndex',
      });
      if (row['folderId'] != folderId || !_videoId(row['bvid'])) _invalid();
      _text(row['title']);
      _date(row['addedAt']);
      for (final key in ['ownerName', 'durationText']) {
        if (row[key] != null) _text(row[key]);
      }
      _image(row, 'coverUrl');
      if (row['partCount'] != null) _int(row['partCount'], min: 1);
      if (row['sortIndex'] != null) {
        _int(row['sortIndex'], max: UnifiedRestorePreferences._progressLimit);
      }
      return row;
    }).toList();
    _unique(rows.map((row) => row['bvid']));
    return rows;
  }

  _GroupData groups(Object? value) {
    final root = _map(_decode(value));
    _fields(root, {'groups', 'deleted', 'autoSync'}, root: true);
    final sync = root['autoSync'];
    if (root.containsKey('autoSync') && sync is! bool) _invalid();
    if (incoming && sync == true) {
      warnings.add('关注分组自动同步开关不恢复；本机设置不变。');
    }
    final rows = _list(root['groups']).map((raw) {
      final row = _map(raw);
      _fields(row, {'id', 'name', 'remoteId', 'excluded', 'members'});
      _stableId(row['id']);
      _text(row['name'], nonEmpty: true);
      if (row['remoteId'] != null) _remoteGroupId(row['remoteId']);
      if (row['excluded'] != null) {
        _unique(_list(row['excluded']).map((id) => _int(id, min: 1)));
      }
      final members = _list(row['members']).map((raw) {
        final member = _map(raw);
        _fields(member, {'mid', 'name', 'avatar', 'sign', 'official'});
        _int(member['mid'], min: 1);
        _text(member['name']);
        for (final key in ['sign', 'official']) {
          if (member[key] != null) _text(member[key]);
        }
        _image(member, 'avatar');
        return member;
      }).toList();
      _unique(members.map((member) => member['mid']));
      return row;
    }).toList();
    _unique(rows.map((row) => row['id']));
    _unique(rows.map((row) => row['remoteId']).whereType<int>());
    final deleted = _list(root['deleted']).map(_remoteGroupId).toList();
    _unique(deleted);
    return _GroupData(rows, deleted, autoSync: incoming ? null : sync as bool?);
  }

  int _remoteGroupId(Object? value) =>
      value == -10 && value is int ? value : _int(value, min: 1);

  _HomeData home(Object? value, ({bool favorites, int mid}) scope) {
    final root = _map(_decode(value));
    _fields(root, {'custom', 'items'}, root: true);
    final custom = root['custom'];
    if (custom is! bool) _invalid();
    final rows = _list(root['items']).map((raw) {
      final row = _map(raw);
      _fields(row, {'kind', 'id', 'label', 'avatar'});
      final kind = row['kind'];
      final id = _text(row['id'], nonEmpty: true);
      _text(row['label']);
      if (scope.favorites) {
        if (kind == 'local') {
          _stableId(id);
        } else if (kind == 'remote' && scope.mid > 0) {
          _requireUid(id);
        } else {
          _invalid();
        }
      } else if (kind == 'group' && scope.mid > 0) {
        _stableId(id);
      } else if (kind == 'creator' && scope.mid > 0) {
        _requireUid(id);
      } else {
        _invalid();
      }
      if (kind != 'creator' && row['avatar'] != null) _invalid();
      _image(row, 'avatar');
      return row;
    }).toList();
    _unique(rows.map(_homeId));
    return _HomeData(custom, rows);
  }

  List<_Row> watch(Object? value) {
    final rows = _list(_decode(value)).map((raw) {
      final row = _map(raw);
      _fields(row, {
        'bvid',
        'title',
        'ownerName',
        'lastPartTitle',
        'lastPartPageNumber',
        'watchedAt',
        'thumbnailUrl',
        'lastPositionMs',
      });
      if (!_videoId(row['bvid'])) _invalid();
      if (row.containsKey('lastPositionMs')) {
        _int(row['lastPositionMs'], max: UnifiedRestorePreferences._dayMs);
      }
      _image(row, 'thumbnailUrl');
      if (WatchHistoryEntry.tryParse(row) == null) _invalid();
      return row;
    }).toList();
    _unique(rows.map((row) => row['bvid']));
    return rows;
  }

  List<String> search(Object? value) {
    final rows = _list(
      value,
    ).map((value) => _text(value, nonEmpty: true)).toList();
    _unique(rows.map((value) => value.trim()));
    return rows;
  }

  _Row progress(Object? value, String key) {
    final row = _map(_decode(value));
    _fields(row, {
      'savedAtMs',
      'cid',
      'pageNumber',
      'positionMs',
      'durationMs',
    });
    final cid = _int(row['cid'], min: 1);
    _int(row['pageNumber'], min: 1);
    final position = _int(
      row['positionMs'],
      max: UnifiedRestorePreferences._progressLimit,
    );
    if (row.containsKey('durationMs')) {
      final duration = _int(
        row['durationMs'],
        max: UnifiedRestorePreferences._progressLimit,
      );
      if (duration > 0 && position > duration) _invalid();
    }
    if (row.containsKey('savedAtMs')) {
      _int(row['savedAtMs'], max: 8640000000000000);
    }
    final cidIndex = key.lastIndexOf('_cid_');
    if (cidIndex >= 0 && cid.toString() != key.substring(cidIndex + 5)) {
      _invalid();
    }
    return row;
  }
}

String _learningId(_Row row) => '${row['bvid']}:${row['partCid']}';
String _homeId(_Row row) => '${row['kind']}:${row['id']}';

int _compareLearning(_Row a, _Row b) {
  final status = (a['status'] == 'completed' ? 1 : 0).compareTo(
    b['status'] == 'completed' ? 1 : 0,
  );
  if (status != 0) return status;
  final rank = (a['sortOrder'] as int? ?? 0).compareTo(
    b['sortOrder'] as int? ?? 0,
  );
  if (rank != 0) return rank;
  final time = _date(a['addedAt']).compareTo(_date(b['addedAt']));
  return time != 0 ? time : _learningId(a).compareTo(_learningId(b));
}

int _compareFavorite(_Row a, _Row b) {
  final left = a['sortIndex'] as int?;
  final right = b['sortIndex'] as int?;
  if (left != null && right != null && left != right) {
    return left.compareTo(right);
  }
  if (left == null && right != null) return -1;
  if (left != null && right == null) return 1;
  return _date(b['addedAt']).compareTo(_date(a['addedAt']));
}

class _PreferenceMerge {
  _PreferenceMerge(this.local);
  final Map<String, Object?> local;
  final writes = <String, Object>{};
  final warnings = <String>{};
  final _parser = _PreferenceParser(incoming: false);
  final _groupAliases = <String, Map<String, String?>>{};
  var added = 0;
  var skipped = 0;

  Object? _current(String key) => writes[key] ?? local[key];

  void skip(int count, [String? reason]) {
    if (count == 0) return;
    skipped += count;
    if (reason != null) warnings.add(reason);
  }

  List<T> _mergeList<T>(
    List<T> current,
    Iterable<T> incoming,
    Object? Function(T) id, {
    int? limit,
    String? capacityWarning,
    T Function(T item)? prepare,
  }) {
    final result = <T>[...current];
    final ids = current.map(id).toSet();
    for (final item in incoming) {
      if (!ids.add(id(item))) {
        skip(1);
      } else if (limit != null && result.length >= limit) {
        skip(1, capacityWarning);
      } else {
        result.add(prepare == null ? item : prepare(item));
        added++;
      }
    }
    return result;
  }

  void learning(_LearningData incoming) {
    const key = UnifiedRestorePreferences._learning;
    const legacyKey = UnifiedRestorePreferences._legacyLearning;
    final count = incoming.entries.length + incoming.folders.length;
    if (count == 0) return;
    final raw = local[key] ?? local[legacyKey];
    final _LearningData current;
    try {
      current = raw == null
          ? const _LearningData([], [])
          : _parser.learning(raw, legacy: local[key] == null);
    } on FormatException {
      skip(count, '本机学习清单含无法识别的数据，未改动。');
      return;
    }

    final folders = _mergeList<_Row>(
      current.folders,
      incoming.folders,
      (row) => row['id'],
      limit: LearningListService.maximumFolders,
      capacityWarning: '已达到学科分组上限，未挤掉任何本机分组。',
    );
    final folderIds = {for (final folder in folders) folder['id']};
    final entries = [...current.entries];
    final entryIds = entries.map(_learningId).toSet();
    var nextRank = -1;
    for (final entry in entries) {
      final rank = entry['sortOrder'] as int? ?? 0;
      if (rank > nextRank) nextRank = rank;
    }
    final ordered = incoming.entries.toList()..sort(_compareLearning);
    for (final row in ordered) {
      if (!entryIds.add(_learningId(row))) {
        skip(1);
      } else if (row['folderId'] != null &&
          !folderIds.contains(row['folderId'])) {
        skip(1, '无法保留所属学科分组的任务未恢复。');
      } else if (entries.length >= LearningListService.maximumEntries ||
          nextRank >= UnifiedRestorePreferences._progressLimit) {
        skip(1, '学习清单容量或排序已达上限，未挤掉任何本机任务。');
      } else {
        entries.add(
          current.entries.isEmpty ? row : {...row, 'sortOrder': ++nextRank},
        );
        added++;
      }
    }
    if (folders.length != current.folders.length ||
        entries.length != current.entries.length) {
      writes[key] = jsonEncode({
        'schemaVersion': 3,
        'folders': folders,
        'entries': entries,
      });
    }
  }

  void favorites(List<_Row> incoming, Map<String, Object> data) {
    if (incoming.isEmpty) return;
    const key = UnifiedRestorePreferences._folders;
    const prefix = UnifiedRestorePreferences._items;
    final List<_Row> current;
    try {
      current = local[key] == null ? [] : _parser.favoriteFolders(local[key]);
    } on FormatException {
      skip(
        incoming.length +
            data.entries
                .where((entry) => entry.key.startsWith(prefix))
                .fold(0, (sum, entry) => sum + (entry.value as List).length),
        '本机收藏夹含无法识别的数据，未改动。',
      );
      return;
    }
    final ids = {for (final folder in current) folder['id']};
    final folders = [...current];
    for (final folder in incoming) {
      final id = folder['id'] as String;
      final itemKey = '$prefix$id';
      final items = data[itemKey] as List<_Row>? ?? [];
      final exists = ids.contains(id);
      // An orphan local key could be remnants of a deletion or interrupted
      // write, not records belonging to this source folder. Do not revive it.
      if (!exists && local[itemKey] != null) {
        skip(1 + items.length, '本机收藏夹存在缺失目录的旧记录，未覆盖。');
        continue;
      }
      final List<_Row> currentItems;
      try {
        currentItems = local[itemKey] == null
            ? []
            : _parser.favoriteItems(local[itemKey], id);
      } on FormatException {
        skip(1 + items.length, '部分本机收藏夹含无法识别的数据，未改动。');
        continue;
      }
      if (exists) {
        skip(1);
      } else {
        folders.add(folder);
        added++;
      }
      final ordered = items.toList()..sort(_compareFavorite);
      var nextIndex = -1;
      for (final item in currentItems) {
        final index = item['sortIndex'] as int? ?? -1;
        if (index > nextIndex) nextIndex = index;
      }
      final rows = _mergeList<_Row>(
        currentItems,
        ordered,
        (row) => row['bvid'],
        limit: currentItems.isEmpty
            ? null
            : currentItems.length +
                  UnifiedRestorePreferences._progressLimit -
                  nextIndex,
        capacityWarning: '部分收藏的排序已达上限，未覆盖本机顺序。',
        prepare: currentItems.isEmpty
            ? null
            : (row) => {...row, 'sortIndex': ++nextIndex},
      );
      if (rows.length != currentItems.length) {
        writes[itemKey] = jsonEncode(rows);
      }
    }
    // Commit the new folders only after the item writes are in the plan.
    if (folders.length != current.length) writes[key] = jsonEncode(folders);
  }

  void groups(String key, _GroupData incoming) {
    final _GroupData current;
    final aliases = _groupAliases[key] = {};
    try {
      current = local[key] == null
          ? const _GroupData([], [])
          : _parser.groups(local[key]);
    } on FormatException {
      for (final row in incoming.groups) {
        aliases[row['id'] as String] = null;
      }
      skip(incoming.count, '部分账号的本机关注分组含无法识别的数据，未改动。');
      return;
    }
    final groups = [...current.groups];
    final deleted = {...current.deleted};
    final byId = <String, int>{
      for (var i = 0; i < groups.length; i++) groups[i]['id'] as String: i,
    };
    final byRemoteId = <int, int>{
      for (var i = 0; i < groups.length; i++)
        if (groups[i]['remoteId'] is int) groups[i]['remoteId'] as int: i,
    };
    final alreadyAdded = added;
    for (final row in incoming.groups) {
      final id = row['id'] as String;
      final remoteId = row['remoteId'] as int?;
      final members = (row['members'] as List).cast<_Row>();
      final idIndex = byId[id];
      final remoteIndex = byRemoteId[remoteId];
      if (deleted.contains(remoteId) ||
          (idIndex != null && groups[idIndex]['remoteId'] != remoteId)) {
        aliases[id] = null;
        skip(1 + members.length, '已在本机删除或标识冲突的关注分组未恢复。');
        continue;
      }
      final index = idIndex ?? remoteIndex;
      if (index == null) {
        aliases[id] = id;
        byId[id] = groups.length;
        if (remoteId != null) byRemoteId[remoteId] = groups.length;
        groups.add(row);
        added += 1 + members.length;
        continue;
      }
      final existing = groups[index];
      aliases[id] = existing['id'] as String;
      skip(1);
      final exclusions = (existing['excluded'] as List?)?.toSet() ?? {};
      final permitted = members.where(
        (member) => !exclusions.contains(member['mid']),
      );
      skip(members.length - permitted.length, '本机已移除的关注分组成员未恢复。');
      final oldMembers = (existing['members'] as List).cast<_Row>();
      final merged = _mergeList(
        oldMembers,
        permitted,
        (member) => member['mid'],
      );
      if (merged.length != oldMembers.length) {
        groups[index] = {...existing, 'members': merged};
      }
    }
    for (final id in incoming.deleted) {
      // Do not apply an older deletion marker to a group that still exists.
      if (byRemoteId.containsKey(id) || !deleted.add(id)) {
        skip(1);
      } else {
        added++;
      }
    }
    if (added > alreadyAdded) {
      writes[key] = jsonEncode({
        'groups': groups,
        'deleted': deleted.toList(),
        if (current.autoSync != null) 'autoSync': current.autoSync,
      });
    }
  }

  void home(String key, _HomeData incoming) {
    final scope = UnifiedRestorePreferences._homeScope(key);
    final groups = '${UnifiedRestorePreferences._groups}${scope.mid}';
    final _HomeData? current;
    try {
      current = local[key] == null ? null : _parser.home(local[key], scope);
    } on FormatException {
      skip(1 + incoming.items.length, '部分本机首页配置含无法识别的数据，未改动。');
      return;
    }
    final aliases = _groupAliases[groups] ?? {};
    final validItems = <_Row>[];
    Set<Object?>? favoriteIds;
    Set<Object?>? groupIds;
    for (final row in incoming.items) {
      final id = row['id'] as String;
      if (row['kind'] == 'local') {
        favoriteIds ??= _referenceIds(UnifiedRestorePreferences._folders);
        if (!favoriteIds.contains(id)) {
          skip(1, '找不到本机收藏夹或关注分组的首页入口未恢复。');
          continue;
        }
      } else if (row['kind'] == 'group') {
        final mapped = aliases.containsKey(id) ? aliases[id] : id;
        groupIds ??= _referenceIds(groups);
        if (!groupIds.contains(mapped)) {
          skip(1, '找不到本机收藏夹或关注分组的首页入口未恢复。');
          continue;
        }
        if (id != mapped) {
          validItems.add({...row, 'id': mapped});
          continue;
        }
      }
      validItems.add(row);
    }
    final items = _mergeList<_Row>(current?.items ?? [], validItems, _homeId);
    if (current == null) {
      added++;
    } else {
      skip(1);
    }
    if (current == null || items.length != current.items.length) {
      writes[key] = jsonEncode({
        'custom': current?.custom ?? incoming.custom,
        'items': items,
      });
    }
  }

  Set<Object?> _referenceIds(String key) {
    final raw = _current(key);
    if (raw == null) return {};
    try {
      final rows = key == UnifiedRestorePreferences._folders
          ? _parser.favoriteFolders(raw)
          : _parser.groups(raw).groups;
      return {for (final row in rows) row['id']};
    } on FormatException {
      return {};
    }
  }

  void watch(List<_Row> incoming) {
    const key = UnifiedRestorePreferences._watch;
    final List<_Row> current;
    try {
      current = local[key] == null ? [] : _parser.watch(local[key]);
    } on FormatException {
      skip(incoming.length, '本机观看历史含无法识别的数据，未改动。');
      return;
    }
    final rows = _mergeList<_Row>(
      current,
      incoming,
      (row) => row['bvid'],
      limit: WatchHistoryService.maximumEntries,
      capacityWarning: '已达到观看历史上限，未挤掉任何本机记录。',
    );
    if (rows.length != current.length) writes[key] = jsonEncode(rows);
  }

  void search(List<String> incoming) {
    const key = UnifiedRestorePreferences._search;
    final List<String> current;
    try {
      current = local[key] == null ? [] : _parser.search(local[key]);
    } on FormatException {
      skip(incoming.length, '本机搜索历史含无法识别的数据，未改动。');
      return;
    }
    final rows = _mergeList<String>(
      current,
      incoming,
      (row) => row.trim(),
      limit: UnifiedRestorePreferences._searchLimit,
      capacityWarning: '已达到搜索历史上限，未挤掉任何本机记录。',
    );
    if (rows.length != current.length) {
      writes[key] = List<String>.unmodifiable(rows);
    }
  }

  void progress(Map<String, _Row> incoming) {
    if (incoming.isEmpty) return;
    final existing = <String, Object?>{};
    for (final entry in local.entries) {
      if (!entry.key.startsWith(UnifiedRestorePreferences._progressPrefix)) {
        continue;
      }
      try {
        final key = UnifiedRestorePreferences._canonicalProgressKey(entry.key);
        // A canonical local slot takes priority over a legacy alias.
        if (!existing.containsKey(key) || key == entry.key) {
          existing[key] = entry.value;
        }
      } on FormatException {
        // Leave unrecognized local keys untouched. They are never a write target.
      }
    }
    for (final entry in incoming.entries) {
      final key = entry.key;
      final cidIndex = key.lastIndexOf('_cid_');
      if (existing.containsKey(key)) {
        skip(1);
        continue;
      }
      final cid = entry.value['cid'];
      if (cidIndex < 0 && existing.containsKey('${key}_cid_$cid')) {
        skip(1);
        continue;
      }
      // A pre-existing latest entry is also an implicit record for its CID
      // until the app creates the per-part slot. Don't shadow that local record.
      if (cidIndex >= 0) {
        final latest = key.substring(0, cidIndex);
        if (existing.containsKey(latest)) {
          try {
            final localState = _parser.progress(existing[latest], latest);
            if (localState['cid'] == cid) {
              skip(1);
              continue;
            }
          } on FormatException {
            skip(1, '部分本机播放进度无法识别，未覆盖。');
            continue;
          }
        }
      }
      writes[key] = jsonEncode(entry.value);
      added++;
    }
  }
}
