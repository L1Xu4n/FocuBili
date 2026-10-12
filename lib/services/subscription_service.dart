import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/public_profile.dart';
import '../models/subscription.dart';
import '../models/subscription_history.dart';
import 'subscription_history_store.dart';
import 'subscription_request_scope.dart';
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
    SubscriptionHistoryStore? historyStore,
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
       _backgroundScheduler = backgroundScheduler,
       historyStorage =
           historyStore ??
           (AppPlatformDetector.isFlutterTest
               ? MemorySubscriptionHistoryStore()
               : FileSubscriptionHistoryStore());
  static final SubscriptionService instance = SubscriptionService();
  static const storageKey = 'focubili_subscriptions_v1';
  static const backupKey = '${storageKey}_backup';
  static const displayLimit = 500;
  final BilibiliPublicContentService content;
  final SubscriptionHistoryStore historyStorage;
  final String _instanceId =
      '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
  int _leaseSequence = 0;
  String? _leaseOwner;
  DateTime? _leaseUntil;
  String? _roundLease;
  Completer<void>? _localLeaseDone;
  Map<String, SubscriptionHistoryJob> _historyJobs = {};
  final Map<String, Future<void>> _historyRuns = {};
  final Map<String, SubscriptionRequestScope> _requests = {};
  SubscriptionHistoryJob? historyJob(String sourceKey) =>
      _historyJobs[sourceKey];
  bool historyRunning(String sourceKey) => _historyRuns.containsKey(sourceKey);
  void _cancelRequests() {
    for (final request in _requests.values.toList()) {
      request.cancel();
    }
  }

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
        Object? decoded;
        try {
          decoded = jsonDecode(raw);
        } catch (_) {
          /* backup recovery below */
        }
        if (decoded is Map &&
            decoded['version'] is int &&
            decoded['version'] != 1 &&
            decoded['version'] != 2) {
          throw const FormatException('Unsupported subscription version');
        }
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
        // A backup write failure is a storage failure, not corruption. Never
        // restore an older snapshot over valid current data in that case.
        if (decoded is Map &&
            decoded['version'] == 1 &&
            prefs.getString('${storageKey}_pre_beta4') == null &&
            !await prefs.setString('${storageKey}_pre_beta4', raw)) {
          throw const SubscriptionStorageException();
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
    'version': 2,
    'leaseOwner': _leaseOwner,
    'leaseUntil': _leaseUntil?.toIso8601String(),
    'historyJobs': _historyJobs.map((k, v) => MapEntry(k, v.toJson())),
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
    if (j['version'] != 1 && j['version'] != 2) {
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
    final history = (j['historyJobs'] as Map? ?? {}).map(
      (k, v) => MapEntry(
        k as String,
        SubscriptionHistoryJob.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    );
    _leaseOwner = j['leaseOwner'] as String?;
    _leaseUntil = DateTime.tryParse(j['leaseUntil'] as String? ?? '');
    _historyJobs = history;
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
    _cancelRequests();
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
    _cancelRequests();
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
        _checkpoints[source.key] = SourceCheckpoint(baselineAt: _clock());
        _generation++;
      }
    });
    await reconcileBackgroundSchedule();
    if (enabled && _foreground) unawaited(refresh());
  }

  Future<void> pauseSource(String key, bool value) async {
    _epoch++;
    _cancelRequests();
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
    _cancelRequests();
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
    if (!value) {
      _epoch++;
      _cancelRequests();
    }
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
          !cp.blocked &&
          (cp.retryAt == null || !now.isBefore(cp.retryAt!)) &&
          (manual ||
              cp.partial ||
              cp.lastSuccess == null ||
              now.difference(cp.lastSuccess!) >= const Duration(hours: 1));
    }).toList();
    if (pending.isEmpty) return;
    if (_localLeaseDone != null) await _localLeaseDone!.future;
    final lease = await _acquireLease();
    if (lease == null) return;
    _roundLease = lease;
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
            !cp.partial &&
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
      await _releaseLease(lease);
      _roundLease = null;
      refreshing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<String?> _acquireLease() async {
    final owner = '${_instanceId}_${++_leaseSequence}';
    final acquired = await _mutate(() {
      final now = _clock();
      if (_leaseOwner != null &&
          _leaseUntil != null &&
          now.isBefore(_leaseUntil!)) {
        return false;
      }
      _leaseOwner = owner;
      _leaseUntil = now.add(requestTimeout * 3);
      return true;
    });
    if (!acquired) return null;
    _localLeaseDone = Completer<void>();
    return owner;
  }

  bool _ownsLease(String? owner) =>
      owner != null &&
      _leaseOwner == owner &&
      _leaseUntil != null &&
      _clock().isBefore(_leaseUntil!);

  Future<void> _releaseLease(String owner) async {
    try {
      await _mutate(() {
        if (_leaseOwner == owner) {
          _leaseOwner = null;
          _leaseUntil = null;
        }
      });
    } catch (_) {
      /* expiry allows recovery after an interrupted release */
    } finally {
      _localLeaseDone?.complete();
      _localLeaseDone = null;
    }
  }

  Future<CreatorContentPage<CreatorVideo>> _requestPage(
    SubscriptionSource source,
    int page,
    String task,
  ) async {
    final scope = SubscriptionRequestScope();
    _requests[task] = scope;
    try {
      final result = await scope
          .run(
            () => source.kind == SubscriptionKind.creator
                ? content.loadVideos(
                    source.mid,
                    page: page,
                    order: CreatorVideoOrder.latest,
                  )
                : content.loadCollectionVideos(
                    source.mid,
                    source.seasonId!,
                    page: page,
                  ),
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              scope.cancel();
              throw TimeoutException('Subscription request timed out');
            },
          );
      if (scope.cancelled) throw StateError('Request cancelled');
      if (result.page != page) {
        throw const SubscriptionPaginationException('接口返回了不同页码');
      }
      if (result.items.isEmpty && result.hasMore) {
        throw const SubscriptionPaginationException('接口没有继续返回内容');
      }
      return result;
    } finally {
      if (identical(_requests[task], scope)) _requests.remove(task);
    }
  }

  String _pageSignature(Iterable<String> ids) =>
      sha256.convert(utf8.encode((ids.toList()..sort()).join('|'))).toString();

  void _checkProgress(
    Map<String, int> signatures,
    String signature,
    int page,
    bool empty,
  ) {
    final previous = signatures[signature];
    if (!empty && previous != null && previous != page) {
      throw const SubscriptionPaginationException('接口重复返回同一页，已停止获取');
    }
    signatures[signature] = page;
  }

  SubscriptionFeedItem _feedItem(
    SubscriptionSource source,
    CreatorVideo video,
  ) => SubscriptionFeedItem(
    bvid: video.bvid,
    title: video.title,
    coverUrl: video.coverUrl,
    sources: {source.key: source.name},
    discoveredAt: _clock(),
    publishedAt: video.publishedAt,
    collectionAdded: source.kind == SubscriptionKind.collection,
  );

  // Live event dedupe never consults historical import IDs.
  bool _mergeLive(SubscriptionFeedItem item, {required bool newEvent}) {
    final previous = _feed[item.bvid];
    if (previous != null) {
      final merged = {...previous.sources, ...item.sources};
      if (!mapEquals(merged, previous.sources) ||
          (!previous.collectionAdded && item.collectionAdded)) {
        _feed[item.bvid] = previous.copyWith(
          sources: merged,
          collectionAdded: previous.collectionAdded || item.collectionAdded,
        );
        _invalidateFeed();
      }
      return false;
    }
    if (!newEvent || _announced.contains(item.bvid)) return false;
    _announced.add(item.bvid);
    _feed[item.bvid] = item;
    _invalidateFeed();
    return true;
  }

  void _trimFeed() {
    if (_feed.length > displayLimit) {
      _feed = {for (final item in feed.take(displayLimit)) item.bvid: item};
      _invalidateFeed();
    }
  }

  Future<void> retrySource(String key) async {
    await _mutate(() {
      final cp = _checkpoints[key];
      if (cp == null) return;
      // Explicit retry keeps saved data, but starts a new bounded coverage pass.
      cp.blocked = false;
      cp.signatures.clear();
      cp.nextPage = 1;
      cp.knownPages = 0;
      cp.error = null;
    });
    await refresh(manual: true);
  }

  Future<Set<String>> _scan(SubscriptionSource source, int epoch) async {
    final lease = _roundLease;
    final discovered = <String>{};
    bool active() => _active(source, epoch) && _ownsLease(lease);
    await _mutate(() {
      if (!active()) return;
      final cp = _checkpoints[source.key]!;
      if (cp.algorithm == 1) {
        cp.algorithm = 2;
        cp.fullBaseline = cp.initialized;
        cp.baselineAt ??= _clock();
        if (!cp.initialized) cp.seen.addAll(cp.pending.keys);
        // Keep legacy pending metadata for inspection/recovery; never notify it.
        cp.nextPage = 1;
        cp.error = null;
      }
      cp.baselineAt ??= _clock();
    });
    if (!active()) return discovered;
    var cp = SourceCheckpoint.fromJson(_checkpoints[source.key]!.toJson());
    var pageNumber = cp.nextPage;

    final budget = _backgroundRunGeneration != null
        ? min(pageBudget, 3)
        : pageBudget;
    try {
      final pages = <int>[
        if (pageNumber > 1) 1,
        if (pageNumber > 2) pageNumber - 1,
      ];
      final advancing = max(1, budget - pages.length);
      for (var i = 0; i < advancing; i++) {
        pages.add(pageNumber + i);
      }
      for (final requestedPage in pages) {
        if (!active()) break;
        final page = await _requestPage(
          source,
          requestedPage,
          'live:${source.key}',
        );
        if (!active()) break;
        final snapshot = jsonEncode(cp.toJson());
        final result = await _mutate(() {
          if (!active() ||
              jsonEncode(_checkpoints[source.key]!.toJson()) != snapshot) {
            return (false, true, <String>{});
          }
          final next = SourceCheckpoint.fromJson(cp.toJson());
          final ids = page.items.map((e) => e.bvid).toList();
          final headProbe = requestedPage == 1 && next.nextPage > 1;
          final overlap = requestedPage < next.nextPage;
          if (!headProbe) {
            _checkProgress(
              next.signatures,
              _pageSignature(ids),
              requestedPage,
              ids.isEmpty,
            );
          }
          if (headProbe && !listEquals(ids, next.firstPage)) {
            next.needsHeadRecheck = true;
            // Insertion shifts legitimate pages to other page numbers. The
            // pending head coverage pass will close the gap; stale signatures
            // must not misclassify this movement as an API pagination loop.
            next.signatures.clear();
          }
          if (requestedPage == 1) next.firstPage = ids;
          if (requestedPage == 2) next.secondPage = ids;
          next.total = page.totalCount;
          final wasInitialized = next.initialized;
          final known =
              page.items.isNotEmpty &&
              page.items.every(
                (video) =>
                    next.anchors.contains(video.bvid) ||
                    (next.fullBaseline && next.seen.contains(video.bvid)) ||
                    (video.publishedAt != null &&
                        next.baselineAt != null &&
                        video.publishedAt!.isBefore(next.baselineAt!)),
              );
          final newerThanBoundary = page.items.any(
            (v) =>
                v.publishedAt != null &&
                next.watermark != null &&
                v.publishedAt!.isAfter(next.watermark!),
          );
          if (!overlap) {
            next.knownPages = known && !newerThanBoundary
                ? next.knownPages + 1
                : 0;
          }
          final additions = <String>{};
          for (final video in page.items) {
            final published = video.publishedAt;
            final validDate =
                published != null &&
                !published.isAfter(_clock().add(const Duration(minutes: 5)));
            if (validDate &&
                (next.scanNewest == null ||
                    published.isAfter(next.scanNewest!))) {
              next.scanNewest = published;
            }
            final unseen = !next.seen.contains(video.bvid);
            final isCollection = source.kind == SubscriptionKind.collection;
            final afterStart =
                validDate && !published.isBefore(next.baselineAt!);
            final event =
                unseen &&
                (isCollection
                    ? wasInitialized
                    : wasInitialized
                    ? (next.fullBaseline || afterStart)
                    : afterStart);
            if (_mergeLive(_feedItem(source, video), newEvent: event)) {
              additions.add(video.bvid);
            }
            next.seen.add(video.bvid);
          }
          var complete = false;
          if (!headProbe) {
            next.nextPage = max(next.nextPage, requestedPage + 1);
            complete =
                !page.hasMore ||
                (source.kind == SubscriptionKind.creator &&
                    (!wasInitialized
                        ? requestedPage >= 2
                        : next.knownPages >= 2));
          }
          next.failures = 0;
          next.retryAt = null;
          next.error = null;
          if (complete && next.needsHeadRecheck) {
            next.nextPage = 1;
            next.catchingUp = true;
            next.needsHeadRecheck = false;
            next.knownPages = 0;
            next.signatures.clear();
          } else if (complete) {
            next.catchingUp = false;
            next.initialized = true;
            next.fullBaseline = next.fullBaseline || !page.hasMore;
            next.anchors = {...next.firstPage, ...next.secondPage};
            next.watermark = next.scanNewest ?? next.watermark;
            next.scanNewest = null;
            next.nextPage = 1;
            next.knownPages = 0;
            next.signatures.clear();
            next.lastSuccess = _clock();
          }
          _checkpoints[source.key] = next;
          _leaseUntil = _clock().add(requestTimeout * 3);
          _trimFeed();
          return (true, complete, additions);
        });
        discovered.addAll(result.$3);
        if (!result.$1 || result.$2) break;
        cp = SourceCheckpoint.fromJson(_checkpoints[source.key]!.toJson());
      }
    } catch (error) {
      if (active()) {
        await _mutate(() {
          if (!active()) return;
          final current = _checkpoints[source.key]!;
          if (error is SubscriptionPaginationException) {
            current.blocked = true;
            current.error = '${error.message}；已保存内容保留，可稍后手动重试。';
          } else {
            current.failures++;
            current.retryAt = _clock().add(
              Duration(minutes: min(60, 1 << min(current.failures, 6))),
            );
            current.error = '获取中断，已保存进度；网络或接口恢复后继续。';
          }
        });
      }
    }
    return discovered;
  }

  Future<void> startHistory(String sourceKey, {int? limit = 100}) async {
    if (limit != null && limit < 1) throw ArgumentError.value(limit);
    await _mutate(() {
      final source = _sources[sourceKey];
      if (source == null || source.paused) throw StateError('请先恢复订阅源');
      final existing = _historyJobs[sourceKey];
      if (existing != null) {
        existing.sourceToken = source.token;
        if (limit == null && existing.limit != null) {
          existing.limit = null;
          if (existing.status == HistoryImportStatus.limited) {
            existing.batches = max(0, existing.batches - 1);
            existing.nextPage = max(1, existing.nextPage - 1);
            existing.status = HistoryImportStatus.paused;
          }
        }
        return;
      }
      _historyJobs[sourceKey] = SubscriptionHistoryJob(
        id: '${_instanceId}_${++_leaseSequence}',
        sourceKey: sourceKey,
        sourceToken: source.token,
        limit: limit,
      );
    });
    await resumeHistory(sourceKey);
  }

  Future<void> pauseHistory(String sourceKey) async {
    _requests['history:$sourceKey']?.cancel();
    await _mutate(() {
      final job = _historyJobs[sourceKey];
      if (job != null && job.status == HistoryImportStatus.running) {
        job.status = HistoryImportStatus.paused;
      }
    });
  }

  Future<void> resumeHistory(String sourceKey) {
    if (_historyRuns.containsKey(sourceKey)) return _historyRuns[sourceKey]!;
    late final Future<void> run;
    run = _runHistory(sourceKey).whenComplete(() {
      if (identical(_historyRuns[sourceKey], run)) {
        _historyRuns.remove(sourceKey);
      }
      if (!_disposed) notifyListeners();
    });
    _historyRuns[sourceKey] = run;
    return run;
  }

  Future<List<SubscriptionFeedItem>> historyItems(
    String sourceKey, {
    int offset = 0,
    int count = 100,
  }) async {
    final job = _historyJobs[sourceKey];
    final seen = <String>{};
    final result = <SubscriptionFeedItem>[];
    if (job != null) {
      for (var index = 0; index < job.batches; index++) {
        final batch = await historyStorage.read(job.id, index);
        if (batch == null) throw const SubscriptionStorageException();
        for (final item in batch.items) {
          if (!job.ids.contains(item.bvid) || !seen.add(item.bvid)) continue;
          if (seen.length > offset) result.add(item);
          if (result.length >= count) return result;
        }
      }
    }
    // Legacy partial baselines are retained without changing their read state.
    for (final item
        in _checkpoints[sourceKey]?.pending.values ??
            <SubscriptionFeedItem>[]) {
      if (seen.add(item.bvid) && seen.length > offset) result.add(item);
      if (result.length >= count) break;
    }
    return result;
  }

  Future<void> _runHistory(String key) async {
    await initialize();
    final runOwner = '${_instanceId}_${++_leaseSequence}';
    final claimed = await _mutate(() {
      final job = _historyJobs[key];
      if (job == null ||
          job.status == HistoryImportStatus.complete ||
          job.status == HistoryImportStatus.limited ||
          (job.retryAt != null && _clock().isBefore(job.retryAt!)) ||
          (job.status == HistoryImportStatus.running &&
              job.runUntil != null &&
              _clock().isBefore(job.runUntil!))) {
        return false;
      }
      job.revisit = job.nextPage > 1;
      job.runOwner = runOwner;
      job.runUntil = _clock().add(requestTimeout * 3);
      job.status = HistoryImportStatus.running;
      job.error = null;
      return true;
    });
    if (!claimed) return;
    while (!_disposed && _foreground && enabled) {
      // A manual live refresh takes precedence at the next page boundary.
      if (_refresh != null) await _refresh;
      await reload();
      final job = _historyJobs[key];
      final source = _sources[key];
      if (job == null ||
          source == null ||
          source.paused ||
          source.token != job.sourceToken ||
          job.runOwner != runOwner ||
          job.status != HistoryImportStatus.running) {
        break;
      }
      final lease = await _acquireLease();
      if (lease == null) {
        await _mutate(() {
          final current = _historyJobs[key];
          if (current?.id == job.id) {
            current!.status = HistoryImportStatus.paused;
          }
        });
        break;
      }
      final epoch = _epoch;
      bool active() =>
          !_disposed &&
          _foreground &&
          enabled &&
          epoch == _epoch &&
          _ownsLease(lease) &&
          _sources[key]?.token == job.sourceToken &&
          _sources[key]?.paused == false &&
          _historyJobs[key]?.id == job.id &&
          _historyJobs[key]?.runOwner == runOwner &&
          _historyJobs[key]?.status == HistoryImportStatus.running;
      try {
        var batch = await historyStorage.read(job.id, job.batches);
        if (batch == null) {
          final requestedPage = job.revisit
              ? max(1, job.nextPage - 1)
              : job.nextPage;
          final page = await _requestPage(
            source,
            requestedPage,
            'history:$key',
          );
          if (!active()) break;
          final signature = _pageSignature(page.items.map((e) => e.bvid));
          final signatures = Map<String, int>.from(job.signatures);
          _checkProgress(
            signatures,
            signature,
            requestedPage,
            page.items.isEmpty,
          );
          batch = SubscriptionHistoryBatch(
            page: requestedPage,
            items: [for (final video in page.items) _feedItem(source, video)],
            hasMore: page.hasMore,
            signature: signature,
            total: page.totalCount,
          );
          await historyStorage.write(job.id, job.batches, batch);
          batch = await historyStorage.read(job.id, job.batches);
        }
        if (batch == null ||
            (batch.page != job.nextPage &&
                !(job.revisit && batch.page == job.nextPage - 1))) {
          throw const SubscriptionPaginationException('历史页与保存位置不一致');
        }
        final saved = batch;
        await _mutate(() {
          if (!active()) return;
          final current = _historyJobs[key]!;
          if (current.batches != job.batches || current.runOwner != runOwner) {
            return;
          }
          _checkProgress(
            current.signatures,
            saved.signature,
            saved.page,
            saved.items.isEmpty,
          );
          for (final item in saved.items) {
            if (current.limit != null && current.ids.length >= current.limit!) {
              break;
            }
            current.ids.add(item.bvid);
          }
          current.listChanged =
              current.listChanged ||
              (current.total != null &&
                  saved.total != null &&
                  current.total != saved.total);
          current.total = saved.total;
          current.batches++;
          current.nextPage = max(current.nextPage, saved.page + 1);
          current.revisit = false;
          current.runUntil = _clock().add(requestTimeout * 3);
          current.failures = 0;
          current.retryAt = null;
          current.error = null;
          if (!saved.hasMore) {
            current.status = HistoryImportStatus.complete;
          } else if (current.limit != null &&
              current.ids.length >= current.limit!) {
            current.status = HistoryImportStatus.limited;
          }
        });
      } catch (error) {
        if (!_disposed) {
          await _mutate(() {
            if (!active()) return;
            final current = _historyJobs[key]!;
            if (error is SubscriptionPaginationException) {
              current.status = HistoryImportStatus.blocked;
              current.error = '${error.message}；当前只能确认已导入的范围。';
            } else {
              current.status = HistoryImportStatus.failed;
              current.failures++;
              current.retryAt = _clock().add(
                Duration(minutes: min(60, 1 << min(current.failures, 6))),
              );
              current.error = '导入中断，已保存内容保留，稍后可继续。';
            }
          });
        }
        break;
      } finally {
        await _releaseLease(lease);
      }
    }
    if (!_disposed) {
      await _mutate(() {
        final job = _historyJobs[key];
        if (job?.status == HistoryImportStatus.running &&
            job?.runOwner == runOwner) {
          job!.status = HistoryImportStatus.paused;
          job.runUntil = null;
        }
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _foreground = false;
    _refreshAgain = false;
    _epoch++;
    _cancelRequests();
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

class SubscriptionPaginationException implements Exception {
  const SubscriptionPaginationException(this.message);
  final String message;
}
