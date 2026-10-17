import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../services/media_cache_service.dart';
import '../../services/media_cache_service_factory.dart';
import '../../services/image_resource_cache.dart';
import '../../services/cached_player_overlay_service.dart';
import '../../services/cache_lifecycle.dart';

/// 按平台展示 Android Media3 边播缓存或 Windows media_kit 播放缓冲。
class CacheManagementPage extends StatefulWidget {
  /// 创建可注入缓存服务的页面，测试时可传入不依赖 Android 的假服务。
  const CacheManagementPage({
    super.key,
    MediaCacheService? service,
    this.imageCache,
  }) : _service = service;

  final MediaCacheService? _service;
  final ImageResourceCache? imageCache;

  /// 创建保存缓存状态、加载状态和操作状态的页面状态。
  @override
  State<CacheManagementPage> createState() => _CacheManagementPageState();
}

/// 管理缓存状态读取、上限切换和清空确认的页面状态。
class _CacheManagementPageState extends State<CacheManagementPage> {
  late final MediaCacheService _service;
  MediaCacheStatus? _status;
  bool _loading = true;
  bool _mutating = false;
  ImageCacheUsage? _images;
  ImageResourceCache get _imageCache =>
      widget.imageCache ?? ImageResourceCache.instance;

  /// 页面创建后立即选择当前平台实现并读取缓存或缓冲用量与容量设置。
  @override
  void initState() {
    super.initState();
    _service = widget._service ?? createMediaCacheService();
    unawaited(_loadStatus());
  }

  /// 从原生层刷新缓存状态；失败时保留已有数据显示，避免页面变为空白。
  Future<void> _loadStatus() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      try {
        _images = await _imageCache.status();
      } catch (_) {
        _images = null;
      }
      final MediaCacheStatus status = await _service.loadStatus();
      if (mounted) {
        setState(() => _status = status);
      }
    } on MediaCacheException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 保存新的容量上限；播放器仍活跃或原生层拒绝时会展示明确原因。
  Future<void> _changeCapacity(int capacityBytes) async {
    final MediaCacheStatus? status = _status;
    if (status?.isPlaybackActive == true) {
      _showMessage('视频播放中，停止播放并退出播放页后才能管理缓存。');
      return;
    }
    await _runMutation(() => _service.setCapacityBytes(capacityBytes));
  }

  /// 显示确认框，避免用户误触后立即删除边播边缓存。
  Future<void> _confirmClearCache() async {
    final MediaCacheStatus? status = _status;
    if (status?.isPlaybackActive == true) {
      _showMessage('视频播放中，停止播放并退出播放页后才能管理缓存。');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          status?.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer
              ? '清空播放缓冲？'
              : '清空视频缓存？',
        ),
        content: Text(
          status?.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer
              ? '只清理旧版本遗留的临时磁盘缓冲，不影响离线下载、账号、观看记录和笔记。'
              : '只清理边播边缓存，不影响手动离线下载、账号、观看记录和笔记。',
        ),
        actions: <Widget>[
          TextButton(
            // 取消按钮只关闭确认框，不更改任何缓存内容。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认按钮只返回结果，实际清理由外层函数统一执行。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runMutation(_service.clearCache);
    }
  }

  /// 统一处理会改动缓存的原生请求，并在成功后替换为服务返回的最新状态。
  Future<void> _runMutation(
    Future<MediaCacheStatus> Function() operation,
  ) async {
    if (_mutating) {
      return;
    }
    setState(() => _mutating = true);
    try {
      final MediaCacheStatus status = await operation();
      if (mounted) {
        setState(() => _status = status);
      }
    } on MediaCacheException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _mutating = false);
      }
    }
  }

  /// 使用统一的三秒临时提示告知用户缓存操作结果或受限原因。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 创建当前缓存占用和已配置容量上限的摘要卡片。
  Widget _buildUsageCard(MediaCacheStatus status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              status.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer
                  ? '磁盘播放缓冲实际占用'
                  : '当前占用',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              status.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer
                  ? formatMediaCacheBytes(status.usedBytes)
                  : '${formatMediaCacheBytes(status.usedBytes)} / ${formatMediaCacheBytes(status.capacityBytes)}',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              status.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer
                  ? '磁盘软阈值：${formatMediaCacheBytes(status.capacityBytes)}（可能超出）'
                  : '容量上限：${formatMediaCacheBytes(status.capacityBytes)}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建只提供五档固定容量的选择器，保证 Android 和 Windows 都使用经过验证的安全范围。
  Widget _buildCapacityPicker(MediaCacheStatus status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: status.capacityBytes,
          key: const Key('video-cache-capacity'),
          decoration: InputDecoration(
            labelText:
                status.storageKind ==
                    MediaCacheStorageKind.windowsPlaybackBuffer
                ? '磁盘播放缓冲软阈值'
                : '视频磁盘缓存上限',
            border: const OutlineInputBorder(),
          ),
          items: supportedMediaCacheBytes
              .map(
                (int capacityBytes) => DropdownMenuItem<int>(
                  value: capacityBytes,
                  child: Text(
                    formatMediaCacheBytes(capacityBytes),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          // 选择函数只在没有活跃播放器且没有其他操作时发送容量变更。
          onChanged: _mutating || status.isPlaybackActive
              ? null
              : (int? capacityBytes) {
                  if (capacityBytes != null) {
                    unawaited(_changeCapacity(capacityBytes));
                  }
                },
        ),
      ),
    );
  }

  /// 创建播放页仍存活时显示的保护提示，解释为什么缓存按钮被禁用。
  Widget _buildBusyHint(MediaCacheStatus status) {
    if (!status.isPlaybackActive) {
      return const SizedBox.shrink();
    }
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: const ListTile(
        leading: Icon(Icons.play_circle_outline_rounded),
        title: Text('播放中暂不能管理缓存'),
        subtitle: Text('请停止播放并退出播放页后再清空缓存或更改上限。'),
      ),
    );
  }

  /// 创建平台化说明卡片，明确持久边播缓存、临时播放缓冲和离线下载之间的边界。
  Widget _buildExplanationCard(MediaCacheStatus? status) {
    final bool windowsBuffer =
        status?.storageKind == MediaCacheStorageKind.windowsPlaybackBuffer;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '缓存与缓冲说明',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (status?.bufferMessage != null)
              Text(
                status!.bufferMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 8),
            Text(
              windowsBuffer
                  ? '保留本次播放的磁盘回看缓冲，默认软阈值 512 MB。每 0.5 秒按实际文件大小检查；'
                        '达到阈值后请求暂停新增磁盘写入，已有文件保留到播放结束，绝不删除活跃文件。'
                        '检查和播放器响应存在延迟，实际占用可能超过阈值；这不是磁盘硬上限。'
                        '随后新增数据使用每路前后各 64 MB 的内存预算，独立音视频各有一份，解码内存另计。'
                        '回看受播放器保留范围限制，范围外需重新联网。内存索引预算不代表磁盘字节。'
                        '设置在下次打开播放器时生效。关闭后自动清理已结束会话，启动时回收崩溃残留；'
                        '不是离线下载，不能跨重启复用，不影响手动离线文件。'
                  : '边播边缓存默认 512 MB，超过上限自动淘汰最久未使用的内容，不是离线下载。'
                        '当前播放内容和写入中的分片受到保护；全部被占用时暂停新增缓存，继续联网播放。'
                        '系统也可能清理临时缓存，手动离线下载不参与自动清理。',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageImages({int? capacity}) async {
    if (_mutating) return;
    if (capacity == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('清空图片缓存？'),
          content: const Text(
            '清理头像和封面的临时文件及内存图片。当前图片会隐藏，下次打开页面重新加载；不影响离线视频、笔记和收藏。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清空'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _mutating = true);
    try {
      final before = _images?.usedBytes ?? 0;
      final usage = capacity == null
          ? await _imageCache.clear()
          : await _imageCache.setCapacity(capacity);
      if (mounted) {
        setState(() => _images = usage);
        _showMessage(
          '已释放 ${formatMediaCacheBytes((before - usage.usedBytes).clamp(0, before))}',
        );
      }
    } catch (_) {
      if (mounted) _showMessage('图片缓存暂时无法操作，请稍后重试。');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Widget _buildImageCache() {
    final usage = _images;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('头像与封面', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              usage == null
                  ? '暂时无法读取图片缓存用量'
                  : '${formatMediaCacheBytes(usage.usedBytes)} / ${formatMediaCacheBytes(usage.capacityBytes)} · ${usage.objects} 张',
            ),
            const SizedBox(height: 12),
            if (usage != null)
              DropdownButtonFormField<int>(
                isExpanded: true,
                key: ValueKey('image-cache-capacity-${usage.capacityBytes}'),
                initialValue: usage.capacityBytes,
                decoration: const InputDecoration(
                  labelText: '图片磁盘缓存上限',
                  border: OutlineInputBorder(),
                ),
                items: ImageResourceCache.capacities
                    .map(
                      (mb) => DropdownMenuItem(
                        value: mb * 1024 * 1024,
                        child: Text('$mb MB'),
                      ),
                    )
                    .toList(),
                onChanged: _mutating
                    ? null
                    : (value) {
                        if (value != null) {
                          unawaited(_manageImages(capacity: value));
                        }
                      },
              ),
            const SizedBox(height: 8),
            const Text(
              '默认 256 MB。超出上限自动清理最久未使用的图片；同一资源跨页面和重启复用，过期时检查更新。不同账号分开使用。',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('clear-image-cache'),
              onPressed: _mutating ? null : () => unawaited(_manageImages()),
              icon: const Icon(Icons.image_not_supported_outlined),
              label: const Text('清空图片缓存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitleCache() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('字幕临时缓存', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: SubtitleMemoryCache.instance.usage,
            builder: (context, bytes, _) =>
                Text('${formatMediaCacheBytes(bytes)} / 8 MB · 仅内存'),
          ),
          const Text(
            '用量按字幕文本和时间戳计，不是进程总内存。最多 64 条轨道，5 分钟后重新读取；达到上限按最近使用次序淘汰。临时字幕地址不写入磁盘。',
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('clear-subtitle-cache'),
            onPressed: () {
              CacheLifecycle.clearSubtitles();
              _showMessage('字幕缓存已清空，当前显示与未完成的字幕请求已撤销。');
            },
            icon: const Icon(Icons.subtitles_off_outlined),
            label: const Text('清空字幕并关闭显示'),
          ),
        ],
      ),
    ),
  );

  /// 组合加载、刷新、容量选择和清空操作，形成完整的缓存管理界面。
  @override
  Widget build(BuildContext context) {
    final MediaCacheStatus? status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数只重新读取用量，不会修改缓存内容。
            onPressed: _loading || _mutating
                ? null
                : () => unawaited(_loadStatus()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新缓存状态',
          ),
        ],
      ),
      body: AdaptivePageFrame(
        maxWidth: 900,
        child: status == null && _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                // 下拉刷新函数只读取状态，适合缓存被系统自动清理后的手动同步。
                onRefresh: _loadStatus,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    if (status != null) ...<Widget>[
                      _buildUsageCard(status),
                      const SizedBox(height: 12),
                      _buildBusyHint(status),
                      if (status.isPlaybackActive) const SizedBox(height: 12),
                      _buildCapacityPicker(status),
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              // 清空按钮函数先询问用户，再执行不可恢复的缓存清理。
                              onPressed: _mutating || status.isPlaybackActive
                                  ? null
                                  : () => unawaited(_confirmClearCache()),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: Text(
                                status.storageKind ==
                                        MediaCacheStorageKind
                                            .windowsPlaybackBuffer
                                    ? '清空播放缓冲'
                                    : '清空已缓存视频',
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _buildExplanationCard(status),
                    const SizedBox(height: 12),
                    _buildImageCache(),
                    const SizedBox(height: 12),
                    _buildSubtitleCache(),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 将字节数转换为用户易读的 B、MB 或 GB 文本。
String formatMediaCacheBytes(int bytes) {
  final int safeBytes = bytes < 0 ? 0 : bytes;
  const int bytesPerMegabyte = 1024 * 1024;
  const int bytesPerGigabyte = 1024 * 1024 * 1024;
  if (safeBytes >= bytesPerGigabyte) {
    return '${(safeBytes / bytesPerGigabyte).toStringAsFixed(1)} GB';
  }
  if (safeBytes >= bytesPerMegabyte) {
    return '${(safeBytes / bytesPerMegabyte).toStringAsFixed(1)} MB';
  }
  return '$safeBytes B';
}
