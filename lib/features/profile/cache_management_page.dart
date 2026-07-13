import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/media_cache_service.dart';

/// 展示并管理 Media3 边播边缓存，而非完整视频离线下载。
class CacheManagementPage extends StatefulWidget {
  /// 创建可注入缓存服务的页面，测试时可传入不依赖 Android 的假服务。
  const CacheManagementPage({super.key, MediaCacheService? service})
      : _service = service;

  final MediaCacheService? _service;

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

  /// 页面创建后立即读取 Android 当前的缓存用量和容量设置。
  @override
  void initState() {
    super.initState();
    _service = widget._service ?? NativeMediaCacheService();
    unawaited(_loadStatus());
  }

  /// 从原生层刷新缓存状态；失败时保留已有数据显示，避免页面变为空白。
  Future<void> _loadStatus() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
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
        title: const Text('清空视频缓存？'),
        content: const Text('这不会删除账号信息或观看记录，只会删除边播边缓存的数据。'),
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
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
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
            const Text(
              '当前占用',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '${formatMediaCacheBytes(status.usedBytes)} / '
              '${formatMediaCacheBytes(status.capacityBytes)}',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '容量上限：${formatMediaCacheBytes(status.capacityBytes)}',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建只提供五档固定容量的选择器，避免页面与 Android 的安全范围不一致。
  Widget _buildCapacityPicker(MediaCacheStatus status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DropdownButtonFormField<int>(
          value: status.capacityBytes,
          decoration: const InputDecoration(
            labelText: '缓存上限',
            border: OutlineInputBorder(),
          ),
          items: supportedMediaCacheBytes
              .map(
                (int capacityBytes) => DropdownMenuItem<int>(
                  value: capacityBytes,
                  child: Text(formatMediaCacheBytes(capacityBytes)),
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

  /// 创建说明卡片，明确缓存用途、系统清理行为和非离线下载边界。
  Widget _buildExplanationCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '缓存说明',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              '这里保存的是边播边缓存，用于减少短期内重复播放的网络请求，不是离线下载。'
              'Android 在存储空间紧张时可能自动清理这些数据。',
            ),
          ],
        ),
      ),
    );
  }

  /// 组合加载、刷新、容量选择和清空操作，形成完整的缓存管理界面。
  @override
  Widget build(BuildContext context) {
    final MediaCacheStatus? status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频缓存'),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数只重新读取用量，不会修改缓存内容。
            onPressed:
                _loading || _mutating ? null : () => unawaited(_loadStatus()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新缓存状态',
          ),
        ],
      ),
      body: status == null && _loading
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
                            label: const Text('清空已缓存视频'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _buildExplanationCard(),
                ],
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
