import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/public_profile.dart';
import '../models/subscription.dart';
import 'bilibili_public_content_service.dart';
import '../platform/app_platform.dart';
import 'subscription_snapshot_store.dart';
import 'subscription_background_service.dart';

/// Device-local polling with optional Android WorkManager checks. No cloud writes.
class SubscriptionService extends ChangeNotifier {
  SubscriptionService({
    BilibiliPublicContentService? contentService,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? clock,
    SubscriptionSnapshotStore? snapshotStore,
    Future<void> Function(bool enabled, int generation)? backgroundScheduler,
    this.pageBudget = 20,
    this.maxSources = 50,
    this.requestTimeout = const Duration(seconds: 30),
  }) : content = contentService ?? BilibiliHttpPublicContentService(),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now,
       _snapshotStore =
           snapshotStore ??
           (preferencesLoader == null &&
                   AppPlatformDetector.current == AppPlatform.android &&
                   !AppPlatformDetector.isFlutterTest
               ? SqliteSubscriptionSnapshotStore()
               : null),
       _backgroundScheduler = backgroundScheduler;
  static final SubscriptionService instance = SubscriptionService();
  static const storageKey = 'focubili_subscriptions_v1';
  static const backupKey = '${storageKey}_backup';
  static const displayLimit = 500;
  final BilibiliPublicContentService content;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _clock;
  final SubscriptionSnapshotStore? _snapshotStore;
  final Future<void> Function(bool enabled, int generation)?
  _backgroundScheduler;
  bool backgroundRefreshEnabled = false;
  DateTime? lastBackgroundCheckAt;
  String? backgroundStatus;
  int _generation = 0, _refreshGeneration = 0, _backgroundCursor = 0;
  int? _backgroundRunGeneration;
  int get notificationGeneration => _generation;
  DateTime? _runDeadline;
  bool get backgroundRefreshSupported =>
      _backgroundScheduler != null ||
      (AppPlatformDetector.current == AppPlatform.android &&
          !AppPlatformDetector.isFlutterTest);
  bool get _canRun =>
      _foreground ||
      (_backgroundRunGeneration != null &&
          backgroundRefreshEnabled &&
          _backgroundRunGeneration == _generation);

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
  String? _snapshotText;
  List<SubscriptionFeedItem>? _feedView;
  int? _unreadCount;
  void _invalidateFeed() {
    _feedView = null;
    _unreadCount = null;
  }

  List<SubscriptionSource> get sources => List.unmodifiable(_sources.values);
  List<SubscriptionFeedItem> get feed => _feedView ??= List.unmodifiable(
    _feed.values.toList()
      ..sort((a, b) => b.discoveredAt.compareTo(a.discoveredAt)),
  );
  int get unreadCount =>
      _unreadCount ??= _feed.values.where((e) => e.readAt == null).length;
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
      await prefs.reload();
      final databaseRaw = await _snapshotStore?.read();
      final raw = databaseRaw ?? prefs.getString(storageKey);
      if (raw != null) {
        try {
          _restoreRaw(raw);
        } catch (_) {
          if (databaseRaw != null) {
            // Recover only the transactional SQLite backup, never stale legacy data.
            final recovered = await _snapshotStore!.recover((value) {
              try {
                _restoreRaw(value);
                return true;
              } catch (_) {
                return false;
              }
            });
            if (recovered == null) rethrow;
            _restoreRaw(recovered);
            storageError = '订阅数据损坏，已恢复上份有效快照。';
          } else {
            final backup = prefs.getString(backupKey);
            if (backup == null) rethrow;
            _restoreRaw(backup);
            // Keep corrupt bytes separately before future writes; never erase evidence.
            if (!await prefs.setString('${storageKey}_quarantine', raw)) {
              throw const SubscriptionStorageException();
            }
            storageError = '订阅数据损坏，已恢复上份有效快照。';
          }
        }
      }
      if (_snapshotStore != null && databaseRaw == null) {
        // One-time non-destructive migration. Keep the legacy snapshot/backup;
        // SQLite becomes authoritative, including on every future process start.
        await _snapshotStore.transact((current, save) {
          if (current != null) {
            _restoreRaw(current);
          } else {
            save(jsonEncode(_json()));
          }
        });
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
    'backgroundRefreshEnabled': backgroundRefreshEnabled,
    'generation': _generation,
    'backgroundCursor': _backgroundCursor,
    'lastBackgroundCheckAt': lastBackgroundCheckAt?.toIso8601String(),
    'backgroundStatus': backgroundStatus,
    'sources': _sources.values.map((e) => e.toJson()).toList(),
    'checkpoints': _checkpoints.map((k, v) => MapEntry(k, v.toJson())),
    'feed': _feed.values.map((e) => e.toJson()).toList(),
    'announced': _announced.toList(),
    'notificationClaims': _notificationClaims.toList(),
  };
  // Still read the store on every cross-engine boundary. Only decoding an
  // identical authoritative snapshot can be skipped; CAS always reads afresh.
  void _restoreRaw(String raw) {
    if (_snapshotText == raw) return;
    _snapshotText = null;
    _restore(jsonDecode(raw));
    _snapshotText = raw;
  }

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
    _invalidateFeed();
    _announced = Set<String>.from(j['announced'] as List);
    _notificationClaims = Set<String>.from(j['notificationClaims'] as List);
    enabled = j['enabled'] == true;
    notificationsEnabled = j['notificationsEnabled'] == true;
    backgroundRefreshEnabled = j['backgroundRefreshEnabled'] == true;
    _generation = j['generation'] as int? ?? 0;
    _backgroundCursor = j['backgroundCursor'] as int? ?? 0;
    lastBackgroundCheckAt = DateTime.tryParse(
      j['lastBackgroundCheckAt'] as String? ?? '',
    );
    backgroundStatus = j['backgroundStatus'] as String?;
  }

  Future<T> _mutate<T>(
    FutureOr<T> Function() action, {
    bool readOnly = false,
  }) async {
    await initialize();
    final prior = _writes ?? Future<void>.value();
    final next = prior.then((_) async {
      if (!_loaded || _disposed) throw const SubscriptionStorageException();
      final before = _snapshotText ?? jsonEncode(_json());
      final hadError = storageError != null;
      var previous = before;
      Object? actionFailure;
      Future<T> apply() async {
        try {
          // An action may partially change memory before failing. Force rollback
          // and every CAS replay to restore a fresh authoritative snapshot.
          _snapshotText = null;
          return await action();
        } catch (error) {
          actionFailure = error;
          rethrow;
        }
      }

      try {
        late final T result;
        if (readOnly && _snapshotStore != null) {
          final current = await _snapshotStore.read();
          if (current != null) _restoreRaw(current);
          result = await action();
        } else if (_snapshotStore != null) {
          String? committed;
          result = await _snapshotStore.transact((current, save) async {
            if (current != null) _restoreRaw(current);
            previous = _snapshotText ?? jsonEncode(_json());
            final value = await apply();
            committed = jsonEncode(_json());
            if (committed != current) save(committed!);
            return value;
          });
          _snapshotText = committed;
        } else {
          result = await apply();
          final encoded = jsonEncode(_json());
          if (encoded != previous) {
            final prefs = await _preferencesLoader();
            if (!await prefs.setString(backupKey, previous) ||
                !await prefs.setString(storageKey, encoded)) {
              throw const SubscriptionStorageException();
            }
            await prefs.reload();
            if (prefs.getString(storageKey) != encoded) {
              throw const SubscriptionStorageException();
            }
          }
          _snapshotText = encoded;
        }
        storageError = null;
        if (!_disposed && (before != _snapshotText || hadError)) {
          notifyListeners();
        }
        return result;
      } catch (_) {
        try {
          await (await _preferencesLoader()).reload();
        } catch (_) {
          /* retain last valid in-memory snapshot */
        }
        _restoreRaw(previous);
        if (actionFailure != null) rethrow;
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
        _generation++;
      });
    } finally {
      // Persistence rollback may restore enabled=true; restore its polling too.
      _schedule();
      await reconcileBackgroundSchedule();
      if (enabled && _foreground) unawaited(refresh());
    }
  }

  Future<void> setBackgroundRefreshEnabled(bool value) async {
    if (value && !backgroundRefreshSupported) {
      throw UnsupportedError('仅 Android 支持后台检查');
    }
    _epoch++;
    await _mutate(() {
      backgroundRefreshEnabled = value;
      _generation++;
      backgroundStatus = value ? '等待系统安排检查' : '后台检查已关闭';
    });
    await reconcileBackgroundSchedule();
  }

  Future<void> reconcileBackgroundSchedule() async {
    if (!backgroundRefreshSupported) return;
    final generation = _generation;
    final requested = enabled && backgroundRefreshEnabled;
    try {
      await (_backgroundScheduler ?? SubscriptionBackgroundScheduler.configure)(
        requested,
        generation,
      );
      if (backgroundStatus == '后台任务安排失败，请重新开关后重试') {
        await _mutate(() {
          if (_generation == generation) {
            backgroundStatus = requested ? '等待系统安排检查' : '后台检查已关闭';
          }
        });
      }
    } catch (_) {
      // Stored opt-in remains truthful; startup/toggle retries reconciliation.
      await _mutate(() {
        if (_generation == generation) {
          backgroundStatus = '后台任务安排失败，请重新开关后重试';
        }
      });
    }
  }

  /// Reload after headless work. No stale whole-snapshot writes on foreground resume.
  Future<void> reload() async {
    await initialize();
    if (_snapshotStore == null || !_loaded) return;
    await _mutate(() {}, readOnly: true);
  }

  Future<void> runBackgroundCheck(int generation) async {
    await reload();
    if (!_loaded ||
        !enabled ||
        !backgroundRefreshEnabled ||
        generation != _generation) {
      return;
    }
    _backgroundRunGeneration = generation;
    _runDeadline = _clock().add(const Duration(minutes: 8));
    try {
      await refresh();
      await _mutate(() {
        if (generation != _generation ||
            !backgroundRefreshEnabled ||
            !enabled) {
          return;
        }
        lastBackgroundCheckAt = _clock();
        backgroundStatus = storageError != null
            ? '检查未保存，请检查设备存储'
            : (_runDeadline != null && !_clock().isBefore(_runDeadline!))
            ? '本轮检查已到时限，剩余订阅下次继续'
            : _checkpoints.values.any((e) => e.error != null)
            ? '检查结束，部分订阅未完成；保留缓存并稍后重试'
            : '后台检查完成';
      });
    } finally {
      _backgroundRunGeneration = null;
      _runDeadline = null;
    }
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
        _generation++;
      }
    });
    await reconcileBackgroundSchedule();
    if (enabled && _foreground) unawaited(refresh());
  }

  Future<void> pauseSource(String key, bool value) async {
    _epoch++;
    try {
      await _mutate(() {
        _generation++;
        final source = _sources[key];
        if (source != null) _sources[key] = source.withPaused(value);
      });
    } finally {
      await reconcileBackgroundSchedule();
      // The epoch also cancels an in-flight scan when persistence rolls back.
      if (enabled && _foreground) unawaited(refresh());
    }
  }

  Future<void> deleteSource(String key) async {
    _epoch++;
    try {
      await _mutate(() {
        _generation++;
        _sources.remove(key);
        _checkpoints.remove(key);
      });
    } finally {
      await reconcileBackgroundSchedule();
      if (enabled && _foreground) unawaited(refresh());
    }
  }

  Future<void> markRead(String bvid) => _mutate(() {
    final item = _feed[bvid];
    if (item != null && item.readAt == null) {
      _feed[bvid] = item.copyWith(readAt: _clock());
      _invalidateFeed();
    }
  });
  Future<void> markAllRead() => _mutate(() {
    for (final item in _feed.values.toList()) {
      if (item.readAt == null) {
        _feed[item.bvid] = item.copyWith(readAt: _clock());
        _invalidateFeed();
      }
    }
  });
  Future<void> clearDisplayCache() => _mutate(() {
    _feed.clear();
    _invalidateFeed();
  });

  void setForeground(bool value) {
    _foreground = value;
    if (!value) _epoch++;
    _schedule();
    if (value) {
      unawaited(() async {
        try {
          await refresh();
        } catch (_) {
          /* Storage error is displayed; lifecycle must not crash. */
        }
      }());
    }
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
      _canRun &&
      epoch == _epoch &&
      _generation == _refreshGeneration &&
      (_runDeadline == null || _clock().isBefore(_runDeadline!)) &&
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
    try {
      await reload();
    } catch (_) {
      return;
    }
    if (!enabled || !_canRun || !_loaded || _disposed) return;
    _refreshGeneration = _generation;
    final epoch = _epoch;
    final allSources = sources;
    final offset = allSources.isEmpty
        ? 0
        : _backgroundCursor % allSources.length;
    final ordered = _backgroundRunGeneration == null
        ? allSources
        : [...allSources.skip(offset), ...allSources.take(offset)];
    final now = _clock();
    final pending = ordered.where((source) {
      final cp = _checkpoints[source.key];
      return !source.paused &&
          cp != null &&
          (cp.retryAt == null || !now.isBefore(cp.retryAt!)) &&
          (manual ||
              cp.lastSuccess == null ||
              now.difference(cp.lastSuccess!) >= const Duration(hours: 1));
    }).toList();
    if (pending.isEmpty) return;
    refreshing = true;
    if (!_disposed) notifyListeners();
    var index = 0;
    final candidates = <String>{};
    // At most two sources; pages within a source remain sequential.
    Future<void> worker() async {
      while (index < pending.length && enabled && _canRun && epoch == _epoch) {
        final source = pending[index++];
        final cp = _checkpoints[source.key];
        if (cp == null || !_active(source, epoch)) continue;
        final now = _clock();
        if (cp.retryAt != null && now.isBefore(cp.retryAt!)) continue;
        if (!manual &&
            cp.lastSuccess != null &&
            now.difference(cp.lastSuccess!) < const Duration(hours: 1)) {
          continue;
        }
        try {
          if (_backgroundRunGeneration != null) {
            await _mutate(() {
              if (!_active(source, epoch)) return;
              final keys = _sources.keys.toList();
              _backgroundCursor = (keys.indexOf(source.key) + 1) % keys.length;
            });
          }
          if (!_active(source, epoch)) continue;
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
          _canRun &&
          epoch == _epoch &&
          notificationsEnabled &&
          suppressNotifications?.call() != true) {
        // Claim durably before sending. A crash may miss a system hint, never lose unread.
        final claimed = await _mutate(() {
          if (!enabled ||
              !_canRun ||
              epoch != _epoch ||
              _generation != _refreshGeneration ||
              !notificationsEnabled) {
            return <String>{};
          }
          final ids = candidates.difference(_notificationClaims);
          _notificationClaims.addAll(ids);
          return ids;
        });
        if (claimed.isNotEmpty &&
            enabled &&
            _canRun &&
            epoch == _epoch &&
            notificationsEnabled &&
            suppressNotifications?.call() != true) {
          try {
            // Recheck persisted state. Native dispatch validates the same
            // generation under its own short SQLite transaction, serializing
            // notification posting against disabling without a Dart-held lock.
            await reload();
            if (enabled &&
                _canRun &&
                epoch == _epoch &&
                _generation == _refreshGeneration &&
                notificationsEnabled &&
                suppressNotifications?.call() != true) {
              await notifySummary?.call(claimed.length);
            }
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
    final initialCheckpoint = jsonEncode(_checkpoints[source.key]!.toJson());
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
      for (
        var budget = 0;
        budget <
            (_backgroundRunGeneration == null
                ? pageBudget
                : min(pageBudget, 3));
        budget++
      ) {
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
    // A CAS conflict replays the mutation against the newest whole snapshot.
    // Keep the network result immutable: each attempt must get a fresh copy
    // before clearing pending entries or extending the deduplication index.
    final scannedCheckpoint = jsonEncode(cp.toJson());
    return _mutate(() {
      if (!_active(source, epoch)) return <String>{};
      // Another engine may have scanned this source meanwhile. Never replace
      // newer checkpoints with a detached stale scan. Read state is merged below.
      if (jsonEncode(_checkpoints[source.key]!.toJson()) != initialCheckpoint) {
        return <String>{};
      }
      final cp = SourceCheckpoint.fromJson(
        Map<String, dynamic>.from(jsonDecode(scannedCheckpoint) as Map),
      );
      final discovered = <String>{};
      var feedChanged = false;
      if (complete) {
        for (final item in cp.pending.values) {
          final previous = _feed[item.bvid];
          if (previous != null) {
            final mergedSources = {...previous.sources, ...item.sources};
            if (!mapEquals(previous.sources, mergedSources) ||
                (!previous.collectionAdded && item.collectionAdded)) {
              _feed[item.bvid] = previous.copyWith(
                sources: mergedSources,
                collectionAdded:
                    previous.collectionAdded || item.collectionAdded,
              );
              feedChanged = true;
            }
          } else if (cp.initialized &&
              !cp.seen.contains(item.bvid) &&
              !_announced.contains(item.bvid)) {
            _feed[item.bvid] = item;
            feedChanged = true;
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
        if (feedChanged) {
          _invalidateFeed();
          if (_feed.length > displayLimit) {
            _feed = {
              for (final item in feed.take(displayLimit)) item.bvid: item,
            };
            _invalidateFeed();
          }
        }
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
    final store = _snapshotStore;
    if (store is SqliteSubscriptionSnapshotStore) unawaited(store.close());
    super.dispose();
  }
}

class SubscriptionStorageException implements Exception {
  const SubscriptionStorageException();
  @override
  String toString() => '订阅数据未保存，请重试';
}
