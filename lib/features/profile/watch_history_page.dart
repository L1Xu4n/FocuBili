import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/video_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/bilibili_service.dart';
import '../../services/watch_history_service.dart';

/// 展示只保存在当前设备上的观看记录，不读取或同步 B 站账号历史。
class WatchHistoryPage extends StatefulWidget {
  /// 创建本机观看记录页面；可注入服务以便测试或替换本地实现。
  const WatchHistoryPage({
    super.key,
    this.historyService,
    this.bilibiliService,
  });

  /// 可选的本地记录服务；未传入时页面会创建默认 SharedPreferences 服务。
  final WatchHistoryService? historyService;

  /// 可选的视频详情服务；未传入时使用公开视频详情查询服务。
  final BilibiliService? bilibiliService;

  /// 创建管理加载、删除和打开视频状态的页面状态对象。
  @override
  State<WatchHistoryPage> createState() => _WatchHistoryPageState();
}

/// 管理设备本机观看记录的读取、删除、清空和重新打开流程。
class _WatchHistoryPageState extends State<WatchHistoryPage> {
  late final WatchHistoryService _historyService;
  late final BilibiliService _bilibiliService;
  final TextEditingController _searchController = TextEditingController();
  List<WatchHistoryEntry> _entries = const <WatchHistoryEntry>[];
  bool _isLoading = true;
  String? _loadError;
  String? _openingBvid;
  String _searchQuery = '';

  /// 初始化可替换服务并在首次显示页面时读取设备本机记录。
  @override
  void initState() {
    super.initState();
    _historyService = widget.historyService ?? WatchHistoryService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _loadHistory();
  }

  /// 释放观看记录搜索输入控制器。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 从本机存储读取列表，并把读取失败转换为可重试的页面状态。
  Future<void> _loadHistory() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final List<WatchHistoryEntry> entries = await _historyService
          .loadHistory();
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
      unawaited(_backfillMissingThumbnails(entries));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = const <WatchHistoryEntry>[];
        _isLoading = false;
        _loadError = '读取本机观看记录失败，请稍后重试。';
      });
    }
  }

  /// 以每批最多两个公开详情请求补齐旧记录封面，失败时保留原记录且不阻塞页面显示。
  Future<void> _backfillMissingThumbnails(
    List<WatchHistoryEntry> entries,
  ) async {
    final List<WatchHistoryEntry> missingEntries = entries
        .where((WatchHistoryEntry entry) => entry.thumbnailUrl.isEmpty)
        .toList(growable: false);
    if (missingEntries.isEmpty) {
      return;
    }
    final Map<String, String> thumbnailUrls = <String, String>{};
    for (int offset = 0; offset < missingEntries.length; offset += 2) {
      final int end = (offset + 2).clamp(0, missingEntries.length).toInt();
      final List<MapEntry<String, String>?> results = await Future.wait(
        missingEntries.sublist(offset, end).map(_lookupMissingThumbnail),
      );
      for (final MapEntry<String, String>? result in results) {
        if (result != null) {
          thumbnailUrls[result.key] = result.value;
        }
      }
    }
    if (!mounted || thumbnailUrls.isEmpty) {
      return;
    }
    final List<WatchHistoryEntry> updated = await _historyService
        .backfillThumbnails(thumbnailUrls);
    if (mounted) {
      setState(() => _entries = updated);
    }
  }

  /// 查询一条旧记录的公开视频详情并返回 BV 与封面；无封面或网络失败时返回空值。
  Future<MapEntry<String, String>?> _lookupMissingThumbnail(
    WatchHistoryEntry entry,
  ) async {
    try {
      final VideoPreview video = await _bilibiliService.lookupVideo(entry.bvid);
      if (video.thumbnailUrl.isEmpty) {
        return null;
      }
      return MapEntry<String, String>(entry.bvid, video.thumbnailUrl);
    } catch (_) {
      return null;
    }
  }

  /// 询问用户是否确认删除一条记录，避免误触立即丢失本机数据。
  Future<bool> _confirmRemove(WatchHistoryEntry entry) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移除观看记录'),
        content: Text('确定移除“${entry.title}”吗？此操作只影响本机。'),
        actions: <Widget>[
          TextButton(
            // 取消按钮函数关闭对话框而不修改本机记录。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认按钮函数只返回结果，实际删除统一由外层函数执行。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 询问用户是否确认清空当前设备上的全部观看记录。
  Future<bool> _confirmClear() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空本机观看记录'),
        content: const Text('确定清空全部本机观看记录吗？此操作不能撤销，也不会影响 B 站账号。'),
        actions: <Widget>[
          TextButton(
            // 取消按钮函数关闭对话框而不清空设备上的数据。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认按钮函数只返回确认结果，实际清空由外层函数执行。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 删除一条已确认的本机记录，并以服务返回的列表更新当前界面。
  Future<void> _removeEntry(WatchHistoryEntry entry) async {
    if (!await _confirmRemove(entry) || !mounted) {
      return;
    }
    try {
      final List<WatchHistoryEntry> entries = await _historyService.remove(
        entry.bvid,
      );
      if (!mounted) {
        return;
      }
      setState(() => _entries = entries);
    } catch (_) {
      if (mounted) {
        _showMessage('移除本机观看记录失败，请稍后重试。');
      }
    }
  }

  /// 清空用户已确认的全部本机记录，并立即显示空记录状态。
  Future<void> _clearAll() async {
    if (!await _confirmClear() || !mounted) {
      return;
    }
    try {
      final List<WatchHistoryEntry> entries = await _historyService.clear();
      if (!mounted) {
        return;
      }
      setState(() => _entries = entries);
    } catch (_) {
      if (mounted) {
        _showMessage('清空本机观看记录失败，请稍后重试。');
      }
    }
  }

  /// 查询被点击记录对应的视频详情，成功后进入播放器，失败时保留该记录。
  Future<void> _openEntry(WatchHistoryEntry entry) async {
    if (_openingBvid != null) {
      return;
    }
    setState(() => _openingBvid = entry.bvid);
    try {
      final VideoPreview video = await _bilibiliService.lookupVideo(entry.bvid);
      if (!mounted) {
        return;
      }
      setState(() => _openingBvid = null);
      Navigator.of(context).pushNamed(AppRoutes.player, arguments: video);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _openingBvid = null);
      final String message = error is BilibiliLookupException
          ? error.message
          : '无法打开该视频，请稍后重试。';
      _showMessage(message);
    }
  }

  /// 显示统一持续三秒的轻量提示，不改变已有本机记录内容。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 将本机记录时间格式化为便于扫读的年月日和小时分钟文本。
  String _formatWatchedAt(DateTime watchedAt) {
    final String year = watchedAt.year.toString().padLeft(4, '0');
    final String month = watchedAt.month.toString().padLeft(2, '0');
    final String day = watchedAt.day.toString().padLeft(2, '0');
    final String hour = watchedAt.hour.toString().padLeft(2, '0');
    final String minute = watchedAt.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  /// 将已观看的位置转换为简短时分秒文本，供缩略图右下角展示。
  String _formatWatchedPosition(Duration position) {
    final int totalSeconds = position.inSeconds.clamp(0, 24 * 60 * 60).toInt();
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String twoDigitsMinutes = minutes.toString().padLeft(2, '0');
    final String twoDigitsSeconds = seconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$twoDigitsMinutes:$twoDigitsSeconds'
        : '$minutes:$twoDigitsSeconds';
  }

  /// 构建缓存缩略图、网络失败占位图和右下角的已观看时长角标。
  Widget _buildHistoryThumbnail(WatchHistoryEntry entry) {
    return SizedBox(
      width: 122,
      height: 76,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (entry.thumbnailUrl.isEmpty)
              _buildThumbnailPlaceholder()
            else
              CachedNetworkImage(
                imageUrl: entry.thumbnailUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36',
                },
                fit: BoxFit.cover,
                memCacheWidth: 320,
                maxWidthDiskCache: 640,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (BuildContext context, String url) =>
                    _buildThumbnailPlaceholder(),
                errorWidget: (BuildContext context, String url, Object error) =>
                    _buildThumbnailPlaceholder(),
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: _buildThumbnailBadge(
                '已看 ${_formatWatchedPosition(entry.lastPosition)}',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 按标题、UP 主、分P标题或 BV 号筛选本机观看记录。
  List<WatchHistoryEntry> _filteredEntries() {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _entries;
    }
    return _entries
        .where(
          (WatchHistoryEntry entry) =>
              entry.title.toLowerCase().contains(query) ||
              entry.ownerName.toLowerCase().contains(query) ||
              entry.lastPartTitle.toLowerCase().contains(query) ||
              entry.bvid.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// 创建本机观看记录搜索框，输入时即时筛选而不访问网络。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: TextField(
        key: const Key('watch-history-search'),
        controller: _searchController,
        onChanged: (String value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: '搜索标题、UP 主、分P或 BV 号',
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  /// 创建无法获得封面时使用的低干扰本地占位图。
  Widget _buildThumbnailPlaceholder() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.play_arrow_rounded, color: Colors.black45),
      ),
    );
  }

  /// 创建覆盖在缩略图上的半透明文字角标。
  Widget _buildThumbnailBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }

  /// 构建顶部的本机范围说明，明确它不等同于 B 站账号观看历史。
  Widget _buildLocalOnlyNotice() {
    return const Card(
      margin: EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.devices_other_rounded),
            SizedBox(width: 10),
            Expanded(child: Text('仅保存在本机，不与 B 站账号或云端观看历史同步。')),
          ],
        ),
      ),
    );
  }

  /// 构建首次读取本机存储时的居中加载状态。
  Widget _buildLoadingState() {
    return Center(
      child: Semantics(
        label: '正在读取本机观看记录',
        child: const CircularProgressIndicator(),
      ),
    );
  }

  /// 构建本机存储读取失败的说明和重试按钮。
  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: 12),
            Text(_loadError ?? '读取本机观看记录失败，请稍后重试。'),
            const SizedBox(height: 12),
            OutlinedButton(
              // 重试按钮函数只重新读取本机数据，不会触碰 B 站账号状态。
              onPressed: _loadHistory,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建没有任何设备本机记录时的空状态提示。
  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.history_toggle_off_rounded, size: 44),
            SizedBox(height: 12),
            Text('还没有本机观看记录'),
            SizedBox(height: 4),
            Text('播放视频后会自动记录最近观看的位置。'),
          ],
        ),
      ),
    );
  }

  /// 构建自适应记录卡；封面使用固定比例，文字区域在窄屏也不会被 ListTile 挤坏。
  Widget _buildHistoryList() {
    final List<WatchHistoryEntry> visibleEntries = _filteredEntries();
    if (visibleEntries.isEmpty) {
      return const Center(child: Text('没有匹配的观看记录'));
    }
    return ListView.separated(
      key: const Key('watch-history-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: visibleEntries.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final WatchHistoryEntry entry = visibleEntries[index];
        final bool isOpening = _openingBvid == entry.bvid;
        return Card(
          key: Key('watch-history-${entry.bvid}'),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // 卡片点击函数查询最新公开详情，避免使用可能已失效的旧分P数据。
            onTap: isOpening ? null : () => _openEntry(entry),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildHistoryThumbnail(entry),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              entry.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              entry.ownerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (isOpening)
                        const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        IconButton(
                          tooltip: '移除记录',
                          icon: const Icon(Icons.delete_outline_rounded),
                          // 删除按钮函数先二次确认，再仅移除设备上的这一条记录。
                          onPressed: () => _removeEntry(entry),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上次看至 P${entry.lastPartPageNumber} · '
                    '${entry.lastPartTitle}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '上次观看：${_formatWatchedAt(entry.watchedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 根据加载、失败、空和有记录四种状态创建页面主体。
  Widget _buildBody() {
    final Widget content;
    if (_isLoading) {
      content = _buildLoadingState();
    } else if (_loadError != null) {
      content = _buildErrorState();
    } else if (_entries.isEmpty) {
      content = _buildEmptyState();
    } else {
      content = _buildHistoryList();
    }
    return Column(
      children: <Widget>[
        _buildLocalOnlyNotice(),
        if (!_isLoading && _loadError == null && _entries.isNotEmpty)
          _buildSearchField(),
        Expanded(child: content),
      ],
    );
  }

  /// 创建本机记录页标题、清空入口和与状态相匹配的内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本机观看记录'),
        actions: <Widget>[
          if (!_isLoading && _loadError == null && _entries.isNotEmpty)
            TextButton(
              // 清空按钮函数会先二次确认，避免误触抹去全部设备记录。
              onPressed: _clearAll,
              child: const Text('清空'),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
