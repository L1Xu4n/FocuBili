import 'package:flutter/foundation.dart';

import '../../../models/player_enhancement.dart';
import '../../../services/bilibili_player_enhancement_service.dart';

/// 独立管理章节和互动剧情状态，避免把网络与状态代码继续堆进播放器页面。
class PlayerEnhancementController extends ChangeNotifier {
  /// 创建控制器，并注入可替换的公开播放器增强服务。
  PlayerEnhancementController({
    required BilibiliPlayerEnhancementService service,
  }) : _service = service;

  final BilibiliPlayerEnhancementService _service;
  PlayerEnhancementMetadata _metadata = const PlayerEnhancementMetadata();
  InteractiveVideoNode? _interactiveNode;
  String _bvid = '';
  int _requestToken = 0;
  int? _lastRequestedEdgeId;
  bool _metadataLoading = false;
  bool _interactiveNodeLoading = false;
  bool _chapterProgressVisible = true;
  String? _metadataError;
  String? _interactiveNodeError;

  /// 返回当前分P按时间排列的只读章节列表。
  List<VideoChapter> get chapters => _metadata.chapters;

  /// 返回当前互动剧情节点；普通视频或尚未加载时为空。
  InteractiveVideoNode? get interactiveNode => _interactiveNode;

  /// 判断当前视频是否带有有效互动剧情版本。
  bool get isInteractive => _metadata.interaction != null;

  /// 判断播放器完播时是否应该交给互动选择层处理。
  bool get handlesPlaybackCompletion {
    return isInteractive && !(_interactiveNode?.isLeaf ?? false);
  }

  /// 判断分段元数据是否仍在请求中。
  bool get metadataLoading => _metadataLoading;

  /// 判断互动节点或下一批选择是否仍在请求中。
  bool get interactiveNodeLoading => _interactiveNodeLoading;

  /// 返回章节接口错误；没有错误时为空。
  String? get metadataError => _metadataError;

  /// 返回互动剧情接口错误；没有错误时为空。
  String? get interactiveNodeError => _interactiveNodeError;

  /// 返回用户是否允许在播放器时间轴上显示分段条。
  bool get chapterProgressVisible => _chapterProgressVisible;

  /// 读取新分P的章节和互动入口，并自动加载互动剧情起始节点。
  Future<void> load({required String bvid, required int cid}) async {
    final int token = ++_requestToken;
    _bvid = bvid;
    _lastRequestedEdgeId = null;
    _metadata = const PlayerEnhancementMetadata();
    _interactiveNode = null;
    _metadataError = null;
    _interactiveNodeError = null;
    _metadataLoading = true;
    _interactiveNodeLoading = false;
    notifyListeners();
    try {
      final PlayerEnhancementMetadata metadata = await _service.loadMetadata(
        bvid: bvid,
        cid: cid,
      );
      if (token != _requestToken) {
        return;
      }
      _metadata = metadata;
      _metadataLoading = false;
      notifyListeners();
      if (metadata.interaction != null) {
        await _loadInteractiveNode(token: token, edgeId: null);
      }
    } catch (error) {
      if (token != _requestToken) {
        return;
      }
      _metadataLoading = false;
      _metadataError = error.toString();
      notifyListeners();
    }
  }

  /// 在用户选择剧情后读取目标节点，让下一次完播显示正确的后续选择。
  Future<void> selectChoice(InteractiveVideoChoice choice) async {
    final int token = _requestToken;
    _lastRequestedEdgeId = choice.edgeId;
    _interactiveNode = null;
    _interactiveNodeError = null;
    notifyListeners();
    await _loadInteractiveNode(token: token, edgeId: choice.edgeId);
  }

  /// 重新请求上一次失败的互动节点，起始节点和剧情分支都能复用。
  Future<void> retryInteractiveNode() async {
    if (!isInteractive || _interactiveNodeLoading) {
      return;
    }
    await _loadInteractiveNode(
      token: _requestToken,
      edgeId: _lastRequestedEdgeId,
    );
  }

  /// 切换分段进度条显示状态，并立即通知播放器和详情面板刷新。
  void toggleChapterProgress() {
    _chapterProgressVisible = !_chapterProgressVisible;
    notifyListeners();
  }

  /// 查找播放位置对应的章节序号；没有章节时返回 -1。
  int chapterIndexAt(Duration position) {
    for (int index = 0; index < chapters.length; index += 1) {
      if (chapters[index].contains(
        position,
        isLast: index == chapters.length - 1,
      )) {
        return index;
      }
    }
    return -1;
  }

  /// 请求指定剧情节点，并用令牌防止旧视频的迟到响应污染新视频。
  Future<void> _loadInteractiveNode({
    required int token,
    required int? edgeId,
  }) async {
    final InteractiveVideoInfo? interaction = _metadata.interaction;
    if (interaction == null || token != _requestToken) {
      return;
    }
    _interactiveNodeLoading = true;
    _interactiveNodeError = null;
    notifyListeners();
    try {
      final InteractiveVideoNode node = await _service.loadInteractiveNode(
        bvid: _bvid,
        graphVersion: interaction.graphVersion,
        edgeId: edgeId,
      );
      if (token != _requestToken) {
        return;
      }
      _interactiveNode = node;
      _interactiveNodeLoading = false;
      notifyListeners();
    } catch (error) {
      if (token != _requestToken) {
        return;
      }
      _interactiveNodeLoading = false;
      _interactiveNodeError = error.toString();
      notifyListeners();
    }
  }
}
