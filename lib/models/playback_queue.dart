import 'package:flutter/foundation.dart';

import 'learning_list_entry.dart';
import 'video_preview.dart';

/// 命名路由同时携带完整视频和可选来源，旧 VideoPreview 参数仍可使用。
class PlayerLaunchRequest {
  /// 来源列表的所有权在路由打开后交给播放器。
  const PlayerLaunchRequest(this.video, this.queue);
  final VideoPreview video;
  final PlaybackQueue queue;
}

/// 一项可以是整支视频，也可以是学习清单指定的分 P。
class PlaybackQueueItem {
  /// 创建列表条目；学习条目保留原身份与续播位置。
  const PlaybackQueueItem({
    required this.bvid,
    required this.title,
    this.learningEntry,
  });

  final String bvid;
  final String title;
  final LearningListEntry? learningEntry;

  /// 使用 BV/CID 区分同一视频中的多个学习任务。
  String get id => '$bvid:${learningEntry?.partCid ?? 0}';

  /// 匹配正在播放的内容，普通视频条目允许在内部切换分 P。
  bool matches(String currentBvid, int currentCid) =>
      bvid == currentBvid &&
      (learningEntry == null || learningEntry!.partCid == currentCid);
}

/// 一次分页读取的原子结果；失败时不推进页码。
class PlaybackQueuePage {
  /// 保留服务端顺序与后续分页标志。
  const PlaybackQueuePage(this.items, {required this.hasMore});
  final List<PlaybackQueueItem> items;
  final bool hasMore;
}

/// 一次播放会话拥有的列表，不持久保存或修改来源内容。
class PlaybackQueue extends ChangeNotifier {
  /// 用已加载的来源快照启动，后续由独立读取器分页。
  PlaybackQueue({
    required this.title,
    required Iterable<PlaybackQueueItem> items,
    this.loadPage,
    int nextPage = 1,
    bool hasMore = false,
  }) : _items = List.of(items),
       _nextPage = nextPage,
       _hasMore = hasMore;

  final String title;
  final Future<PlaybackQueuePage> Function(int page)? loadPage;
  final List<PlaybackQueueItem> _items;
  int _nextPage;
  bool _hasMore;
  bool _disposed = false;
  Future<void>? _pending;
  String? _lastPageSignature;
  String? error;

  /// 提供只读快照，防止界面直接改变队列顺序。
  List<PlaybackQueueItem> get items => List.unmodifiable(_items);
  bool get hasMore => _hasMore && loadPage != null;
  bool get loading => _pending != null;

  /// 按稳定身份寻找当前项。
  int indexOf(String bvid, int cid) =>
      _items.indexWhere((item) => item.matches(bvid, cid));

  /// 合并一页，去重并保留旧顺序；失败保留内容和页码以便重试。
  Future<void> loadMore() {
    if (_pending != null) return _pending!;
    if (_disposed || !hasMore) return Future.value();
    final completion = _readNextPage();
    _pending = completion;
    notifyListeners();
    return completion.whenComplete(() {
      _pending = null;
      if (!_disposed) notifyListeners();
    });
  }

  /// 读取器完成后才提交结果；已关闭播放器的返回值不再通知界面。
  Future<void> _readNextPage() async {
    try {
      final page = await loadPage!(_nextPage);
      if (_disposed) return;
      final ids = _items.map((item) => item.id).toSet();
      final additions = page.items.where((item) => ids.add(item.id)).toList();
      final signature = page.items.map((item) => item.id).join('|');
      // 内嵌合集可能已包含第一页；相邻接口页重复才说明分页没有前进。
      if (page.hasMore &&
          (page.items.isEmpty || signature == _lastPageSignature)) {
        throw StateError('播放列表分页没有前进');
      }
      _items.addAll(additions);
      _lastPageSignature = signature;
      _nextPage++;
      _hasMore = page.hasMore;
      error = null;
    } catch (_) {
      if (!_disposed) error = '播放列表加载失败，请重试';
    }
  }

  /// 自动前进前等待所需分页；失败不把列表误认为已经结束。
  Future<PlaybackQueueItem?> nextAfter(String bvid, int cid) async {
    var index = indexOf(bvid, cid);
    while (!_disposed && index >= 0 && index + 1 >= _items.length && hasMore) {
      await loadMore();
      if (error != null) return null;
      index = indexOf(bvid, cid);
    }
    return !_disposed && index >= 0 && index + 1 < _items.length
        ? _items[index + 1]
        : null;
  }

  /// 取消通知而不取消调用方可能共用的网络服务。
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
