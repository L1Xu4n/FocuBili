import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
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
  });
  final OfflineDownloadQueue? downloadQueue;
  final bool initialQueue;

  /// 可选的离线下载服务，未传入时使用设备默认实现。
  final OfflineVideoService? offlineVideoService;

  /// 创建管理离线列表读取、删除和打开播放器的状态对象。
  @override
  State<OfflineVideosPage> createState() => _OfflineVideosPageState();
}

/// 管理离线视频列表、占用空间统计和单条删除行为。
class _OfflineVideosPageState extends State<OfflineVideosPage> {
  late final OfflineVideoService _offlineVideoService;
  List<OfflineVideoDownload> _downloads = const <OfflineVideoDownload>[];
  bool _isLoading = true;
  int _totalSizeBytes = 0;
  late final OfflineDownloadQueue _queue;
  String _query = '';
  String _completedIds = '';

  /// 创建页面服务并在首次进入时读取一次本机离线列表。
  @override
  void initState() {
    super.initState();
    _offlineVideoService = widget.offlineVideoService ?? OfflineVideoService();
    _queue = widget.downloadQueue ?? OfflineDownloadQueue.instance;
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
    _queue.removeListener(_queueChanged);
    super.dispose();
  }

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
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('删除离线视频'),
          content: Text('将删除“${download.title}”的离线缓存，且无法恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
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
      if (_downloads.isEmpty) {
        return;
      }
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('清空离线缓存'),
          content: Text('将删除全部 ${_downloads.length} 条离线视频，且无法恢复。'),
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
      final bool cleared = await _offlineVideoService.clearAll();
      await _queue.reconcileCompleted();
      if (!mounted) {
        return;
      }
      if (!cleared) {
        _showMessage('清空失败，请稍后重试。');
        return;
      }
      await _loadDownloads();
      _showMessage('已清空离线缓存');
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
  Widget _buildThumbnail(OfflineVideoDownload download) {
    return SizedBox(
      width: 112,
      height: 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: download.coverUrl.isEmpty
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.offline_pin_rounded),
              )
            : CachedNetworkImage(
                imageUrl: download.coverUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 256,
                maxWidthDiskCache: 512,
                fadeInDuration: const Duration(milliseconds: 120),
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
  Widget _buildDownloadCard(OfflineVideoDownload download) {
    return Card(
      key: Key('offline-video-${download.bvid}-${download.cid}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _playDownload(download),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              _buildThumbnail(download),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      download.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      download.ownerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      download.partLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '${download.qualityLabel} · ${_formatBytes(download.sizeBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key(
                  'delete-offline-video-${download.bvid}-${download.cid}',
                ),
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => unawaited(_deleteDownload(download)),
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
    if (_downloads.isEmpty) {
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
    if (visible.isEmpty) return const Center(child: Text('没有匹配的离线视频'));
    return RefreshIndicator(
      onRefresh: _loadDownloads,
      child: AdaptiveTwoColumnList(
        key: const Key('offline-videos-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: visible.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          return _buildDownloadCard(visible[index]);
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
            if (_downloads.isNotEmpty)
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
                '共 ${_downloads.length} 条 · ${_formatBytes(_totalSizeBytes)}',
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
