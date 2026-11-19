import 'dart:async';
import '../../platform/app_platform.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/course_cache_library.dart';
import '../classroom/course_cache_playback_page.dart';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/offline_video_download.dart';
import '../../services/offline_video_service.dart';
import '../../services/offline_download_queue.dart';
import '../../models/offline_download_task.dart';
import '../player/player_page.dart';
import 'download_queue_view.dart';

/// 展示已下载到本机的离线视频，并提供播放、删除和清空管理。
class OfflineVideosPage extends StatefulWidget {
  /// 创建离线缓存页；服务可注入以支持测试和安全替换。
  const OfflineVideosPage({
    super.key,
    this.offlineVideoService,
    this.downloadQueue,
    this.initialQueue = false,
    this.includeCourses,
  });
  final OfflineDownloadQueue? downloadQueue;
  final bool initialQueue;
  final bool? includeCourses;

  /// 可选的离线下载服务，未传入时使用设备默认实现。
  final OfflineVideoService? offlineVideoService;

  /// 创建管理离线列表读取、删除和打开播放器的状态对象。
  @override
  State<OfflineVideosPage> createState() => _OfflineVideosPageState();
}

/// 管理离线视频列表、占用空间统计和单条删除行为。
class _OfflineVideosPageState extends State<OfflineVideosPage>
    with WidgetsBindingObserver {
  late final OfflineVideoService _offlineVideoService;
  List<OfflineVideoDownload> _downloads = const <OfflineVideoDownload>[];
  bool _isLoading = true;
  int _totalSizeBytes = 0;
  late final OfflineDownloadQueue _queue;
  String _query = '';
  String _completedIds = '';
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
    _offlineVideoService = widget.offlineVideoService ?? OfflineVideoService();
    _queue = widget.downloadQueue ?? OfflineDownloadQueue.instance;
    _courses = _queue.courses;
    final platform = AppPlatformDetector.current;
    _includeCourses =
        widget.includeCourses ??
        (platform == AppPlatform.android || platform == AppPlatform.windows);
    if (_includeCourses) {
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

  /// Releases page listeners but deliberately leaves the shared queue running.
  @override
  void dispose() {
    if (_includeCourses) {
      WidgetsBinding.instance.removeObserver(this);
      CacheLifecycle.account.removeListener(_courseAccountChanged);
      _courses.removeListener(_courseChanged);
    }
    _expiry?.cancel();
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
    _expiry?.cancel();
    setState(() {
      _courseEntries = const [];
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
      if (await _courses.access.currentLocalMid() == null) return;
      final rows = (await _courses.entries()).where((e) => e.hasMedia).toList();
      if (!mounted || generation != _courseGeneration) return;
      setState(() {
        _courseEntries = rows;
        _needsRecheck.removeWhere(
          (id, checked) =>
              rows.where((e) => e.id == id).firstOrNull?.checkedAt != checked,
        );
      });
      _scheduleExpiry();
    } catch (_) {
      if (mounted && generation == _courseGeneration) {
        setState(() => _courseEntries = const []);
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
    try {
      final List<OfflineVideoDownload> downloads = await _offlineVideoService
          .loadDownloads();
      final int totalSizeBytes = await _offlineVideoService.totalSizeBytes();
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _downloads = downloads;
        _totalSizeBytes = totalSizeBytes;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 打开离线播放页，返回后保留当前列表。
  Future<void> _playDownload(OfflineVideoDownload download) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlayerPage(
          video: download.toPreview(),
          initialPartCid: download.cid,
          forceOffline: true,
          offlineVideoService: _offlineVideoService,
          downloadQueue: _queue,
        ),
      ),
    );
  }

  /// 确认后删除一条离线视频。
  Future<void> _deleteDownload(OfflineVideoDownload download) async {
    try {
      if (!await _confirmDelete(download.title) || !mounted) return;
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
      await _queue.remove('${download.bvid}:${download.cid}');
      await _loadDownloads();
      _showMessage('已删除离线缓存');
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
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
  Widget _buildDownloadCard(OfflineVideoDownload video) => _buildCacheCard(
    id: '${video.bvid}-${video.cid}',
    title: video.title,
    subtitle: video.ownerName,
    detail: video.partLabel,
    summary: '${video.qualityLabel} · ${_formatBytes(video.sizeBytes)}',
    coverUrl: video.coverUrl,
    open: () => unawaited(_playDownload(video)),
    remove: () => unawaited(_deleteDownload(video)),
  );

  Widget _buildCourseCard(CourseCacheEntry entry) => _buildCacheCard(
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
    required String title,
    required String subtitle,
    required String detail,
    required String summary,
    required String coverUrl,
    required VoidCallback? open,
    required VoidCallback remove,
  }) {
    return Card(
      key: Key('offline-video-$id'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
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
                    Text(detail, style: Theme.of(context).textTheme.bodySmall),
                    Text(summary, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                key: Key('delete-offline-video-$id'),
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: remove,
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
      return const Center(
        key: Key('offline-videos-empty'),
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.offline_pin_outlined, size: 44),
                SizedBox(height: 12),
                Text('还没有离线缓存'),
                SizedBox(height: 6),
                Text('在看视频时点击下载，即可在无网络时播放', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }
    final needle = _query.trim().toLowerCase();
    final visible = _downloads
        .where(
          (e) => '${e.title} ${e.ownerName} ${e.bvid}'.toLowerCase().contains(
            needle,
          ),
        )
        .toList();
    final visibleCourses = _courseEntries
        .where(
          (e) => '${e.courseTitle} ${e.chapterTitle}'.toLowerCase().contains(
            needle,
          ),
        )
        .toList();
    if (visible.isEmpty && visibleCourses.isEmpty) {
      return const Center(child: Text('没有匹配的离线视频'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: AdaptiveTwoColumnList(
        key: const Key('offline-videos-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: visible.length + visibleCourses.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          return index < visible.length
              ? _buildDownloadCard(visible[index])
              : _buildCourseCard(visibleCourses[index - visible.length]);
        },
      ),
    );
  }

  /// 创建离线缓存页标题、清空入口和内容区域。
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialQueue ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('离线缓存'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '已缓存'),
              Tab(text: '下载队列'),
            ],
          ),
          actions: <Widget>[
            if (_itemCount != 0)
              IconButton(
                key: const Key('clear-offline-videos'),
                tooltip: '清空全部',
                onPressed: () => unawaited(_clearAll()),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
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
                  child: TabBarView(
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
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索离线视频或下载任务',
          ),
          onChanged: (value) => setState(() => _query = value),
        );
        final summary = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.offline_pin_rounded, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '共 $_itemCount 条 · ${_formatBytes(_totalSizeBytes + _courseSize)}',
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
