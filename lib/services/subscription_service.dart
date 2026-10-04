import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/public_profile.dart';
import '../models/subscription.dart';
import 'bilibili_public_content_service.dart';

/// Foreground-only local RSS-style polling. No background service or cloud writes.
class SubscriptionService extends ChangeNotifier {
  SubscriptionService({
    BilibiliPublicContentService? contentService,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? clock,
    this.pageBudget = 20,
    this.maxSources = 20,
    this.requestTimeout = const Duration(seconds: 30),
  }) : content = contentService ?? BilibiliHttpPublicContentService(),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;
  static final SubscriptionService instance = SubscriptionService();
  static const storageKey = 'focubili_subscriptions_v1';
  static const backupKey = '${storageKey}_backup';
  static const displayLimit = 500;
  final BilibiliPublicContentService content;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _clock;
  final int pageBudget, maxSources;
  final Duration requestTimeout;
  bool enabled = false, notificationsEnabled = false, refreshing = false;
  String? storageError;
  bool _loaded = false, _foreground = false, _disposed = false;
  int _epoch = 0;
  Future<void>? _loading, _refresh;
  int _refreshEpoch = -1;
  Set<String> _refreshSources = {};
  bool _refreshAgain = false, _refreshAgainManual = false;
  bool _refreshManual = false;
  Future<void>? _writes;
  Timer? _timer;
  Map<String, SubscriptionSource> _sources = {};
  Map<String, SourceCheckpoint> _checkpoints = {};
  Map<String, SubscriptionFeedItem> _feed = {};
  Set<String> _announced = {};
  Set<String> _notificationClaims = {};
  List<SubscriptionSource> get sources => List.unmodifiable(_sources.values);
  List<SubscriptionFeedItem> get feed => List.unmodifiable(
    _feed.values.toList()
      ..sort((a, b) => b.discoveredAt.compareTo(a.discoveredAt)),
  );
  int get unreadCount => _feed.values.where((e) => e.readAt == null).length;
  SourceCheckpoint? checkpoint(String key) => _checkpoints[key];
  bool Function()? suppressNotifications;
  Future<bool> Function(int count)? notifySummary;

  Future<void> initialize() {
    if (_loaded) return Future.value();
    return _loading ??= _initialize().whenComplete(() => _loading = null);
  }

  Future<void> _initialize() async {
    try {
      final prefs = await _preferencesLoader();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        try {
          _restore(jsonDecode(raw));
        } catch (_) {
          final backup = prefs.getString(backupKey);
          if (backup == null) rethrow;
          _restore(jsonDecode(backup));
          // Keep corrupt bytes separately before future writes; never erase evidence.
          if (!await prefs.setString('${storageKey}_quarantine', raw)) {
            throw const SubscriptionStorageException();
          }
          storageError = '订阅数据损坏，已恢复上份有效快照。';
        }
      }
      _loaded = true;
      _schedule();
      if (!_disposed) notifyListeners();
    } catch (_) {
      storageError = '无法读取订阅数据，原数据已保留；请重启后重试。';
      _loaded = false;
      if (!_disposed) notifyListeners();
    }
  }

  Map<String, Object?> _json() => {
    'version': 1,
    'enabled': enabled,
    'notificationsEnabled': notificationsEnabled,
    'sources': _sources.values.map((e) => e.toJson()).toList(),
    'checkpoints': _checkpoints.map((k, v) => MapEntry(k, v.toJson())),
    'feed': _feed.values.map((e) => e.toJson()).toList(),
    'announced': _announced.toList(),
    'notificationClaims': _notificationClaims.toList(),
  };
  void _restore(Object? object) {
    final j = Map<String, dynamic>.from(object as Map);
    if (j['version'] != 1) {
      throw const FormatException('Unsupported subscription version');
    }
    final sources = <String, SubscriptionSource>{};
    for (final x in j['sources'] as List) {
      final source = SubscriptionSource.fromJson(
        Map<String, dynamic>.from(x as Map),
      );
      sources[source.key] = source;
    }
    final checkpoints = (j['checkpoints'] as Map).map(
      (k, v) => MapEntry(
        k as String,
        SourceCheckpoint.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    );
    if (sources.keys.any((key) => !checkpoints.containsKey(key))) {
      throw const FormatException('Missing source checkpoint');
    }
    final feed = <String, SubscriptionFeedItem>{};
    for (final x in j['feed'] as List) {
      final item = SubscriptionFeedItem.fromJson(
        Map<String, dynamic>.from(x as Map),
      );
      feed[item.bvid] = item;
    }
    _sources = sources;
    _checkpoints = checkpoints;
    _feed = feed;
    _announced = Set<String>.from(j['announced'] as List);
    _notificationClaims = Set<String>.from(j['notificationClaims'] as List);
    enabled = j['enabled'] == true;
    notificationsEnabled = j['notificationsEnabled'] == true;
  }

  Future<T> _mutate<T>(T Function() action) async {
    await initialize();
    final prior = _writes ?? Future<void>.value();
    final next = prior.then((_) async {
      if (!_loaded || _disposed) throw const SubscriptionStorageException();
      final previous = jsonEncode(_json());
      final result = action();
      try {
        final prefs = await _preferencesLoader();
        if (!await prefs.setString(backupKey, previous)) {
          throw const SubscriptionStorageException();
        }
        final encoded = jsonEncode(_json());
        if (!await prefs.setString(storageKey, encoded)) {
          throw const SubscriptionStorageException();
        }
        await prefs.reload();
        if (prefs.getString(storageKey) != encoded) {
          throw const SubscriptionStorageException();
        }
        storageError = null;
        if (!_disposed) notifyListeners();
        return result;
      } catch (_) {
        try {
          await (await _preferencesLoader()).reload();
        } catch (_) {
          /* retain last valid in-memory snapshot */
        }
        _restore(jsonDecode(previous));
        storageError = '订阅变更未保存，请检查设备存储后重试。';
        if (!_disposed) notifyListeners();
        throw const SubscriptionStorageException();
      }
    });
    late final Future<void> barrier;
    barrier = next
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_writes, barrier)) _writes = null;
        });
    _writes = barrier;
    return next;
  }

  Future<void> setEnabled(bool value) async {
    // Invalidate pending responses immediately, before waiting on disk.
    _epoch++;
    _timer?.cancel();
    try {
      await _mutate(() {
        enabled = value;
      });
    } finally {
      // Persistence rollback may restore enabled=true; restore its polling too.
      _schedule();
    }
    if (value && _foreground) unawaited(refresh());
  }

  Future<void> setNotificationsEnabled(bool value) => _mutate(() {
    notificationsEnabled = value;
  });
  Future<void> addSource(SubscriptionSource source) async {
    await _mutate(() {
      if (!_sources.containsKey(source.key) && _sources.length >= maxSources) {
        throw StateError('最多 $maxSources 个订阅源，这是本测试版的请求保护值。');
      }
      if (!_sources.containsKey(source.key)) {
        _sources[source.key] = source;
        _checkpoints[source.key] = SourceCheckpoint();
      }
    });
    if (enabled && _foreground) unawaited(refresh());
  }

  Future<void> pauseSource(String key, bool value) async {
    _epoch++;
    await _mutate(() {
      final source = _sources[key];
      if (source != null) _sources[key] = source.withPaused(value);
    });
    if (enabled && _foreground) unawaited(refresh());
  }

  Future<void> deleteSource(String key) async {
    _epoch++;
    await _mutate(() {
      _sources.remove(key);
      _checkpoints.remove(key);
    });
    if (enabled && _foreground) unawaited(refresh());
  }

  Future<void> markRead(String bvid) => _mutate(() {
    final item = _feed[bvid];
    if (item != null) _feed[bvid] = item.copyWith(readAt: _clock());
  });
  Future<void> markAllRead() => _mutate(() {
    for (final item in _feed.values.toList()) {
      _feed[item.bvid] = item.copyWith(readAt: _clock());
    }
  });
  Future<void> clearDisplayCache() => _mutate(() {
    _feed.clear();
  });

  void setForeground(bool value) {
    _foreground = value;
    if (!value) _epoch++;
    _schedule();
    if (value) unawaited(initialize().then((_) => refresh()));
  }

  void _schedule() {
    _timer?.cancel();
    if (enabled && _foreground) {
      _timer = Timer.periodic(
        const Duration(hours: 1),
        (_) => unawaited(refresh()),
      );
    }
  }

  bool _active(SubscriptionSource source, int epoch) =>
      enabled &&
      _foreground &&
      epoch == _epoch &&
      _sources[source.key]?.token == source.token &&
      _sources[source.key]?.paused == false;

  Future<void> refresh({bool manual = false}) {
    if (_disposed) return Future.value();
    final activeSources = {
      for (final source in sources.where((e) => !e.paused))
        '${source.key}:${source.token}',
    };
    if (_refresh != null) {
      // Ordinary repeated refreshes share a round. A resumed epoch or newly
      // added source needs one follow-up after the stale request releases.
      if (_refreshEpoch != _epoch ||
          !setEquals(_refreshSources, activeSources)) {
        _refreshAgain = true;
        _refreshAgainManual =
            _refreshAgainManual ||
            manual ||
            (_refreshEpoch != _epoch && _refreshManual);
      }
      return _refresh!;
    }
    _refreshEpoch = _epoch;
    _refreshManual = manual;
    _refreshSources = activeSources;
    late final Future<void> completed;
    completed = _refreshRound(manual).whenComplete(() async {
      if (identical(_refresh, completed)) _refresh = null;
      final again = _refreshAgain, againManual = _refreshAgainManual;
      _refreshAgain = false;
      _refreshAgainManual = false;
      if (again && enabled && _foreground) {
        await refresh(manual: againManual);
      }
    });
    _refresh = completed;
    return completed;
  }

  Future<void> _refreshRound(bool manual) async {
    await initialize();
    if (!enabled || !_foreground || !_loaded || _disposed) return;
    refreshing = true;
    if (!_disposed) notifyListeners();
    final epoch = _epoch;
    final pending = sources.where((e) => !e.paused).toList();
    var index = 0;
    final candidates = <String>{};
    // At most two sources; pages within a source remain sequential.
    Future<void> worker() async {
      while (index < pending.length &&
          enabled &&
          _foreground &&
          epoch == _epoch) {
        final source = pending[index++];
        final cp = _checkpoints[source.key]!;
        final now = _clock();
        if (cp.retryAt != null && now.isBefore(cp.retryAt!)) continue;
        if (!manual &&
            cp.lastSuccess != null &&
            now.difference(cp.lastSuccess!) < const Duration(hours: 1)) {
          continue;
        }
        try {
          candidates.addAll(await _scan(source, epoch));
        } catch (_) {
          // Storage failure is visible; independent sources may still be read.
        }
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      if (candidates.isNotEmpty &&
          enabled &&
          _foreground &&
          epoch == _epoch &&
          notificationsEnabled &&
          suppressNotifications?.call() != true) {
        // Claim durably before sending. A crash may miss a system hint, never lose unread.
        final claimed = await _mutate(() {
          if (!enabled || epoch != _epoch) return <String>{};
          final ids = candidates.difference(_notificationClaims);
          _notificationClaims.addAll(ids);
          return ids;
        });
        if (claimed.isNotEmpty &&
            enabled &&
            _foreground &&
            epoch == _epoch &&
            notificationsEnabled &&
            suppressNotifications?.call() != true) {
          try {
            await notifySummary?.call(claimed.length);
          } catch (_) {
            /* unread remains */
          }
        }
      }
    } catch (_) {
      // Durable save failure is already exposed via storageError; never crash automatic polling.
    } finally {
      refreshing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<Set<String>> _scan(SubscriptionSource source, int epoch) async {
    // Work on a detached checkpoint, never mutate durable state while requesting.
    final cp = SourceCheckpoint.fromJson(
      Map<String, dynamic>.from(_checkpoints[source.key]!.toJson()),
    );
    Future<CreatorContentPage<CreatorVideo>> request(int page) =>
        (source.kind == SubscriptionKind.creator
                ? content.loadVideos(
                    source.mid,
                    page: page,
                    order: CreatorVideoOrder.latest,
                  )
                : content.loadCollectionVideos(
                    source.mid,
                    source.seasonId!,
                    page: page,
                  ))
            .timeout(requestTimeout);
    final discovered = <String>{};
    int? overlapPage;
    var complete = false;
    try {
      if (!_active(source, epoch)) return {};
      final first = await request(1);
      if (!_active(source, epoch)) return {};
      final head = first.items.map((e) => e.bvid).toList();
      if (!listEquals(head, cp.firstPage) || cp.total != first.totalCount) {
        cp.pending.clear();
        cp.nextPage = 1;
      }
      cp.firstPage = head;
      cp.total = first.totalCount;
      var pageNumber = cp.nextPage;
      var page = pageNumber == 1 ? first : null;
      for (var budget = 0; budget < pageBudget; budget++) {
        if (!_active(source, epoch)) return {};
        page ??= await request(pageNumber);
        if (!_active(source, epoch)) return {};
        if (page.items.isEmpty && page.hasMore) {
          throw StateError('分页返回空数据但仍声明后续页面');
        }
        var knownBoundary = false;
        for (final video in page.items) {
          if (cp.seen.contains(video.bvid)) knownBoundary = true;
          cp.pending[video.bvid] = SubscriptionFeedItem(
            bvid: video.bvid,
            title: video.title,
            coverUrl: video.coverUrl,
            sources: {source.key: source.name},
            discoveredAt: _clock(),
            publishedAt: video.publishedAt,
            collectionAdded: source.kind == SubscriptionKind.collection,
          );
        }
        if (source.kind == SubscriptionKind.creator &&
            cp.initialized &&
            knownBoundary) {
          overlapPage ??= pageNumber + 1;
        }
        cp.nextPage = pageNumber + 1;
        if (!page.hasMore ||
            (overlapPage != null && pageNumber >= overlapPage)) {
          complete = true;
          break;
        }
        pageNumber++;
        page = null;
      }
      if (!complete) cp.error = '分页尚未扫描完成，保留缓存与扫描进度，请继续刷新。';
      cp.failures = 0;
      cp.retryAt = null;
    } catch (_) {
      if (!_active(source, epoch)) return {};
      cp.failures++;
      cp.retryAt = _clock().add(
        Duration(minutes: min(60, 1 << min(cp.failures, 6))),
      );
      cp.error =
          '刷新未完成：网络、会话或 B 站风控异常。已保留缓存，${cp.retryAt!.toLocal().hour}:${cp.retryAt!.toLocal().minute.toString().padLeft(2, '0')}后可重试。';
    }
    if (!_active(source, epoch)) return {};
    return _mutate(() {
      if (!_active(source, epoch)) return <String>{};
      if (complete) {
        for (final item in cp.pending.values) {
          final previous = _feed[item.bvid];
          if (previous != null) {
            _feed[item.bvid] = previous.copyWith(
              sources: {...previous.sources, ...item.sources},
              collectionAdded: previous.collectionAdded || item.collectionAdded,
            );
          } else if (cp.initialized &&
              !cp.seen.contains(item.bvid) &&
              !_announced.contains(item.bvid)) {
            _feed[item.bvid] = item;
            discovered.add(item.bvid);
          }
        }
        // All discoveries are indexed before trimming the display cache. Notification claims are separate.
        if (cp.initialized) {
          _announced.addAll(
            cp.pending.keys.where((bvid) => !cp.seen.contains(bvid)),
          );
        }
        cp.seen.addAll(cp.pending.keys);
        cp.initialized = true;
        cp.pending.clear();
        cp.nextPage = 1;
        cp.lastSuccess = _clock();
        cp.error = null;
        final sorted = feed;
        _feed = {for (final item in sorted.take(displayLimit)) item.bvid: item};
      }
      _checkpoints[source.key] = cp;
      return discovered;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _foreground = false;
    _refreshAgain = false;
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}

class SubscriptionStorageException implements Exception {
  const SubscriptionStorageException();
  @override
  String toString() => '订阅数据未保存，请重试';
}
