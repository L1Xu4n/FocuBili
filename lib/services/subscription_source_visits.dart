import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/subscription.dart';
import 'cache_lifecycle.dart';

/// Visits acknowledge discovery events, not playback, video reads or notification
/// delivery. Keep them outside the shared foreground/background scanner snapshot.
abstract final class SubscriptionSourceVisits {
  static String identity(SubscriptionSource source) =>
      '${source.key}/${source.token}';
  static String event(SubscriptionFeedItem item) => _eventIds[item] ??= sha256
      .convert(
        utf8.encode('${item.bvid}@${item.discoveredAt.microsecondsSinceEpoch}'),
      )
      .toString();
  // No persisted title, BV, image URL or date history. Keep the hash memoized
  // only for the lifetime of the immutable cached feed object.
  static final _eventIds = Expando<String>();
  static String _key(String scope) => 'subscription_source_visits_v1/$scope';
  static Future<void>? _queue;

  static Map<String, Set<String>> _decode(String? raw) {
    if (raw == null) return {};
    final stored = jsonDecode(raw) as Map<String, dynamic>;
    return stored.map(
      (key, value) => MapEntry(key, Set<String>.from(value as List)),
    );
  }

  static Future<Map<String, Set<String>>> load(String scope) async {
    await _queue;
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_key(scope)));
  }

  static Future<void> acknowledge({
    required String scope,
    required int revision,
    required String source,
    required Set<String> presented,
    required Set<String> liveSources,
    required Set<String> retainedEvents,
    required bool Function() stillVisible,
  }) {
    // Merge taps from mounted views; queued writes retain their original scope.
    final operation = (_queue ?? Future<void>.value()).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (scope != CacheLifecycle.accountScope ||
          revision != CacheLifecycle.account.value ||
          !stillVisible()) {
        return;
      }
      final map = _decode(prefs.getString(_key(scope)));
      map.removeWhere((key, _) => !liveSources.contains(key));
      for (final events in map.values) {
        events.retainAll(retainedEvents);
      }
      (map[source] ??= {}).addAll(presented);
      if (!await prefs.setString(
        _key(scope),
        jsonEncode(map.map((key, events) => MapEntry(key, events.toList()))),
      )) {
        throw StateError('来源提示未保存');
      }
    });
    final queued = operation.catchError((Object _) {});
    _queue = queued;
    queued.then((_) {
      if (identical(_queue, queued)) _queue = null;
    });
    return operation;
  }
}
