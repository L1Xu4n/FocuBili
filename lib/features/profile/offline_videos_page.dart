import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/offline_video_download.dart';
import '../../services/offline_video_service.dart';
import 'offline_player_page.dart';

/// 展示已下载到本机的离线视频，并提供播放、删除和清空管理。
class OfflineVideosPage extends StatefulWidget {
  /// 创建离线缓存页；服务可注入以支持测试和安全替换。
  const OfflineVideosPage({super.key, this.offlineVideoService});

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

  /// 创建页面服务并在首次进入时读取一次本机离线列表。
  @override
  void initState() {
    super.initState();
    _offlineVideoService = widget.offlineVideoService ?? OfflineVideoService();
    unawaited(_loadDownloads());
  }

  /// 读取离线列表并统计占用空间，失败时保留上一次成功显示的数据。
  Future<void> _loadDownloads() async {
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
  }

  /// 打开离线播放页，返回后保留当前列表。
  Future<void> _playDownload(OfflineVideoDownload download) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OfflinePlayerPage(
          filePath: download.filePath,
          title: download.title,
        ),
      ),
    );
  }

  /// 确认后删除一条离线视频。
  Future<void> _deleteDownload(OfflineVideoDownload download) async {
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
    final bool deleted = await _offlineVideoService.delete(download.bvid);
    if (!mounted) {
      return;
    }
    if (!deleted) {
      _showMessage('删除失败，请稍后重试。');
      return;
    }
    await _loadDownloads();
    _showMessage('已删除离线缓存');
  }

  /// 确认后清空全部离线缓存。
  Future<void> _clearAll() async {
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
    if (!mounted) {
      return;
    }
    if (!cleared) {
      _showMessage('清空失败，请稍后重试。');
      return;
    }
    await _loadDownloads();
    _showMessage('已清空离线缓存');
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
      key: Key('offline-video-${download.bvid}'),
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
                      '${download.qualityLabel} · ${_formatBytes(download.sizeBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('delete-offline-video-${download.bvid}'),
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
      );
    }
    return RefreshIndicator(
      onRefresh: _loadDownloads,
      child: AdaptiveTwoColumnList(
        key: const Key('offline-videos-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _downloads.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          return _buildDownloadCard(_downloads[index]);
        },
      ),
    );
  }

  /// 创建离线缓存页标题、清空入口和内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('离线缓存'),
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
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.offline_pin_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '共 ${_downloads.length} 条 · ${_formatBytes(_totalSizeBytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }
}
