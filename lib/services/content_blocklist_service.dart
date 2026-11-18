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
    return ContentBlocklist(
      videos: Map.unmodifiable(videos),
      creators: Map.unmodifiable(creators),
    );
  }

  Future<void> _change(
    void Function(Map<String, String>, Map<int, String>) edit,
  ) {
    final result = (_pending ?? Future<void>.value()).then((_) async {
      final preferences = await _authoritativePreferences();
      // Do not replace unreadable storage with an empty list during a mutation.
      final current = _read(preferences);
      final videos = Map<String, String>.from(current.videos);
      final creators = Map<int, String>.from(current.creators);
      edit(videos, creators);
      try {
        final saved = await preferences.setString(
          storageKey,
          jsonEncode({
            'version': 1,
            'videos': videos,
            'creators': creators.map((mid, name) => MapEntry('$mid', name)),
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
    return _change((videos, _) => videos[bvid] = title.trim());
  }

  Future<void> blockCreator(int mid, String name) {
    if (mid <= 0) throw ArgumentError.value(mid, 'mid');
    return _change((_, creators) => creators[mid] = name.trim());
  }

  Future<void> unblockVideo(String bvid) =>
      _change((videos, _) => videos.remove(bvid));

  Future<void> unblockCreator(int mid) =>
      _change((_, creators) => creators.remove(mid));
}
