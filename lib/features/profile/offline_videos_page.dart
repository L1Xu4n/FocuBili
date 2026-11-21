import 'dart:async';
import '../../platform/app_platform.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/course_cache_library.dart';
import '../classroom/course_cache_playback_page.dart';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/widgets/drag_selection_region.dart';
import '../../models/offline_video_download.dart';
import '../../models/video_preview.dart';
import '../../services/offline_video_service.dart';
import '../../services/offline_download_queue.dart';
import '../../models/offline_download_task.dart';
import '../player/player_page.dart';
import 'download_queue_view.dart';
import 'offline_cache_location_dialog.dart';

/// 展示已下载到本机的离线视频，并提供播放、删除和清空管理。
class OfflineVideosPage extends StatefulWidget {
  /// 创建离线缓存页；服务可注入以支持测试和安全替换。
  const OfflineVideosPage({
    super.key,
    this.offlineVideoService,
    this.downloadQueue,
    this.initialQueue = false,
    this.includeCourses,
    this.playerBuilder,
  }) : _group = null;

  const OfflineVideosPage._parts({
    required OfflineVideoService this.offlineVideoService,
    required OfflineDownloadQueue this.downloadQueue,
    required _SavedParts group,
    required this.playerBuilder,
  }) : _group = group,
       includeCourses = false,
       initialQueue = false;

  final _SavedParts? _group;

  /// Optional wrapper around the configured offline route, allowing widget tests
  /// to inspect routing without initializing the native media backend.
  final Widget Function(PlayerPage player)? playerBuilder;
  final OfflineDownloadQueue? downloadQueue;
  final bool initialQueue;
  final bool? includeCourses;

  /// 可选的离线下载服务，未传入时使用设备默认实现。
  final OfflineVideoService? offlineVideoService;

  /// 创建管理离线列表读取、删除和打开播放器的状态对象。
  @override
  State<OfflineVideosPage> createState() => _OfflineVideosPageState();
}

class _SavedParts {
  _SavedParts(List<OfflineVideoDownload> downloads)
    : videos = List.of(downloads) {
    // Use another saved record’s metadata if an older record has none.
    final missing = {for (final video in downloads) video.cid};
    for (final video in downloads) {
      for (final part in video.parts) {
        if (part.pageNumber > 0 && missing.remove(part.cid)) {
          metadata[part.cid] = part;
        }
      }
      if (missing.isEmpty) break;
    }
    videos.sort((a, b) {
      final byPage = (part(a)?.pageNumber ?? 0x7fffffff).compareTo(
        part(b)?.pageNumber ?? 0x7fffffff,
      );
      return byPage != 0 ? byPage : a.cid.compareTo(b.cid);
    });
  }

  final List<OfflineVideoDownload> videos;
  final metadata = <int, VideoPart>{};

  String get bvid => videos.first.bvid;
  String get title => videos
      .map((video) => video.originalTitle.trim())
      .firstWhere(
        (title) => title.isNotEmpty,
        orElse: () => videos.first.title,
      );
  VideoPart? part(OfflineVideoDownload video) => metadata[video.cid];
}

class _CacheRow {
  const _CacheRow.video(OfflineVideoDownload this.video, [this.part])
    : course = null,
      group = null;
  const _CacheRow.course(CourseCacheEntry this.course)
    : video = null,
      group = null,
      part = null;
  const _CacheRow.group(_SavedParts this.group)
    : video = null,
      course = null,
      part = null;

  final OfflineVideoDownload? video;
  final CourseCacheEntry? course;
  final _SavedParts? group;
  final VideoPart? part;

  String get id => switch (this) {
    _CacheRow(:final video?) => '${video.bvid}:${video.cid}',
    _CacheRow(:final group?) => 'group:${group.bvid}',
    _ => 'course:${course!.mid}:${course!.id}',
  };

  static final _partNumber = RegExp(r'^(?:p\s*)?(\d+)$');

  bool matches(String query, {bool partsOnly = false}) {
    if (group case final group?) {
      return group.title.toLowerCase().contains(query) ||
          group.videos.any(
            (video) => _CacheRow.video(video, group.part(video)).matches(query),
          );
    }
    if (video case final video?) {
      final part =
          this.part ??
          video.parts.where((part) => part.cid == video.cid).firstOrNull;
      final partNumber = _partNumber.firstMatch(query);
      final numberMatches =
          partNumber != null &&
          part?.pageNumber == int.tryParse(partNumber[1]!);
      if (partsOnly) {
        return numberMatches ||
            (part?.title.trim().isNotEmpty == true ? part!.title : video.title)
                .toLowerCase()
                .contains(query);
      }
      return numberMatches ||
          '${video.originalTitle} ${video.title} ${video.ownerName} ${video.bvid} ${part?.title ?? ''}'
              .toLowerCase()
              .contains(query);
    }
    return '${course!.courseTitle} ${course!.chapterTitle}'
        .toLowerCase()
        .contains(query);
  }
}

/// 管理离线视频列表、占用空间统计和删除行为。
class _OfflineVideosPageState extends State<OfflineVideosPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final OfflineVideoService _offlineVideoService;
  List<OfflineVideoDownload> _downloads = const <OfflineVideoDownload>[];
  List<_CacheRow> _videoRows = const [];
  bool _isLoading = true;
  int _totalSizeBytes = 0;
  late final OfflineDownloadQueue _queue;
  String _query = '';
  String _completedIds = '';
  late final TabController _tabs;
  late bool _showingLibrary;
  final _listController = ScrollController();
  final _selectedIds = <String>{};
  bool _selecting = false, _batchBusy = false;
  int _downloadGeneration = 0, _courseScopeEpoch = 0;

  bool get _inGroup => widget._group != null;
  bool get _showSelection => _selecting && _showingLibrary;
  String get _needle => _query.trim().toLowerCase();
  Iterable<_CacheRow> get _inventory sync* {
    yield* _videoRows;
    yield* _courseEntries.map(_CacheRow.course);
  }

  Iterable<_CacheRow> _makeVideoRows(
    List<OfflineVideoDownload> downloads,
  ) sync* {
    final byBvid = <String, List<OfflineVideoDownload>>{};
    for (final video in downloads) {
      (byBvid[video.bvid] ??= []).add(video);
    }
    for (final videos in byBvid.values) {
      final parts = _SavedParts(videos);
      if (!_inGroup && videos.length > 1) {
        yield _CacheRow.group(parts);
      } else {
        for (final video in parts.videos) {
          yield _CacheRow.video(video, parts.part(video));
        }
      }
    }
  }

  bool _matches(_CacheRow row, String query) =>
      row.matches(query, partsOnly: _inGroup);

  int get _hiddenSelectionCount {
    final needle = _needle;
    if (needle.isEmpty || _selectedIds.isEmpty) return 0;
    return _inventory
        .where((row) => _selectedIds.contains(row.id) && !_matches(row, needle))
        .fold<int>(0, (sum, row) => sum + (row.group?.videos.length ?? 1));
  }

  late final CourseCacheLibrary _courses;
  late final bool _includeCourses;
  List<CourseCacheEntry> _courseEntries = const [];
  int _courseGeneration = 0, _courseListVersion = -1;
  bool _courseSuspended = false;
  String? _openingCourse;
  Timer? _expiry;
  final _needsRecheck = <String, DateTime?>{};
  int get _itemCount => _downloads.length + _courseEntries.length;
  int get _courseSize =>
      _courseEntries.fold(0, (sum, e) => sum + e.videoBytes + e.audioBytes);

  /// 创建页面服务并在首次进入时读取一次本机离线列表。
  @override
  void initState() {
    super.initState();
    _showingLibrary = !widget.initialQueue;
    _tabs = TabController(
      length: 2,
      initialIndex: widget.initialQueue ? 1 : 0,
      vsync: this,
    )..addListener(_tabChanged);
    _offlineVideoService = widget.offlineVideoService ?? OfflineVideoService();
    _queue = widget.downloadQueue ?? OfflineDownloadQueue.instance;
    final platform = AppPlatformDetector.current;
    _includeCourses =
        widget.includeCourses ??
        (platform == AppPlatform.android || platform == AppPlatform.windows);
    if (_includeCourses) {
      _courses = _queue.courses;
      WidgetsBinding.instance.addObserver(this);
      CacheLifecycle.account.addListener(_courseAccountChanged);
      _courses.addListener(_courseChanged);
      unawaited(_loadCourses());
    }
    _queue.addListener(_queueChanged);
    unawaited(_initializeQueue());
    unawaited(_loadDownloads());
  }

  /// Loads durable tasks without treating unavailable queue storage as an empty queue.
  Future<void> _initializeQueue() async {
    try {
      await _queue.initialize();
    } catch (_) {
      if (mounted) _showMessage('下载队列读取失败，原始记录已保留。');
    }
  }

  /// Reloads the library only when finished identities change, not on each byte update.
  void _queueChanged() {
    final ids = _queue.tasks
        .where((e) => e.status == DownloadTaskStatus.completed)
        .map((e) => e.id)
        .join(',');
    if (ids != _completedIds) {
      _completedIds = ids;
      unawaited(_loadDownloads());
    }
  }

  void _tabChanged() {
    final library = _tabs.index == 0;
    if (_showingLibrary != library) {
      setState(() => _showingLibrary = library);
    }
  }

  /// Releases page listeners but deliberately leaves the shared queue running.
  @override
  void dispose() {
    if (_includeCourses) {
      WidgetsBinding.instance.removeObserver(this);
      CacheLifecycle.account.removeListener(_courseAccountChanged);
      _courses.removeListener(_courseChanged);
    }
    _expiry?.cancel();
    _tabs
      ..removeListener(_tabChanged)
      ..dispose();
    _listController.dispose();
    _queue.removeListener(_queueChanged);
    super.dispose();
  }

  void _courseChanged() {
    if (!_courseSuspended && _courseListVersion != _courses.listVersion) {
      unawaited(_loadCourses());
    }
  }

  void _hideCourses() {
    _courseGeneration++;
    _courseScopeEpoch++;
    _expiry?.cancel();
    setState(() {
      _courseEntries = const [];
      _pruneSelection();
      _needsRecheck.clear();
      _openingCourse = null;
    });
  }

  void _courseAccountChanged() {
    _hideCourses();
    if (!_courseSuspended) unawaited(_loadCourses());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _courseSuspended = true;
      _hideCourses();
    } else if (state == AppLifecycleState.resumed && _courseSuspended) {
      _courseSuspended = false;
      unawaited(_loadCourses());
    }
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    final waits =
        _courseEntries
            .where(_courses.isUsable)
            .map(_courses.untilExpiry)
            .whereType<Duration>()
            .where((wait) => wait > Duration.zero)
            .toList()
          ..sort();
    if (waits.isEmpty) return;
    _expiry = Timer(waits.first, () {
      if (!mounted || _courseSuspended) return;
      setState(() {});
      _scheduleExpiry();
    });
  }

  Future<void> _loadCourses() async {
    if (!_includeCourses || _courseSuspended) return;
    final generation = ++_courseGeneration;
    _courseListVersion = _courses.listVersion;
    try {
      final mid = await _courses.access.currentLocalMid();
      if (!mounted || generation != _courseGeneration) return;
      final rows = mid == null
          ? const <CourseCacheEntry>[]
          : (await _courses.entries())
                .where((e) => e.hasMedia && e.mid == mid)
                .toList();
      if (!mounted || generation != _courseGeneration) return;
      setState(() {
        _courseEntries = rows;
        _pruneSelection();
        _needsRecheck.removeWhere(
          (id, checked) =>
              rows.where((e) => e.id == id).firstOrNull?.checkedAt != checked,
        );
      });
      _scheduleExpiry();
    } catch (_) {
      if (mounted && generation == _courseGeneration) {
        setState(() {
          _courseEntries = const [];
          _pruneSelection();
        });
        _showMessage('无法读取本账号的部分离线缓存，请下拉重试。');
      }
    }
  }

  Future<void> _refresh() =>
      Future.wait<void>([_loadDownloads(), _loadCourses()]);

  Future<void> _openCourse(CourseCacheEntry entry) async {
    if (_openingCourse != null) return;
    final rev = CacheLifecycle.account.value;
    bool valid() =>
        mounted && !_courseSuspended && rev == CacheLifecycle.account.value;
    setState(() => _openingCourse = entry.id);
    try {
      if (!_courses.isUsable(entry) || _needsRecheck.containsKey(entry.id)) {
        final task = await _queue.enqueue(
          entry.video,
          part: entry.part,
          quality: entry.quality,
          expectedAccountRevision: rev,
          revalidateCourse: true,
        );
        if (task.status == DownloadTaskStatus.failed ||
            task.status == DownloadTaskStatus.paused) {
          await _queue.resume(task.id);
        }
        if (valid()) _showMessage('已加入下载队列');
        return;
      }
      final opened = await _courses.open(entry);
      if (!mounted || !valid()) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              CourseCachePlaybackPage(library: _courses, entry: opened.entry),
        ),
      );
    } on CourseCacheFailure catch (error) {
      if (valid()) {
        if (error.recheckNeeded) {
          setState(() => _needsRecheck[entry.id] = entry.checkedAt);
        }
        _showMessage(error.message);
      }
    } catch (_) {
      if (valid()) _showMessage('离线操作失败，请稍后重试。');
    } finally {
      if (valid()) setState(() => _openingCourse = null);
    }
  }

  Future<void> _deleteCourse(CourseCacheEntry entry) async {
    final rev = CacheLifecycle.account.value;
    if (!await _confirmDelete(entry.courseTitle) ||
        !mounted ||
        _courseSuspended ||
        rev != CacheLifecycle.account.value) {
      return;
    }
    try {
      await _courses.remove(entry);
      await _loadCourses();
      await _queue.reconcileCompleted();
      if (mounted && rev == CacheLifecycle.account.value) {
        _showMessage('已删除离线缓存');
      }
    } on CourseCacheFailure catch (error) {
      if (mounted && rev == CacheLifecycle.account.value) {
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted && rev == CacheLifecycle.account.value) {
        _showMessage('删除失败，请稍后重试。');
      }
    }
  }

  Future<bool> _confirmDelete(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除离线视频'),
          content: Text('将删除“$title”的离线缓存，且无法恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ==
      true;

  /// 读取离线列表并统计占用空间，失败时保留上一次成功显示的数据。
  Future<void> _loadDownloads() async {
    final generation = ++_downloadGeneration;
    try {
      final all = await _offlineVideoService.loadDownloads();
      final group = widget._group;
      final downloads = group == null
          ? List<OfflineVideoDownload>.of(all)
          : all.where((video) => video.bvid == group.bvid).toList();
      final totalSizeBytes = group == null
          ? await _offlineVideoService.totalSizeBytes()
          : downloads.fold<int>(0, (sum, video) => sum + video.sizeBytes);
      if (!mounted || generation != _downloadGeneration) return;
      setState(() {
        _isLoading = false;
        _downloads = downloads;
        _videoRows = _makeVideoRows(downloads).toList();
        _totalSizeBytes = totalSizeBytes;
        _pruneSelection();
      });
    } catch (_) {
      if (mounted && generation == _downloadGeneration) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  Future<void> _openGroup(_SavedParts group) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OfflineVideosPage._parts(
          offlineVideoService: _offlineVideoService,
          downloadQueue: _queue,
          group: group,
          playerBuilder: widget.playerBuilder,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  /// 打开离线播放页，返回后刷新列表。
  Future<void> _playDownload(OfflineVideoDownload download) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) {
          final player = PlayerPage(
            video: download.toPreview(),
            initialPartCid: download.cid,
            forceOffline: true,
            offlineVideoService: _offlineVideoService,
            downloadQueue: _queue,
          );
          return widget.playerBuilder?.call(player) ?? player;
        },
      ),
    );
    if (mounted) await _loadDownloads();
  }

  /// 确认后删除一条离线视频。
  Future<void> _deleteDownload(
    OfflineVideoDownload download,
    String title,
  ) async {
    try {
      if (!await _confirmDelete(title) || !mounted) return;
      final bool deleted = await _offlineVideoService.delete(
        download.bvid,
        cid: download.cid,
      );
      if (!mounted) {
        return;
      }
      if (!deleted) {
        _showMessage('删除失败，请稍后重试。');
        return;
      }
      var queueSynced = true;
      try {
        // Cache management must never cancel an active or paused download.
        await _queue.reconcileDeleted({'${download.bvid}:${download.cid}'});
      } catch (_) {
        queueSynced = false;
      }
      await _loadDownloads();
      if (mounted) {
        _showMessage(queueSynced ? '已删除离线缓存' : '已删除离线缓存，下载队列未能同步。');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  void _pruneSelection() =>
      _selectedIds.retainAll(_inventory.map((row) => row.id).toSet());

  void _beginSelection([String? id]) {
    if (!_showingLibrary || _selecting || _batchBusy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selecting = true;
      if (id != null) _selectedIds.add(id);
    });
  }

  void _endSelection() {
    if (_batchBusy || !_selecting) return;
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _setChecked(String id, bool value) {
    if (value) {
      _selectedIds.add(id);
    } else {
      _selectedIds.remove(id);
    }
  }

  void _selectRange(DragSelectionUpdate change, List<_CacheRow> visible) {
    if (!_showSelection || _batchBusy) return;
    final previous = change.previous, current = change.current;
    final start = previous < current ? previous : current;
    final end = previous > current ? previous : current;
    setState(() {
      for (var i = start; i <= end; i++) {
        _setChecked(visible[i].id, change.checked);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (!_showSelection || _batchBusy || _selectedIds.isEmpty) return;
    final selectedRows = _inventory
        .where((row) => _selectedIds.contains(row.id))
        .toList();
    if (selectedRows.isEmpty) return;
    final groups = selectedRows.where((row) => row.group != null).length;
    // Capture exact CIDs before confirmation, never expand again after a queue update.
    final chosen = [
      for (final row in selectedRows)
        if (row.group case final group?)
          ...group.videos.map(_CacheRow.video)
        else
          row,
    ];
    final hidden = _hiddenSelectionCount;
    final account = CacheLifecycle.account.value;
    final courseScope = _courseScopeEpoch;
    bool courseIsCurrent() =>
        mounted &&
        !_courseSuspended &&
        courseScope == _courseScopeEpoch &&
        account == CacheLifecycle.account.value;

    setState(() => _batchBusy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除所选离线缓存'),
          content: Text(
            '将删除本机的 ${chosen.length} 条所选缓存，且无法恢复。'
            '${groups > 0 ? '\n包括 $groups 个分P组当前已选中的全部缓存。' : ''}'
            '${hidden > 0 ? '\n其中 $hidden 条不在当前搜索结果中。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirm-delete-offline-selection'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final removedVideos = <String>{};
      final removedCourses = <String>{};
      String? failure;
      for (final row in chosen) {
        if (!mounted) return;
        try {
          final video = row.video;
          if (video != null) {
            if (!await _offlineVideoService.delete(
              video.bvid,
              cid: video.cid,
            )) {
              failure ??= '部分缓存已不存在。';
              continue;
            }
            removedVideos.add(row.id);
          } else {
            if (!courseIsCurrent()) {
              failure ??= '账号或页面状态已变化，未继续删除课程缓存。';
              continue;
            }
            // The library rechecks account and busy state before touching bytes.
            await _courses.remove(row.course!);
            removedCourses.add(row.id);
          }
        } on CourseCacheFailure catch (error) {
          failure ??= courseIsCurrent()
              ? error.message
              : '账号或页面状态已变化，未继续删除课程缓存。';
        } on OfflineVideoException catch (error) {
          failure ??= error.message;
        } catch (_) {
          failure ??= '部分缓存操作失败，请重试。';
        }
      }

      var queueSyncFailed = false;
      try {
        if (removedVideos.isNotEmpty) {
          await _queue.reconcileDeleted(removedVideos);
        }
        if (removedCourses.isNotEmpty && courseIsCurrent()) {
          await _queue.reconcileDeleted(
            removedCourses,
            expectedCourseAccountRevision: account,
          );
        }
      } catch (_) {
        queueSyncFailed = true;
      }
      if (!mounted) return;

      await _refresh();
      if (!mounted) return;
      setState(() {
        _selectedIds.removeAll(removedVideos);
        _selectedIds.removeAll(removedCourses);
        for (final row in selectedRows) {
          final group = row.group;
          if (group != null &&
              group.videos.every(
                (video) => removedVideos.contains(_CacheRow.video(video).id),
              )) {
            _selectedIds.remove(row.id);
          }
        }
        if (_selectedIds.isEmpty) _selecting = false;
      });
      final removed = removedVideos.length + removedCourses.length;
      final skipped = chosen.length - removed;
      _showMessage(
        '已删除 $removed 条离线缓存'
        '${skipped > 0 ? '，$skipped 条未删除。 ${failure ?? ''}' : '。'}'
        '${queueSyncFailed ? ' 下载队列未能同步，请稍后重试。' : ''}',
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 确认后清空全部离线缓存。
  Future<void> _clearAll() async {
    try {
      if (_itemCount == 0) return;
      final revision = CacheLifecycle.account.value;
      final courses = List<CourseCacheEntry>.of(_courseEntries);
      final hadVideos = _downloads.isNotEmpty;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('清空离线缓存'),
          content: Text('将删除当前列表的 $_itemCount 条离线缓存，且无法恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清空'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
      if (courses.isNotEmpty &&
          (revision != CacheLifecycle.account.value || _courseSuspended)) {
        return;
      }
      if (courses.isNotEmpty && _courses.busy) {
        _showMessage('下载还在进行，请暂停后再清空。');
        return;
      }
      final bool cleared = !hadVideos || await _offlineVideoService.clearAll();
      if (cleared) {
        for (final course in courses) {
          if (revision != CacheLifecycle.account.value || _courseSuspended) {
            break;
          }
          await _courses.remove(course);
        }
      }
      await _queue.reconcileCompleted();
      if (!mounted) {
        return;
      }
      if (!cleared) {
        _showMessage('清空失败，请稍后重试。');
        return;
      }
      await _refresh();
      if (mounted && revision == CacheLifecycle.account.value) {
        _showMessage('已清空离线缓存');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 把字节数格式化为人类可读的大小文本。
  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// 显示统一持续三秒的轻量提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 创建封面缩略图，失败时显示固定占位图标。
  Widget _buildThumbnail(String coverUrl) {
    return SizedBox(
      width: 112,
      height: 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: coverUrl.isEmpty
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.offline_pin_rounded),
              )
            : AppNetworkImage(
                imageUrl: coverUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 256,
                placeholder: (BuildContext context, String url) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                errorWidget: (BuildContext context, String url, Object error) =>
                    ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
              ),
      ),
    );
  }

  /// 创建单个离线视频卡片，点击进入播放器并提供删除入口。
  Widget _buildDownloadCard(
    OfflineVideoDownload video,
    VideoPart? part,
    String selectionId,
    Key handleKey,
  ) => _buildCacheCard(
    selectionId: selectionId,
    handleKey: handleKey,
    id: '${video.bvid}-${video.cid}',
    title: _inGroup
        ? (part?.title.trim().isNotEmpty == true ? part!.title : video.title)
        : video.title,
    subtitle: _inGroup
        ? (part == null ? '分P编号未知' : 'P${part.pageNumber}')
        : video.ownerName,
    detail: _inGroup ? '' : video.partLabel,
    summary: '${video.qualityLabel} · ${_formatBytes(video.sizeBytes)}',
    coverUrl: video.coverUrl,
    open: () => unawaited(_playDownload(video)),
    remove: () => unawaited(
      _deleteDownload(
        video,
        _inGroup && part != null
            ? 'P${part.pageNumber} ${part.title.trim().isEmpty ? video.title : part.title}'
            : video.title,
      ),
    ),
  );

  Widget _buildGroupCard(_SavedParts group, Key handleKey) {
    final cover = group.videos.firstWhere(
      (video) => video.coverUrl.isNotEmpty,
      orElse: () => group.videos.first,
    );
    return _buildCacheCard(
      id: 'group-${group.bvid}',
      selectionId: 'group:${group.bvid}',
      handleKey: handleKey,
      title: group.title,
      subtitle: cover.ownerName,
      detail: '',
      summary:
          '${group.videos.length} P 已缓存 · ${_formatBytes(group.videos.fold<int>(0, (sum, video) => sum + video.sizeBytes))}',
      coverUrl: cover.coverUrl,
      open: () => unawaited(_openGroup(group)),
      remove: null,
    );
  }

  Widget _buildCourseCard(
    CourseCacheEntry entry,
    String selectionId,
    Key handleKey,
  ) => _buildCacheCard(
    selectionId: selectionId,
    handleKey: handleKey,
    id: 'course-${entry.id}',
    title: entry.courseTitle,
    subtitle: '课程',
    detail: entry.chapterTitle,
    summary: _courses.isUsable(entry) && !_needsRecheck.containsKey(entry.id)
        ? _formatBytes(entry.videoBytes + entry.audioBytes)
        : '需联网复核',
    coverUrl: '',
    open: _openingCourse == null ? () => unawaited(_openCourse(entry)) : null,
    remove: () => unawaited(_deleteCourse(entry)),
  );

  Widget _buildCacheCard({
    required String id,
    required String selectionId,
    required Key handleKey,
    required String title,
    required String subtitle,
    required String detail,
    required String summary,
    required String coverUrl,
    required VoidCallback? open,
    required VoidCallback? remove,
  }) {
    final checked = _selectedIds.contains(selectionId);
    void change(bool value) {
      if (_showSelection && !_batchBusy) {
        setState(() => _setChecked(selectionId, value));
      }
    }

    return Card(
      key: Key('offline-video-$id'),
      color: checked ? Theme.of(context).colorScheme.secondaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _batchBusy
            ? null
            : _selecting
            ? () => change(!checked)
            : open,
        onLongPress: _selecting || _batchBusy
            ? null
            : () => _beginSelection(selectionId),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              _buildThumbnail(coverUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    Text(summary, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (_selecting)
                Tooltip(
                  message: '长按勾选框后滑动，快速选择',
                  triggerMode: TooltipTriggerMode.manual,
                  child: Checkbox(
                    key: handleKey,
                    value: checked,
                    semanticLabel: '选中 $title $detail',
                    onChanged: _batchBusy
                        ? null
                        : (value) => change(value == true),
                  ),
                )
              else if (remove == null)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.chevron_right_rounded),
                )
              else
                IconButton(
                  key: Key('delete-offline-video-$id'),
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: _batchBusy ? null : remove,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 根据加载状态和空数据创建页面主体。
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_itemCount == 0) {
      return Center(
        key: const Key('offline-videos-empty'),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.offline_pin_outlined, size: 44),
                const SizedBox(height: 12),
                Text(_inGroup ? '这个视频没有已缓存的分P' : '还没有离线缓存'),
                if (!_inGroup) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '在看视频时点击下载，即可在无网络时播放',
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    final visible = _inventory.where((row) => _matches(row, _needle)).toList();
    if (visible.isEmpty) {
      return const Center(child: Text('没有匹配的离线视频'));
    }
    return DragSelectionRegion(
      // A changed search or inventory must not reuse a stale drag anchor.
      key: ValueKey(visible.map((row) => row.id).join('\u0000')),
      controller: _listController,
      itemCount: visible.length,
      enabled: _showSelection && !_batchBusy,
      checkedAt: (index) => _selectedIds.contains(visible[index].id),
      onDragUpdate: (change) => _selectRange(change, visible),
      builder: (context, dragging) => RefreshIndicator(
        onRefresh: _refresh,
        child: AdaptiveTwoColumnList(
          key: const Key('offline-videos-list'),
          controller: _listController,
          physics: dragging
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: visible.length,
          mainAxisSpacing: 8,
          itemBuilder: (context, index) {
            final row = visible[index];
            return DragSelectionTarget(
              key: ValueKey(row.id),
              index: index,
              builder: (context, handleKey) => row.group != null
                  ? _buildGroupCard(row.group!, handleKey)
                  : row.video != null
                  ? _buildDownloadCard(row.video!, row.part, row.id, handleKey)
                  : _buildCourseCard(row.course!, row.id, handleKey),
            );
          },
        ),
      ),
    );
  }

  /// 创建离线缓存页标题、清空入口和内容区域。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showSelection,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showSelection) _endSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _showSelection
                ? '已选 ${_selectedIds.length}'
                : widget._group?.title ?? '离线缓存',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          bottom: _inGroup
              ? null
              : TabBar(
                  controller: _tabs,
                  tabs: const [
                    Tab(text: '已缓存'),
                    Tab(text: '下载队列'),
                  ],
                ),
          actions: <Widget>[
            if (!_inGroup &&
                !_showSelection &&
                _queue.library.cacheLocations.supported)
              IconButton(
                key: const Key('offline-cache-location'),
                tooltip: '离线缓存位置',
                onPressed: _batchBusy
                    ? null
                    : () => unawaited(
                        showOfflineCacheLocationDialog(
                          context,
                          _queue.library.cacheLocations,
                        ).then((_) {
                          if (mounted) unawaited(_refresh());
                        }),
                      ),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            if (_showSelection) ...[
              IconButton(
                key: const Key('exit-offline-selection'),
                tooltip: '结束多选',
                onPressed: _batchBusy ? null : _endSelection,
                icon: const Icon(Icons.close_rounded),
              ),
              IconButton(
                key: const Key('delete-selected-offline-videos'),
                tooltip: '删除所选',
                onPressed: _batchBusy || _selectedIds.isEmpty
                    ? null
                    : () => unawaited(_deleteSelected()),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ] else if (_showingLibrary && _itemCount != 0) ...[
              IconButton(
                key: const Key('start-offline-selection'),
                tooltip: '多选管理',
                onPressed: _batchBusy ? null : _beginSelection,
                icon: const Icon(Icons.checklist_rounded),
              ),
              if (!_inGroup)
                IconButton(
                  key: const Key('clear-offline-videos'),
                  tooltip: '清空全部',
                  onPressed: _batchBusy ? null : () => unawaited(_clearAll()),
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
            ],
          ],
        ),
        body: AdaptivePageFrame(
          maxWidth: 1180,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: <Widget>[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .45,
                  ),
                  child: SingleChildScrollView(
                    key: const Key('offline-toolbar-scroll'),
                    child: Column(
                      children: [
                        _buildToolbar(),
                        ListenableBuilder(
                          listenable: _queue,
                          builder: (context, _) => _queue.storageError == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    0,
                                  ),
                                  child: Text(
                                    _queue.storageError!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _inGroup
                      ? _buildBody()
                      : TabBarView(
                          controller: _tabs,
                          children: [
                            _buildBody(),
                            DownloadQueueView(queue: _queue, query: _query),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 宽窗口合并搜索和空间摘要，窄窗口自然分行；工具区可滚动以给矮窗口保留列表高度。
  Widget _buildToolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final search = TextField(
          key: const Key('offline-search'),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: _inGroup ? '搜索分P名称或编号' : '搜索离线视频或下载任务',
          ),
          onChanged: (value) => setState(() => _query = value),
        );
        final hidden = _showSelection ? _hiddenSelectionCount : 0;
        final summary = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showSelection
                  ? Icons.checklist_rounded
                  : Icons.offline_pin_rounded,
              size: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                hidden > 0
                    ? '所选中有 $hidden 条不在搜索结果中'
                    : _showSelection
                    ? '长按勾选框后滑动，可连续勾选或取消'
                    : '共 $_itemCount 条 · ${_formatBytes(_totalSizeBytes + _courseSize)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
        if (constraints.maxWidth >= 640) {
          return Row(
            children: [
              Expanded(flex: 3, child: search),
              const SizedBox(width: 24),
              Flexible(child: summary),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [search, const SizedBox(height: 12), summary],
        );
      },
    ),
  );
}
