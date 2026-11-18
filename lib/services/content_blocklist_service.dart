import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_blocklist.dart';

/// Serializes local mutations so concurrent menus cannot overwrite one another.
class ContentBlocklistService {
  const ContentBlocklistService({
    this.preferencesLoader = SharedPreferences.getInstance,
  });

  final Future<SharedPreferences> Function() preferencesLoader;
  static const storageKey = 'content.blocklist_v1';
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static Future<void>? _pending;
  static final _needsReload = Expando<bool>();
  static final _bvid = RegExp(r'^BV[0-9A-Za-z]{10}$');

  Future<ContentBlocklist> load() async {
    final pending = _pending;
    if (pending != null) await pending;
    return _read(await _authoritativePreferences());
  }

  Future<SharedPreferences> _authoritativePreferences() async {
    final preferences = await preferencesLoader();
    if (_needsReload[preferences] == true) {
      await _reloadPreferences(preferences);
    }
    return preferences;
  }

  Future<void> _reloadPreferences(SharedPreferences preferences) async {
    await preferences.reload();
    _needsReload[preferences] = null;
  }

  ContentBlocklist _read(SharedPreferences preferences) {
    final raw = preferences.getString(storageKey);
    if (raw == null) return const ContentBlocklist();
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['version'] != 1 ||
        data['videos'] is! Map ||
        data['creators'] is! Map) {
      throw const FormatException('Invalid local blocklist');
    }
    final videos = <String, String>{};
    final creators = <int, String>{};
    for (final entry in (data['videos'] as Map).entries) {
      if (entry.key is String &&
          _bvid.hasMatch(entry.key) &&
          entry.value is String) {
        videos[entry.key as String] = entry.value as String;
      }
    }
    for (final entry in (data['creators'] as Map).entries) {
      final mid = int.tryParse('${entry.key}');
      if (mid != null && mid > 0 && entry.value is String) {
        creators[mid] = entry.value as String;
      }
    }
    final rules = <ContentBlockKind, List<String>>{};
    if (data.containsKey('rules')) {
      final rawRules = data['rules'];
      if (rawRules is! Map) throw const FormatException('Invalid block rules');
      for (final entry in rawRules.entries) {
        final kind = ContentBlockKind.values.asNameMap()[entry.key];
        final rawValues = entry.value;
        if (kind == null ||
            kind == ContentBlockKind.creatorUid ||
            rawValues is! List) {
          throw const FormatException('Invalid block rule kind');
        }
        final values = <String>[];
        final seen = <String>{};
        for (final rawValue in rawValues) {
          if (rawValue is! String) {
            throw const FormatException('Invalid block rule value');
          }
          final value = ContentBlockRule(kind, rawValue).validated().value;
          if (seen.add(ContentBlockRule.normalizeText(value))) {
            values.add(value);
          }
        }
        if (values.isNotEmpty) rules[kind] = List.unmodifiable(values);
      }
    }
    return ContentBlocklist(
      videos: Map.unmodifiable(videos),
      creators: Map.unmodifiable(creators),
      rules: Map.unmodifiable(rules),
    );
  }

  Future<void> _change(
    void Function(
      Map<String, String>,
      Map<int, String>,
      Map<ContentBlockKind, List<String>>,
    )
    edit,
  ) {
    final result = (_pending ?? Future<void>.value()).then((_) async {
      final preferences = await _authoritativePreferences();
      // Do not replace unreadable storage with an empty list during a mutation.
      final current = _read(preferences);
      final videos = Map<String, String>.from(current.videos);
      final creators = Map<int, String>.from(current.creators);
      final rules = current.rules.map(
        (kind, values) => MapEntry(kind, List<String>.of(values)),
      );
      edit(videos, creators, rules);
      try {
        final saved = await preferences.setString(
          storageKey,
          jsonEncode({
            'version': 1,
            'videos': videos,
            'creators': creators.map((mid, name) => MapEntry('$mid', name)),
            if (rules.isNotEmpty)
              'rules': rules.map((kind, values) => MapEntry(kind.name, values)),
          }),
        );
        if (!saved) throw StateError('Blocklist was not saved');
      } catch (_) {
        // SharedPreferences updates its cache before the platform write. Do
        // not expose an uncommitted removal or include it in the next edit.
        _needsReload[preferences] = true;
        try {
          await _reloadPreferences(preferences);
        } catch (_) {
          // Later loads and edits must retry the reload, not trust the cache.
        }
        rethrow;
      }
      changes.value++;
    });
    final settled = result.catchError((Object _) {});
    _pending = settled;
    settled.then((_) {
      if (identical(_pending, settled)) _pending = null;
    });
    return result;
  }

  Future<void> blockVideo(String bvid, String title) {
    if (!_bvid.hasMatch(bvid)) throw ArgumentError.value(bvid, 'bvid');
    return _change((videos, _, _) => videos[bvid] = title.trim());
  }

  Future<void> blockCreator(int mid, String name) {
    if (mid <= 0) throw ArgumentError.value(mid, 'mid');
    return _change((_, creators, _) => creators[mid] = name.trim());
  }

  Future<void> unblockVideo(String bvid) =>
      _change((videos, _, _) => videos.remove(bvid));

  Future<void> unblockCreator(int mid) =>
      _change((_, creators, _) => creators.remove(mid));

  /// Adds or replaces a rule in the same atomic write as stable ID blocks.
  /// An edit does not resurrect a rule deleted in another open page.
  Future<void> saveRule(
    ContentBlockRule input, {
    ContentBlockRule? previous,
  }) async {
    final rule = input.validated();
    final old = previous?.validated();
    if (old != null && old.kind != rule.kind) {
      throw ArgumentError('不能更改规则类型。');
    }
    await _change((_, creators, rules) {
      if (rule.kind == ContentBlockKind.creatorUid) {
        final uid = int.parse(rule.value);
        final oldUid = old == null ? null : int.parse(old.value);
        if (oldUid != null && !creators.containsKey(oldUid)) {
          throw ArgumentError('这条规则已不存在，请返回后重试。');
        }
        if (uid != oldUid && creators.containsKey(uid)) {
          throw ArgumentError('这条规则已存在。');
        }
        if (uid == oldUid) return;
        if (oldUid != null) creators.remove(oldUid);
        // A label accompanying the old UID cannot identify a different UID.
        creators[uid] = '';
        return;
      }
      final values = rules.putIfAbsent(rule.kind, () => []);
      int indexOf(String value) {
        final key = ContentBlockRule.normalizeText(value);
        return values.indexWhere(
          (item) => ContentBlockRule.normalizeText(item) == key,
        );
      }

      final oldIndex = old == null ? -1 : indexOf(old.value);
      if (old != null && oldIndex < 0) {
        throw ArgumentError('这条规则已不存在，请返回后重试。');
      }
      final duplicate = indexOf(rule.value);
      if (duplicate >= 0 && duplicate != oldIndex) {
        throw ArgumentError('这条规则已存在。');
      }
      if (oldIndex < 0) {
        values.add(rule.value);
      } else {
        values[oldIndex] = rule.value;
      }
    });
  }

  Future<void> removeRule(ContentBlockRule input) async {
    final rule = input.validated();
    if (rule.kind == ContentBlockKind.creatorUid) {
      await unblockCreator(int.parse(rule.value));
      return;
    }
    await _change((_, _, rules) {
      final values = rules[rule.kind];
      if (values == null) return;
      final key = ContentBlockRule.normalizeText(rule.value);
      values.removeWhere(
        (value) => ContentBlockRule.normalizeText(value) == key,
      );
      if (values.isEmpty) rules.remove(rule.kind);
    });
  }
}
