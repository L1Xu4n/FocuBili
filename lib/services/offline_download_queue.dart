import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/offline_download_task.dart';
import '../models/video_preview.dart';
import 'cache_lifecycle.dart';
import 'course_cache_access.dart';
import 'course_cache_library.dart';
import 'download_control.dart';
import 'download_notification_service.dart';
import 'offline_cache_locations.dart';
import 'offline_video_service.dart';

/// Owns durable FIFO tasks independently of player and library page lifetimes.
class OfflineDownloadQueue extends ChangeNotifier {
  /// Injects storage, transfer and notification boundaries for deterministic tests.
  OfflineDownloadQueue({
    OfflineVideoService? library,
    CourseCacheLibrary? courseLibrary,
    OfflineVideoPreferencesLoader? preferencesLoader,
    Future<void> Function(List<OfflineDownloadTask>)? publishProgress,
    DateTime Function()? clock,
  }) : library = library ?? OfflineVideoService(),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _publishProgress = publishProgress,
       _clock = clock ?? DateTime.now,
       courses = courseLibrary ?? CourseCacheLibrary.instance {
    CacheLifecycle.account.addListener(_accountChanged);
  }

  static final OfflineDownloadQueue instance = _createDefault();

  /// Connects OS foreground-service timeouts to real queue cancellation.
  static OfflineDownloadQueue _createDefault() {
    final notifications = DownloadNotificationService.instance;
    final queue = OfflineDownloadQueue(publishProgress: notifications.publish);
    notifications.onPauseRequested = queue.pauseAll;
    return queue;
  }

  static const storageKey = 'focubili_download_queue_v3';
  static const _completedRetention = Duration(days: 14);
  static const _previousStorageKey = 'focubili_download_queue_v2';
  final OfflineVideoService library;
  final CourseCacheLibrary courses;
  int? _courseMid;
  bool _visible(OfflineDownloadTask task) =>
      task.courseMid == null || task.courseMid == _courseMid;

  Future<void> _resolveCourseAccount() async {
    final revision = CacheLifecycle.account.value;
    final mid = await courses.access.currentLocalMid();
    if (!_closing && revision == CacheLifecycle.account.value) _courseMid = mid;
  }

  void _accountChanged() {
    if (_closing) return;
    _courseMid = null;
    final active = _activeId == null ? null : _find(_activeId!);
    if (active?.courseMid != null) _control?.interrupt();
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.courseMid != null && task.status == DownloadTaskStatus.queued) {
        _tasks[i] = task.copyWith(status: DownloadTaskStatus.paused);
      }
    }
    _emit();
    unawaited(
      _resolveCourseAccount().then((_) {
        if (!_closing) _emit();
      }),
    );
  }

  Future<List<CourseCacheEntry>?> _courseFiles() async {
    final mid = _courseMid;
    if (mid == null) return null;
    try {
      final revision = CacheLifecycle.account.value;
      final files = await courses.entries();
      return revision == CacheLifecycle.account.value && mid == _courseMid
          ? files
          : null;
    } on CourseCacheFailure {
      return null; // Unavailable private storage is not an empty cache.
    }
  }

  OfflineCacheLocations _locationsFor(bool isCourse) =>
      isCourse ? courses.cacheLocations : library.cacheLocations;

  Future<bool> _locationAvailable(OfflineDownloadTask task) async {
    final id = task.cacheLocationId;
    if (id == null) return true;
    try {
      await _locationsFor(task.courseMid != null).requireRoot(id);
      return true;
    } on OfflineCacheLocationUnavailable {
      return false;
    }
  }

  Future<CourseCacheEntry?> courseEntry(VideoPreview video, VideoPart part) =>
      _findCourseEntry(video, part, requireMedia: true);

  Future<CourseCacheEntry?> _findCourseEntry(
    VideoPreview video,
    VideoPart part, {
    required bool requireMedia,
  }) async {
    final found = await courses.entries();
    final id =
        '${video.courseSeasonId}-${part.courseEpisodeId}-${part.courseAid}-${part.cid}';
    return found
        .where((entry) => entry.id == id && (!requireMedia || entry.hasMedia))
        .firstOrNull;
  }

  final OfflineVideoPreferencesLoader _preferencesLoader;
  final DateTime Function() _clock;
  final Future<void> Function(List<OfflineDownloadTask>)? _publishProgress;
  final List<OfflineDownloadTask> _tasks = [];
  final _completions = StreamController<OfflineDownloadTask>.broadcast();
  Timer? _speedTimer;
  Timer? _retentionTimer;
  final _speedClock = Stopwatch();
  int? _speedSampleBytes;
  Future<void>? _initialization;
  Future<void>? _running;
  Future<void> _writes = Future.value();
  Future<void> _commands = Future.value();
  Future<void> _notifications = Future.value();
  List<OfflineDownloadTask>? _pendingNotification;
  bool _publishingNotification = false;
  DownloadControl? _control;
  String? _activeId;
  String? _storageError;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSavedProgress = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closing = false;

  /// Exposes an immutable snapshot, preventing views from mutating queue state.
  List<OfflineDownloadTask> get tasks =>
      List.unmodifiable(_tasks.where(_visible));

  /// Emits only new successful transfers, never restored history or failed tasks.
  Stream<OfflineDownloadTask> get completions => _completions.stream;

  /// Surfaces persistent storage failures instead of silently losing queued work.
  String? get storageError => _storageError;

  /// Loads once; interrupted transfers restart paused, never as false completions.
  Future<void> initialize() => _initialization ??= _load();

  /// Restores tasks and reconciles files committed just before a previous shutdown.
  Future<void> _load() async {
    try {
      final prefs = await _preferencesLoader();
      final raw =
          prefs.getString(storageKey) ?? prefs.getString(_previousStorageKey);
      final restored = raw == null
          ? <OfflineDownloadTask>[]
          : (jsonDecode(raw) as List)
                .map(
                  (entry) => OfflineDownloadTask.fromJson(
                    Map<String, dynamic>.from(entry as Map),
                  ),
                )
                .toList();
      if (restored.map((e) => e.id).toSet().length != restored.length) {
        throw const FormatException('Duplicate task IDs');
      }
      final completed = await library.loadDownloads();
      if (restored.any((task) => task.courseMid != null)) {
        await _resolveCourseAccount();
      }
      final courseFiles = await _courseFiles();
      final now = _clock();
      _tasks.clear();
      for (final task in restored) {
        if (_historyExpired(task, now)) continue;
        final int? ready;
        DateTime? downloadedAt;
        if (task.courseMid == null) {
          final entry = completed
              .where(
                (file) =>
                    file.bvid == task.video.bvid &&
                    file.cid == task.part.cid &&
                    file.cacheLocationId == task.cacheLocationId &&
                    (task.status == DownloadTaskStatus.completed ||
                        !file.downloadedAt.isBefore(task.createdAt)),
              )
              .firstOrNull;
          ready = entry?.sizeBytes;
          downloadedAt = entry?.downloadedAt;
        } else if (!_visible(task) || courseFiles == null) {
          _tasks.add(
            task.status == DownloadTaskStatus.completed ||
                    task.status == DownloadTaskStatus.failed
                ? task
                : task.copyWith(status: DownloadTaskStatus.paused),
          );
          continue;
        } else {
          final entry = courseFiles
              .where(
                (file) =>
                    file.id == task.courseEntryId &&
                    file.mid == task.courseMid &&
                    file.cacheLocationId == task.cacheLocationId &&
                    file.hasMedia,
              )
              .firstOrNull;
          ready = entry == null ? null : entry.videoBytes + entry.audioBytes;
        }
        if (task.status == DownloadTaskStatus.completed && ready == null) {
          if (!await _locationAvailable(task)) _tasks.add(task);
          continue;
        }
        final restoredTask = ready != null
            ? task.copyWith(
                status: DownloadTaskStatus.completed,
                // Course receipts record authorization checks, not completion.
                completedAt: task.completedAt ?? downloadedAt ?? now,
                receivedBytes: ready,
                totalBytes: ready,
              )
            : task.copyWith(
                status: task.status == DownloadTaskStatus.failed
                    ? DownloadTaskStatus.failed
                    : DownloadTaskStatus.paused,
                error: task.error,
                courseDiagnostic: task.courseDiagnostic,
              );
        if (!_historyExpired(restoredTask, now)) _tasks.add(restoredTask);
      }
      _storageError = null;
      await _save();
      _scheduleRetention();
      _emit();
    } catch (_) {
      _storageError = '下载队列读取失败，原始记录已保留。';
      notifyListeners();
      rethrow;
    }
  }

  bool _historyExpired(OfflineDownloadTask task, DateTime now) =>
      task.status == DownloadTaskStatus.completed &&
      task.completedAt != null &&
      !now.isBefore(task.completedAt!.add(_completedRetention));

  /// Keep history current while the queue lives even if no page is open.
  void _scheduleRetention({Duration? retryAfter}) {
    _retentionTimer?.cancel();
    _retentionTimer = null;
    if (_closing) return;
    final now = _clock();
    Duration? earliest;
    for (final task in _tasks) {
      if (task.status != DownloadTaskStatus.completed ||
          task.completedAt == null) {
        continue;
      }
      final remaining = task.completedAt!
          .add(_completedRetention)
          .difference(now);
      if (earliest == null || remaining < earliest) earliest = remaining;
    }
    if (earliest == null) return;
    // The periodic ceiling also rechecks large clock jumps on a live device.
    final delay =
        retryAfter ??
        (earliest.isNegative
            ? Duration.zero
            : earliest > const Duration(days: 1)
            ? const Duration(days: 1)
            : earliest);
    _retentionTimer = Timer(delay, () {
      if (_closing) return;
      unawaited(
        _command(_expireHistory).then<void>(
          (_) => _scheduleRetention(),
          onError: (Object _, StackTrace _) =>
              _scheduleRetention(retryAfter: const Duration(minutes: 1)),
        ),
      );
    });
  }

  /// Changes only queue records; never invokes the media or partial-file APIs.
  Future<void> _expireHistory() async {
    final now = _clock();
    final expired = <int, OfflineDownloadTask>{};
    for (var i = 0; i < _tasks.length; i++) {
      if (_historyExpired(_tasks[i], now)) expired[i] = _tasks[i];
    }
    if (expired.isEmpty) return;
    for (final index in expired.keys.toList().reversed) {
      _tasks.removeAt(index);
    }
    try {
      await _save();
    } catch (_) {
      for (final entry in expired.entries) {
        // Do not undo any concurrent transfer progress.
        if (_find(entry.value.id) == null) {
          _tasks.insert(entry.key.clamp(0, _tasks.length), entry.value);
        }
      }
      rethrow;
    }
    _emit();
  }

  /// Serializes user commands across all entry points of this shared queue.
  Future<T> _command<T>(Future<T> Function() action) {
    final next = _commands.then((_) async {
      await initialize();
      if (_closing) throw StateError('Download queue is closing');
      return action();
    });
    _commands = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Persists snapshots in order, checking the platform's boolean write result.
  Future<void> _save() {
    final snapshot = jsonEncode(_tasks.map((e) => e.toJson()).toList());
    final next = _writes.then((_) async {
      final prefs = await _preferencesLoader();
      if (!await prefs.setString(storageKey, snapshot)) {
        throw const OfflineVideoException('下载队列保存失败，请检查可用空间。');
      }
      _storageError = null;
    });
    _writes = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _storageError = '下载队列保存失败，请检查可用空间。';
        notifyListeners();
      },
    );
    return next;
  }

  /// Inserts one deduplicated task and returns immediately after durable enqueue.
  Future<OfflineDownloadTask> enqueue(
    VideoPreview video, {
    VideoPart? part,
    int quality = 32,
    int? expectedAccountRevision,
    bool revalidateCourse = false,
  }) => _command(() async {
    return (await _enqueue(
      video,
      part: part,
      quality: quality,
      expectedAccountRevision: expectedAccountRevision,
      revalidateCourse: revalidateCourse,
    ))!;
  });

  /// Adds an ordinary part only when it has neither a durable task nor media.
  /// The check runs inside the queue command to handle submissions from other screens.
  Future<OfflineDownloadTask?> enqueueOrdinaryIfMissing(
    VideoPreview video, {
    required VideoPart part,
    required int quality,
  }) => _command(() {
    if (video.isCourse) {
      throw const OfflineVideoException('课程请使用独立下载入口。');
    }
    return _enqueue(
      video,
      part: part,
      quality: quality,
      skipExistingOrdinary: true,
    );
  });

  Future<OfflineDownloadTask?> _enqueue(
    VideoPreview video, {
    VideoPart? part,
    required int quality,
    int? expectedAccountRevision,
    bool revalidateCourse = false,
    bool skipExistingOrdinary = false,
  }) async {
    final target = part ?? video.initialPart;
    if (!video.isCourse &&
            !RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(video.bvid) ||
        target.cid <= 0 ||
        quality <= 0) {
      throw const OfflineVideoException('视频或分 P 编号无效。');
    }
    if (video.isCourse) await _resolveCourseAccount();
    if (expectedAccountRevision != null &&
        expectedAccountRevision != CacheLifecycle.account.value) {
      throw const OfflineVideoException('登录账号已变化，请重新选择下载。');
    }
    if (video.isCourse && _courseMid == null) {
      throw const OfflineVideoException('请登录购买课程的账号后再下载。');
    }
    final mid = video.isCourse ? _courseMid : null;
    final taskId = mid == null
        ? '${video.bvid}:${target.cid}'
        : 'course:$mid:${video.courseSeasonId}-${target.courseEpisodeId}-${target.courseAid}-${target.cid}';
    final existing = _find(taskId);
    if (skipExistingOrdinary &&
        (existing != null ||
            await library.isDownloaded(video.bvid, cid: target.cid))) {
      return null;
    }
    if (existing != null && existing.status != DownloadTaskStatus.completed) {
      return existing;
    }
    final CourseCacheEntry? existingCourse;
    if (mid != null) {
      existingCourse = await _findCourseEntry(
        video,
        target,
        requireMedia: false,
      );
      // Keep previous receipts and server deadlines at their original location.
      if (existing != null &&
          !revalidateCourse &&
          ((existingCourse?.mid == mid && existingCourse!.hasMedia) ||
              !await _locationAvailable(existing))) {
        return existing;
      }
    } else {
      existingCourse = null;
      if (existing != null &&
          (await library.isDownloaded(video.bvid, cid: target.cid) ||
              !await _locationAvailable(existing))) {
        return existing;
      }
    }
    final String? locationId;
    if (existingCourse != null) {
      locationId = existingCourse.cacheLocationId;
    } else if (mid != null && existing != null) {
      locationId = existing.cacheLocationId;
    } else {
      locationId = await _locationsFor(mid != null).activeId();
    }
    final task = OfflineDownloadTask(
      video: video,
      part: target,
      quality: quality,
      requireExactQuality: skipExistingOrdinary,
      createdAt: _clock(),
      courseMid: mid,
      cacheLocationId: locationId,
    );
    if (mid != null) {
      OfflineDownloadTask.fromJson(task.toJson());
      if (_courseMid != mid ||
          (expectedAccountRevision != null &&
              expectedAccountRevision != CacheLifecycle.account.value)) {
        throw const OfflineVideoException('登录账号已变化，请重新选择下载。');
      }
    }
    if (existing != null) _tasks.remove(existing);
    _tasks.add(task);
    try {
      await _save();
    } catch (_) {
      _tasks.remove(task);
      if (existing != null) _tasks.add(existing);
      rethrow;
    }
    _emit();
    _pump();
    return task;
  }

  /// Interrupts the active request before acknowledging a pause to the UI.
  Future<void> pause(String id) => _command(() async {
    final task = _find(id);
    if (task == null ||
        !_visible(task) ||
        task.status == DownloadTaskStatus.completed) {
      return;
    }
    _replace(task.copyWith(status: DownloadTaskStatus.paused));
    if (_activeId == id) {
      _control?.interrupt();
      await _running;
    }
    await _save();
    _emit();
  });

  /// Pauses every unfinished transfer when the OS withdraws foreground execution.
  Future<void> pauseAll() => _command(() async {
    for (var index = 0; index < _tasks.length; index++) {
      final task = _tasks[index];
      if (task.status == DownloadTaskStatus.queued ||
          task.status == DownloadTaskStatus.downloading) {
        _tasks[index] = task.copyWith(status: DownloadTaskStatus.paused);
      }
    }
    _control?.interrupt();
    await _running;
    await _save();
    _emit();
  });

  /// Requeues a paused or failed task after its previous transfer has stopped.
  Future<void> resume(String id) => _command(() async {
    final task = _find(id);
    if (task == null ||
        !_visible(task) ||
        task.status == DownloadTaskStatus.completed ||
        task.status == DownloadTaskStatus.downloading) {
      return;
    }
    _replace(
      task.copyWith(status: DownloadTaskStatus.queued, clearError: true),
    );
    try {
      await _save();
    } catch (_) {
      _replace(task);
      rethrow;
    }
    _emit();
    _pump();
  });

  /// Cancels a task and removes partial bytes; completed library files stay intact.
  Future<void> remove(String id) => _command(() async {
    final task = _find(id);
    if (task == null || !_visible(task)) return;
    if (_activeId == id) {
      _replace(task.copyWith(status: DownloadTaskStatus.paused));
      _control?.interrupt();
      await _running;
    }
    if (task.status != DownloadTaskStatus.completed) {
      if (task.courseMid == null) {
        await library.discardPartial(
          task.video.bvid,
          task.part.cid,
          task.quality,
          cacheLocationId: task.cacheLocationId,
        );
      } else {
        await courses.discardPartial(
          task.courseMid!,
          task.courseEntryId,
          cacheLocationId: task.cacheLocationId,
        );
      }
    }
    final index = _tasks.indexWhere((e) => e.id == id);
    final removed = _tasks.removeAt(index);
    try {
      await _save();
    } catch (_) {
      _tasks.insert(index, removed);
      rethrow;
    }
    _emit();
  });

  /// Finds a current immutable task by BV/CID identity.
  Future<void> reconcileCompleted() => _command(() async {
    await _expireHistory();
    _scheduleRetention();
    final files = await library.loadDownloads();
    final ready = <(String, String?), (DateTime?,)>{
      for (final file in files)
        ('${file.bvid}:${file.cid}', file.cacheLocationId): (
          file.downloadedAt,
        ),
    };
    final courseFiles = await _courseFiles();
    for (final file in (courseFiles ?? const <CourseCacheEntry>[]).where(
      (file) => file.hasMedia,
    )) {
      ready[('course:${file.mid}:${file.id}', file.cacheLocationId)] = (null,);
    }
    final before = List<OfflineDownloadTask>.of(_tasks);
    final removed = <OfflineDownloadTask>{};
    final migrations = <OfflineDownloadTask, OfflineDownloadTask>{};
    final now = _clock();
    for (final task in before) {
      if (!_visible(task) ||
          task.status != DownloadTaskStatus.completed ||
          (task.courseMid != null && courseFiles == null)) {
        continue;
      }
      final file = ready[(task.id, task.cacheLocationId)];
      if (file == null) {
        if (await _locationAvailable(task)) removed.add(task);
      } else if (task.completedAt == null) {
        final upgraded = task.copyWith(completedAt: file.$1 ?? now);
        if (_historyExpired(upgraded, now)) {
          removed.add(task);
        } else {
          migrations[task] = upgraded;
        }
      }
    }
    if (removed.isEmpty && migrations.isEmpty) return;
    _tasks.removeWhere(removed.contains);
    for (var i = 0; i < _tasks.length; i++) {
      _tasks[i] = migrations[_tasks[i]] ?? _tasks[i];
    }
    try {
      await _save();
    } catch (_) {
      // Roll back only this command's rows, not unrelated transfer updates.
      for (var i = 0; i < before.length; i++) {
        final task = before[i];
        final replacement = migrations[task];
        if (removed.contains(task) && _find(task.id) == null) {
          _tasks.insert(i.clamp(0, _tasks.length), task);
        } else if (replacement != null &&
            identical(_find(task.id), replacement)) {
          _replace(task);
        }
      }
      rethrow;
    }
    _scheduleRetention();
    _emit();
  });

  /// Refreshes only the completed task rows matching deleted cache identities.
  ///
  /// Unlike task removal, this cannot interrupt transfers or discard partial
  /// bytes. A new download which already finished must keep its completed row.
  Future<void> reconcileDeleted(
    Set<String> ids, {
    int? expectedCourseAccountRevision,
  }) => _command(() async {
    if (ids.isEmpty) return;
    bool scopeIsCurrent() =>
        expectedCourseAccountRevision == null ||
        expectedCourseAccountRevision == CacheLifecycle.account.value;
    bool matches(OfflineDownloadTask task) =>
        ids.contains(task.id) &&
        (task.courseMid != null) == (expectedCourseAccountRevision != null) &&
        _visible(task) &&
        task.id != _activeId &&
        task.status == DownloadTaskStatus.completed;
    if (!scopeIsCurrent()) return;
    final candidates = _tasks.where(matches).toSet();
    if (candidates.isEmpty) return;

    final remaining = expectedCourseAccountRevision == null
        ? (await library.loadDownloads())
              .map((e) => '${e.bvid}:${e.cid}')
              .toSet()
        // Do not interpret unavailable private storage as an empty library.
        : (await courses.entries())
              .where((e) => e.hasMedia)
              .map((e) => 'course:${e.mid}:${e.id}')
              .toSet();
    if (!scopeIsCurrent()) return;

    final removed = <int, OfflineDownloadTask>{};
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (candidates.contains(task) &&
          matches(task) &&
          !remaining.contains(task.id)) {
        removed[i] = task;
      }
    }
    if (removed.isEmpty) return;
    for (final index in removed.keys.toList().reversed) {
      _tasks.removeAt(index);
    }
    try {
      await _save();
    } catch (_) {
      // Preserve status/progress changes made by an unrelated active task.
      for (final entry in removed.entries) {
        _tasks.insert(entry.key, entry.value);
      }
      rethrow;
    }
    _emit();
  });

  /// Finds a current immutable task by BV/CID identity.
  OfflineDownloadTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// Replaces a snapshot without changing FIFO order.
  void _replace(OfflineDownloadTask task) {
    final index = _tasks.indexWhere((e) => e.id == task.id);
    if (index >= 0) _tasks[index] = task;
  }

  /// Starts at most one transfer, allowing pause to release bandwidth to the next.
  void _pump() {
    if (_closing || _running != null || _storageError != null) return;
    final queued = _tasks.where(
      (e) => _visible(e) && e.status == DownloadTaskStatus.queued,
    );
    if (queued.isEmpty) return;
    final task = queued.first;
    final control = DownloadControl(
      requireExactQuality: task.requireExactQuality,
    );
    _activeId = task.id;
    _control = control;
    _running = _run(task, control);
    unawaited(
      _running!.then((_) {
        _running = null;
        _activeId = null;
        _control = null;
        _pump();
      }),
    );
  }

  /// Executes one task and makes every error a visible, retryable terminal state.
  Future<void> _run(OfflineDownloadTask task, DownloadControl control) async {
    _speedSampleBytes = null;
    _speedClock.reset();
    _speedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sampleSpeed(task.id),
    );
    _replace(task.copyWith(status: DownloadTaskStatus.downloading));
    _emit();
    try {
      await _save();
      final int bytes;
      if (task.courseMid != null) {
        void progress() {
          if (courses.activeId == task.courseEntryId &&
              !control.isInterrupted) {
            _onProgress(task.id, courses.received, courses.total);
          }
        }

        courses.addListener(progress);
        try {
          await courses.startQueued(
            task.video,
            task.part,
            quality: task.quality,
            control: control,
            expectedMid: task.courseMid!,
            cacheLocationId: task.cacheLocationId,
          );
          control.check();
          final file = await courseEntry(task.video, task.part);
          if (file == null || file.mid != task.courseMid) {
            throw const OfflineVideoException('无法找到已下载的课程。');
          }
          bytes = file.videoBytes + file.audioBytes;
        } finally {
          courses.removeListener(progress);
        }
      } else {
        final result = await library.download(
          task.video,
          part: task.part,
          quality: task.quality,
          control: control,
          cacheLocationId: task.cacheLocationId,
          onProgress: (received, total) =>
              _onProgress(task.id, received, total),
        );
        bytes = result.sizeBytes;
      }
      final completed = task.copyWith(
        status: DownloadTaskStatus.completed,
        completedAt: _clock(),
        receivedBytes: bytes,
        totalBytes: bytes,
      );
      _replace(completed);
      if (_visible(completed)) _completions.add(completed);
    } on DownloadInterrupted {
      final current = _find(task.id);
      if (current != null) {
        _replace(current.copyWith(status: DownloadTaskStatus.paused));
      }
    } catch (error) {
      final current = _find(task.id);
      if (current != null) {
        _replace(
          current.copyWith(
            status: DownloadTaskStatus.failed,
            error: switch (error) {
              OfflineVideoException() => error.message,
              OfflineCacheLocationException() => error.message,
              CourseCacheFailure() => error.message,
              CourseCacheAccessException() => error.message,
              _ => '下载失败，请检查网络后重试。',
            },
            courseDiagnostic: switch (error) {
              CourseCacheFailure() => error.diagnostic,
              CourseCacheAccessException() => error.diagnostic,
              _ => null,
            },
          ),
        );
      }
    } finally {
      _speedTimer?.cancel();
      _speedTimer = null;
      _speedClock.stop();
    }
    try {
      await _save();
    } catch (_) {
      // Keep the in-memory state and surface storageError; do not start more work.
    }
    _scheduleRetention();
    _emit();
  }

  /// Throttles UI/notification refreshes and saves progress at most once a second.
  void _onProgress(String id, int received, int? total) {
    final task = _find(id);
    if (task == null) return;
    if (_speedSampleBytes == null || received < task.receivedBytes) {
      // The first report includes resumed bytes already on disk, not network traffic.
      _speedSampleBytes = received;
      _speedClock
        ..reset()
        ..start();
    }
    _replace(task.copyWith(receivedBytes: received, totalBytes: total));
    final now = DateTime.now();
    if (now.difference(_lastProgress).inMilliseconds >= 250) {
      _lastProgress = now;
      _emit();
    }
    if (now.difference(_lastSavedProgress).inSeconds >= 1) {
      _lastSavedProgress = now;
      unawaited(_save().catchError((Object _) {}));
    }
  }

  /// Samples bytes on a monotonic clock; stalled transfers decay to zero each second.
  void _sampleSpeed(String id) {
    final task = _find(id);
    if (task == null ||
        task.status != DownloadTaskStatus.downloading ||
        _speedSampleBytes == null ||
        _speedClock.elapsedMicroseconds == 0) {
      return;
    }
    final delta = (task.receivedBytes - _speedSampleBytes!).clamp(
      0,
      task.receivedBytes,
    );
    final rate =
        delta *
        Duration.microsecondsPerSecond /
        _speedClock.elapsedMicroseconds;
    _speedSampleBytes = task.receivedBytes;
    _speedClock.reset();
    _replace(task.copyWith(bytesPerSecond: rate));
    _emit();
  }

  /// Retains only the newest waiting snapshot so slow OS calls cannot replay stale progress.
  void _emit() {
    notifyListeners();
    if (_publishProgress == null) return;
    _pendingNotification = tasks;
    if (_publishingNotification) return;
    _publishingNotification = true;
    _notifications = _drainNotifications();
  }

  /// Serializes native calls while coalescing intermediate byte updates and isolating OS errors.
  Future<void> _drainNotifications() async {
    try {
      while (_pendingNotification != null) {
        final snapshot = _pendingNotification!;
        _pendingNotification = null;
        try {
          await _publishProgress!(snapshot);
        } catch (_) {
          // Permission/platform failures never interrupt the actual transfer.
        }
      }
    } finally {
      _publishingNotification = false;
    }
  }

  /// Stops transfers and flushes queued writes before tests or application shutdown.
  Future<void> close() async {
    _retentionTimer?.cancel();
    await _commands;
    _closing = true;
    _retentionTimer?.cancel();
    CacheLifecycle.account.removeListener(_accountChanged);
    _control?.interrupt();
    await _running;
    await _writes;
    await _notifications;
    _speedTimer?.cancel();
    await _completions.close();
    dispose();
  }
}
