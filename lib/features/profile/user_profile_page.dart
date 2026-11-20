import 'dart:async';
import 'dart:collection';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/widgets/drag_selection_region.dart';
import '../common/video_batch_actions.dart';
import '../common/video_list_selection.dart';
import '../common/video_save_destination_dialog.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../features/common/watch_history_badge.dart';
import '../../models/public_profile.dart';
import '../../models/subscription.dart';
import '../../models/video_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_interaction_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/learning_list_service.dart';
import '../../services/subscription_service.dart';
import '../common/discovery_blocklist.dart';
import '../learning/learning_add_sheet.dart';
import '../subscriptions/subscription_updates_page.dart';
import '../../services/watch_history_service.dart';
import 'collection_detail_page.dart';

/// 用户主页只展示公开资料、投稿、专栏和 UGC 合集，不提供私信入口。
class UserProfilePage extends StatefulWidget {
  /// 创建公开用户主页，并允许从已有视频资料预填昵称和头像。
  const UserProfilePage({
    super.key,
    required this.mid,
    this.initialName = '',
    this.initialAvatarUrl = '',
    this.initialSign = '',
    this.initialOfficialDescription = '',
    this.currentPlayback,
    this.publicContentService,
    this.interactionService,
    this.videoService,
    this.learningListService,
    this.watchHistoryService,
    this.subscriptionService,
    this.batchActions,
  });

  final SubscriptionService? subscriptionService;
  final VideoBatchActions? batchActions;
  final int mid;
  final String initialName;
  final String initialAvatarUrl;
  final String initialSign;
  final String initialOfficialDescription;

  /// The player route's current public upload, never a history entry.
  final ({int ownerMid, String bvid, int accountRevision})? currentPlayback;

  final BilibiliPublicContentService? publicContentService;
  final BilibiliInteractionService? interactionService;
  final BilibiliService? videoService;
  final LearningListService? learningListService;
  final WatchHistoryService? watchHistoryService;

  /// 创建管理公开主页资料、标签和分页内容的状态。
  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

/// 标识用户主页下方三类公开内容。
enum _CreatorTab { videos, articles, collections }

/// Retain only the avatar URL. AppNetworkImage owns the shared image bytes.
class _CreatorAvatarSnapshot {
  static const _lifetime = Duration(minutes: 10);
  static const _maximumEntries = 120;

  final _entries = <int, (String, DateTime, int)>{};
  int _nextRequest = 0;
  int? _accountRevision;

  void _checkAccount() {
    final revision = CacheLifecycle.account.value;
    if (_accountRevision == revision) return;
    _accountRevision = revision;
    _entries.clear();
  }

  String read(int mid) {
    _checkAccount();
    final entry = _entries.remove(mid);
    if (entry == null || !DateTime.now().isBefore(entry.$2.add(_lifetime))) {
      return '';
    }
    _entries[mid] = entry;
    return entry.$1;
  }

  int beginRequest() => ++_nextRequest;

  void write(int mid, String url, int request) {
    _checkAccount();
    if ((_entries[mid]?.$3 ?? 0) > request) return;
    _entries.remove(mid);
    _entries[mid] = (url, DateTime.now(), request);
    if (_entries.length > _maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// 管理用户主页资料读取、标签切换、分页以及内容导航。
class _UserProfilePageState extends State<UserProfilePage>
    with
        SingleTickerProviderStateMixin,
        DiscoveryBlocklistState<UserProfilePage> {
  static const int _maximumPartCountLookupConcurrency = 2;
  static const int _maximumLocationPages = 10;
  static const double _videoListBreakpoint = 760;
  static const double _videoRowSpacing = 12;
  static final _defaultAvatarSnapshots = _CreatorAvatarSnapshot();
  static final _injectedAvatarSnapshots = Expando<_CreatorAvatarSnapshot>();
  late final _CreatorAvatarSnapshot _avatarSnapshots;
  late final int _initialAccountRevision;
  int _profileGeneration = 0;
  String _cachedAvatarUrl = '';
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  late final LearningListService _learningListService;
  late final WatchHistoryService _watchHistoryService;
  late final BilibiliInteractionService _interactionService;
  late final TabController _tabController;
  final ScrollController _profileScrollController = ScrollController();
  ScrollController? _videoListController;
  final _videoRowKeys = <String, GlobalKey>{};
  int _locationGeneration = 0;
  bool _locatingCurrentVideo = false;
  String? _highlightedVideo;
  Timer? _highlightTimer;
  final TextEditingController _videoSearchController = TextEditingController();
  CreatorProfile? _profile;
  List<Object> _items = const <Object>[];
  _CreatorTab _selectedTab = _CreatorTab.videos;
  int _page = 0;
  bool _hasMore = true;
  bool _loadingProfile = true;
  bool _loadingContent = true;
  bool _loadingMore = false;
  int _contentGeneration = 0;
  int _selectionVisibilityEpoch = 0;
  String? _profileError;
  String? _contentError;
  bool? _isFollowing;
  bool _followBusy = false;
  bool _batchBusy = false;
  final VideoListSelection _selection = VideoListSelection();
  late final VideoBatchActions _batchActions;
  String? _openingBvid;
  String? _addingBvid;
  Set<String> _learningListBvids = const <String>{};
  String _videoKeyword = '';
  CreatorVideoOrder _videoOrder = CreatorVideoOrder.latest;
  int _totalCount = 0;
  bool _videoSearchExpanded = false;
  bool _profileSignExpanded = false;
  Map<String, WatchHistoryEntry> _watchHistoryByBvid =
      const <String, WatchHistoryEntry>{};
  final Queue<CreatorVideo> _partCountLookupQueue = Queue<CreatorVideo>();
  final Set<String> _partCountLookupAttemptedBvids = <String>{};
  final Map<String, int> _resolvedPartCounts = <String, int>{};
  int _activePartCountLookups = 0;

  /// 初始化公开服务、标签控制器和滚动分页监听。
  @override
  void initState() {
    super.initState();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _avatarSnapshots = widget.publicContentService == null
        ? _defaultAvatarSnapshots
        : (_injectedAvatarSnapshots[_publicContentService] ??=
              _CreatorAvatarSnapshot());
    _initialAccountRevision = CacheLifecycle.account.value;
    _cachedAvatarUrl = _avatarSnapshots.read(widget.mid);
    CacheLifecycle.account.addListener(_profileAccountChanged);
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _learningListService = widget.learningListService ?? LearningListService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _interactionService =
        widget.interactionService ?? BilibiliInteractionService();
    _batchActions =
        widget.batchActions ??
        VideoBatchActions(
          learningService: _learningListService,
          videoService: _videoService,
          interactionService: _interactionService,
        );
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChanged);
    unawaited(_loadProfile());
    unawaited(_loadFollowingState());
    unawaited(_loadFirstContentPage());
    unawaited(_loadWatchHistory());
    unawaited(_loadLearningListMembership());
  }

  /// 读取本机学习清单中的 BV 集合，供投稿卡片显示加入或已加入图标。
  Future<void> _loadLearningListMembership() async {
    final entries = await _learningListService.loadEntries();
    if (mounted) {
      setState(() {
        _learningListBvids = entries.map((entry) => entry.bvid).toSet();
      });
    }
  }

  /// 读取当前账号对该 UP 主的关注状态，未登录时保留未确定而不显示错误页。
  Future<void> _loadFollowingState() async {
    try {
      final bool following = await _interactionService.loadFollowingState(
        widget.mid,
      );
      if (mounted) {
        setState(() => _isFollowing = following);
      }
    } on Object {
      // 关注状态属于增强信息，读取失败不影响公开主页和投稿列表展示。
    }
  }

  /// 关注或取消关注当前 UP 主，并在写操作成功后更新按钮文字。
  Future<void> _toggleFollowing() async {
    if (_followBusy || widget.mid <= 0) {
      return;
    }
    final bool following = _isFollowing == true;
    setState(() => _followBusy = true);
    try {
      await _interactionService.setFollowing(
        mid: widget.mid,
        following: !following,
      );
      if (mounted) {
        setState(() => _isFollowing = !following);
        _showMessage(following ? '已取消关注' : '已关注');
      }
    } on Object catch (error) {
      if (mounted) {
        _showMessage(error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _followBusy = false);
      }
    }
  }

  /// 读取本机观看记录并按 BV 号建立索引，让投稿封面能快速判断是否看过。
  Future<void> _loadWatchHistory() async {
    final List<WatchHistoryEntry> entries = await _watchHistoryService
        .loadHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _watchHistoryByBvid = <String, WatchHistoryEntry>{
        for (final WatchHistoryEntry entry in entries) entry.bvid: entry,
      };
    });
  }

  String get _profileAvatarUrl {
    final fresh = _profile?.mid == widget.mid ? _profile?.avatarUrl ?? '' : '';
    if (fresh.isNotEmpty) return fresh;
    if (_cachedAvatarUrl.isNotEmpty) return _cachedAvatarUrl;
    return CacheLifecycle.account.value == _initialAccountRevision
        ? widget.initialAvatarUrl
        : '';
  }

  void _profileAccountChanged() {
    if (!mounted) return;
    setState(() {
      _profile = null;
      _cachedAvatarUrl = _avatarSnapshots.read(widget.mid);
    });
    unawaited(_loadProfile());
    unawaited(_loadFirstContentPage());
  }

  @override
  void didUpdateWidget(covariant UserProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mid != widget.mid) {
      _profile = null;
      _cachedAvatarUrl = _avatarSnapshots.read(widget.mid);
      unawaited(_loadProfile());
      unawaited(_loadFirstContentPage());
    } else if (oldWidget.currentPlayback != widget.currentPlayback) {
      _cancelVideoLocation();
    }
  }

  /// 移除监听并释放标签与滚动控制器。
  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_profileAccountChanged);
    _highlightTimer?.cancel();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _profileScrollController.dispose();
    _videoSearchController.dispose();
    super.dispose();
  }

  /// 标签动画完成后切换内容类型，并从第一页重新读取。
  void _handleTabChanged() {
    if (_tabController.indexIsChanging) {
      return;
    }
    if (_batchBusy) {
      _tabController.index = _selectedTab.index;
      return;
    }
    final _CreatorTab nextTab = _CreatorTab.values[_tabController.index];
    if (nextTab == _selectedTab) {
      return;
    }
    _selectedTab = nextTab;
    unawaited(_loadFirstContentPage());
  }

  /// 接收嵌套列表滚动通知，在距离底部较近时自动读取下一页。
  bool _handleContentScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (_locatingCurrentVideo) {
      if (notification is UserScrollNotification &&
          notification.direction != ScrollDirection.idle) {
        setState(_cancelVideoLocation);
      }
    } else if (notification.metrics.extentAfter < 420) {
      unawaited(_loadMore());
    }
    return false;
  }

  /// 读取 UP 主公开名片；失败时保留从视频页带来的昵称和头像。
  Future<void> _loadProfile() async {
    final generation = ++_profileGeneration;
    final avatarRequest = _avatarSnapshots.beginRequest();
    final accountRevision = CacheLifecycle.account.value;
    final mid = widget.mid;
    bool isCurrent() =>
        mounted &&
        generation == _profileGeneration &&
        accountRevision == CacheLifecycle.account.value &&
        mid == widget.mid;
    setState(() {
      _loadingProfile = true;
      _profileError = null;
    });
    try {
      final CreatorProfile profile = await _publicContentService.loadProfile(
        mid,
      );
      if (!isCurrent()) return;
      if (profile.mid != mid) {
        throw const BilibiliLookupException('UP 主名片与请求不匹配。');
      }
      _avatarSnapshots.write(mid, profile.avatarUrl, avatarRequest);
      setState(() {
        final oldName = _profile?.name ?? widget.initialName;
        _profile = profile;
        _cachedAvatarUrl = profile.avatarUrl;
        if (oldName != profile.name) _reconcileDiscoverySelection();
        _loadingProfile = false;
      });
    } catch (error) {
      if (!isCurrent()) return;
      setState(() {
        _profileError = error.toString();
        _loadingProfile = false;
      });
    }
  }

  /// 读取当前标签第 1 页，并清除上一标签留下的内容和错误。
  Future<void> _loadFirstContentPage({bool keepVideoLocation = false}) async {
    if (!keepVideoLocation) _cancelVideoLocation();
    _videoRowKeys.clear();
    _selection.end();
    final _CreatorTab requestedTab = _selectedTab;
    final generation = ++_contentGeneration;
    if (mounted) {
      setState(() {
        _items = const <Object>[];
        _page = 0;
        _hasMore = true;
        _loadingContent = true;
        _loadingMore = false;
        _contentError = null;
      });
    }
    try {
      final CreatorContentPage<Object> result = await _loadContentPage(
        requestedTab,
        1,
      );
      if (!mounted ||
          requestedTab != _selectedTab ||
          generation != _contentGeneration) {
        return;
      }
      setState(() {
        // 首屏同样必须按 BV 去重；否则两个卡片会镜像同一选择，
        // 空 BV 还会产生可勾选但不能保存的条目。
        _items = requestedTab == _CreatorTab.videos
            ? _mergeContent(const [], result.items, requestedTab)
            : result.items;
        _page = result.page;
        _hasMore = result.hasMore;
        _totalCount = result.totalCount ?? _items.length;
        _loadingContent = false;
      });
    } catch (error) {
      if (!mounted ||
          requestedTab != _selectedTab ||
          generation != _contentGeneration) {
        return;
      }
      setState(() {
        _contentError = error.toString();
        _loadingContent = false;
      });
    }
  }

  /// 根据标签调用对应公开接口，并统一转换为 Object 分页供页面渲染。
  Future<CreatorContentPage<Object>> _loadContentPage(
    _CreatorTab tab,
    int page,
  ) async {
    switch (tab) {
      case _CreatorTab.videos:
        final CreatorContentPage<CreatorVideo> result =
            await _publicContentService.loadVideos(
              widget.mid,
              page: page,
              keyword: _videoKeyword,
              order: _videoOrder,
            );
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
      case _CreatorTab.articles:
        final CreatorContentPage<CreatorArticle> result =
            await _publicContentService.loadArticles(widget.mid, page: page);
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
      case _CreatorTab.collections:
        final CreatorContentPage<CreatorCollection> result =
            await _publicContentService.loadCollections(widget.mid, page: page);
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
    }
  }

  /// 提交投稿关键词并从第一页重新查询，空关键词表示恢复全部投稿。
  void _submitVideoSearch([String? value]) {
    if (_batchBusy) return;
    final String keyword = (value ?? _videoSearchController.text).trim();
    if (keyword == _videoKeyword && !_loadingContent) {
      return;
    }
    _videoKeyword = keyword;
    _videoSearchController.value = TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    );
    FocusScope.of(context).unfocus();
    unawaited(_loadFirstContentPage());
  }

  /// 切换投稿排序后重新请求第一页，保证“最多播放/最多收藏”由服务端完整排序。
  void _selectVideoOrder(CreatorVideoOrder order) {
    if (_batchBusy || order == _videoOrder) {
      return;
    }
    setState(() => _videoOrder = order);
    unawaited(_loadFirstContentPage());
  }

  /// 展开或收起投稿搜索框，收起时保留已经提交的关键词结果。
  void _toggleVideoSearch() {
    setState(() {
      _cancelVideoLocation();
      _videoSearchExpanded = !_videoSearchExpanded;
    });
    if (!_videoSearchExpanded) {
      FocusScope.of(context).unfocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _videoSearchExpanded &&
            _profileScrollController.hasClients) {
          _profileScrollController.jumpTo(
            _profileScrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  /// 将投稿排序枚举转换为工具栏中容易理解的中文名称。
  String _videoOrderLabel(CreatorVideoOrder order) {
    switch (order) {
      case CreatorVideoOrder.latest:
        return '最新发布';
      case CreatorVideoOrder.mostPlayed:
        return '最多播放';
      case CreatorVideoOrder.mostFavorited:
        return '最多收藏';
    }
  }

  /// 创建投稿专用的紧凑数量、搜索框和排序菜单，给视频列表留出更多首屏空间。
  Widget _buildVideoToolbar() {
    final count = Text(
      '共${_totalCount > 0 ? _totalCount : _items.length}投稿',
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
    final controls = <Widget>[
      if (!_selection.active)
        IconButton(
          tooltip: '多选投稿',
          icon: const Icon(Icons.checklist_rounded),
          onPressed:
              _loadingContent ||
                  !discoveryBlocklistActionsReady ||
                  !_items.whereType<CreatorVideo>().any(
                    (v) => !_isCreatorVideoBlocked(v),
                  ) ||
                  _addingBvid != null ||
                  _openingBvid != null
              ? null
              : () => setState(() => _selection.start()),
        ),
      PopupMenuButton<CreatorVideoOrder>(
        key: const Key('creator-video-order'),
        initialValue: _videoOrder,
        tooltip: '投稿排序',
        onSelected: _selectVideoOrder,
        itemBuilder: (_) => [
          for (final order in CreatorVideoOrder.values)
            PopupMenuItem(value: order, child: Text(_videoOrderLabel(order))),
        ],
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort_rounded, size: 19),
              const SizedBox(width: 5),
              Text(_videoOrderLabel(_videoOrder)),
            ],
          ),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth /
                  (MediaQuery.textScalerOf(context).scale(14) / 14) <
              240;
          return stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    count,
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: controls,
                    ),
                  ],
                )
              : Row(children: [count, const Spacer(), ...controls]);
        },
      ),
    );
  }

  /// 读取当前标签下一页并按业务主键去重合并。
  Future<bool> _loadMore({bool forLocation = false}) async {
    if (_loadingContent || _loadingMore || !_hasMore || _page == 0) {
      return false;
    }
    final _CreatorTab requestedTab = _selectedTab;
    final generation = _contentGeneration;
    final requestedPage = _page + 1;
    bool isCurrent() =>
        mounted &&
        requestedTab == _selectedTab &&
        generation == _contentGeneration;

    setState(() => _loadingMore = true);
    try {
      final CreatorContentPage<Object> result = await _loadContentPage(
        requestedTab,
        requestedPage,
      );
      if (!isCurrent()) return false;
      setState(() {
        _loadingMore = false;
        if (result.page == requestedPage) {
          _items = _mergeContent(_items, result.items, requestedTab);
          _page = result.page;
          _hasMore = result.hasMore;
        }
      });
      return result.page == requestedPage;
    } catch (error) {
      if (!isCurrent()) return false;
      setState(() => _loadingMore = false);
      if (!forLocation) _showMessage('加载更多失败：$error');
      return false;
    }
  }

  String? get _currentPlaybackBvid {
    final playback = widget.currentPlayback;
    return playback != null &&
            widget.mid > 0 &&
            playback.ownerMid == widget.mid &&
            playback.accountRevision == CacheLifecycle.account.value &&
            playback.bvid.isNotEmpty
        ? playback.bvid
        : null;
  }

  void _cancelVideoLocation() {
    _locationGeneration++;
    _locatingCurrentVideo = false;
    _highlightTimer?.cancel();
    _highlightedVideo = null;
  }

  bool _matchesPlayingUpload(CreatorVideo item, String bvid) =>
      item.bvid == bvid && (item.ownerMid == 0 || item.ownerMid == widget.mid);

  Future<void> _locateCurrentVideo() async {
    final bvid = _currentPlaybackBvid;
    if (bvid == null || _locatingCurrentVideo || _loadingMore) return;
    setState(() {
      _cancelVideoLocation();
      _locatingCurrentVideo = true;
    });
    final operation = _locationGeneration;
    final mid = widget.mid;
    final switchToUploads = _selectedTab != _CreatorTab.videos;
    final clearSearch =
        _videoKeyword.isNotEmpty &&
        (switchToUploads ||
            !_items.whereType<CreatorVideo>().any(
              (item) =>
                  _matchesPlayingUpload(item, bvid) &&
                  !_isCreatorVideoBlocked(item),
            ));
    Future<void>? firstPage;
    if (switchToUploads || clearSearch || _contentError != null) {
      if (switchToUploads) {
        _selectedTab = _CreatorTab.videos;
        _tabController.index = _CreatorTab.videos.index;
      }
      if (clearSearch) {
        _videoKeyword = '';
        _videoSearchController.clear();
      }
      FocusScope.of(context).unfocus();
      firstPage = _loadFirstContentPage(keepVideoLocation: true);
    }
    final generation = _contentGeneration;
    final rulesRevision = discoveryBlocklistGeneration;
    bool isCurrent() =>
        mounted &&
        operation == _locationGeneration &&
        generation == _contentGeneration &&
        discoveryBlocklistGeneration == rulesRevision &&
        discoveryBlocklistActionsReady &&
        !_selection.active &&
        widget.mid == mid &&
        _currentPlaybackBvid == bvid &&
        _selectedTab == _CreatorTab.videos &&
        ModalRoute.of(context)?.isCurrent != false;

    try {
      await firstPage;
      if (!isCurrent()) return;
      var pages = 0;
      while (_contentError == null) {
        final videos = _items.cast<CreatorVideo>();
        final visible = _visibleCreatorVideos(videos);
        final index = visible.indexWhere(
          (item) => _matchesPlayingUpload(item, bvid),
        );
        if (index >= 0) {
          await _scrollToPlayingUpload(visible, index, isCurrent);
          return;
        }
        // A video hidden by the local blocklist must not be revealed by locating.
        if (!_hasMore ||
            videos.any((item) => _matchesPlayingUpload(item, bvid))) {
          _showMessage('未在公开投稿中找到当前视频');
          return;
        }
        if (pages++ >= _maximumLocationPages) {
          _showMessage('暂未找到当前视频，可继续定位');
          return;
        }
        final loaded = await _loadMore(forLocation: true);
        if (!isCurrent()) return;
        if (!loaded) break;
      }
      _showMessage('投稿加载失败，请重试');
    } finally {
      if (mounted && operation == _locationGeneration) {
        setState(() => _locatingCurrentVideo = false);
      }
    }
  }

  RenderBox? _videoRow(String bvid) {
    final render = _videoRowKeys[bvid]?.currentContext?.findRenderObject();
    return render is RenderBox && render.attached && render.hasSize
        ? render
        : null;
  }

  /// The lazy list only lays out nearby rows. Seek using measured row offsets,
  /// then align the exact render box; this also handles variable text heights.
  Future<void> _scrollToPlayingUpload(
    List<CreatorVideo> visible,
    int index,
    bool Function() isCurrent,
  ) async {
    final bvid = visible[index].bvid;
    final operation = _locationGeneration;
    double lower = 0;
    double upper = double.infinity;
    for (var attempt = 0; attempt < 12; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !isCurrent() || !_isVideoDisplayed(bvid)) return;
      final controller = _videoListController;
      if (controller == null || !controller.hasClients) continue;
      final position = controller.position;
      if (!position.hasContentDimensions) continue;

      final row = _videoRow(bvid);
      if (row != null) {
        setState(() => _highlightedVideo = bvid);
        await position.ensureVisible(
          row,
          alignment: .18,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 230),
          curve: Curves.easeOutCubic,
        );
        if (isCurrent()) {
          _highlightTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _highlightedVideo = null);
          });
        } else if (mounted && operation == _locationGeneration) {
          setState(() => _highlightedVideo = null);
        }
        return;
      }

      final built = <(int, RenderBox)>[
        for (var i = 0; i < visible.length; i++)
          if (_videoRow(visible[i].bvid) case final row?) (i, row),
      ];
      if (built.isEmpty) continue;
      final first = built.first;
      final last = built.last;
      final viewport = RenderAbstractViewport.of(first.$2);
      final columns =
          viewport is RenderBox &&
              (viewport as RenderBox).size.width >= _videoListBreakpoint
          ? 2
          : 1;
      final firstOffset = viewport.getOffsetToReveal(first.$2, 0).offset;
      final lastOffset = viewport.getOffsetToReveal(last.$2, 0).offset;
      final rowCount = last.$1 ~/ columns - first.$1 ~/ columns;
      final stride = rowCount > 0
          ? (lastOffset - firstOffset) / rowCount
          : first.$2.size.height + _videoRowSpacing;
      final before = index < first.$1;
      if (before) {
        upper = position.pixels < upper ? position.pixels : upper;
      } else {
        lower = position.pixels > lower ? position.pixels : lower;
      }
      var offset =
          firstOffset +
          (index ~/ columns - first.$1 ~/ columns) * stride -
          position.viewportDimension * .18;
      if (offset <= lower || offset >= upper) {
        offset = upper.isFinite
            ? (lower + upper) / 2
            : position.pixels + position.viewportDimension;
      }
      position.jumpTo(
        offset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    }
    if (isCurrent()) _showMessage('暂时无法定位当前视频');
  }

  /// 按 BV、文章编号或合集编号合并分页内容，避免重复卡片。
  List<Object> _mergeContent(
    List<Object> current,
    List<Object> incoming,
    _CreatorTab tab,
  ) {
    final Set<String> keys = current
        .map((Object item) => _contentKey(item, tab))
        .toSet();
    return List<Object>.unmodifiable(<Object>[
      ...current,
      ...incoming.where((Object item) {
        final key = _contentKey(item, tab);
        return key.isNotEmpty && keys.add(key);
      }),
    ]);
  }

  /// 返回不同内容类型的稳定主键，用于分页去重。
  String _contentKey(Object item, _CreatorTab tab) {
    switch (tab) {
      case _CreatorTab.videos:
        return (item as CreatorVideo).bvid;
      case _CreatorTab.articles:
        return (item as CreatorArticle).id.toString();
      case _CreatorTab.collections:
        return (item as CreatorCollection).id.toString();
    }
  }

  /// 为当前已经显示、但列表接口没有集数的投稿安排一次视频详情补查。
  void _schedulePartCountFallback(CreatorVideo item) {
    if (item.partCount > 1 || _resolvedPartCounts.containsKey(item.bvid)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isVideoDisplayed(item.bvid)) {
        return;
      }
      if (!_partCountLookupAttemptedBvids.add(item.bvid)) {
        return;
      }
      _partCountLookupQueue.addLast(item);
      _pumpPartCountLookups();
    });
  }

  bool _isCreatorVideoBlocked(CreatorVideo item) =>
      discoveryBlocklist.isNotEmpty &&
      blocksCreatorPost(
        discoveryBlocklist,
        item,
        profileMid: widget.mid,
        profileName: _profile?.name ?? widget.initialName,
      );

  List<CreatorVideo> _visibleCreatorVideos(List<CreatorVideo> loaded) =>
      !discoveryBlocklist.isNotEmpty
      ? loaded
      : loaded.where((item) => !_isCreatorVideoBlocked(item)).toList();

  @override
  void onDiscoveryBlocklistChanged() => _reconcileDiscoverySelection();

  void _reconcileDiscoverySelection() {
    _selectionVisibilityEpoch++;
    if (_selection.active && _selectedTab == _CreatorTab.videos) {
      _selection.keepVisible(
        _visibleCreatorVideos(_items.cast<CreatorVideo>()).map((v) => v.bvid),
      );
    }
  }

  bool Function() _visibleSourceGuard(List<CreatorVideo> videos) {
    final generation = _contentGeneration;
    return () =>
        mounted &&
        _selectedTab == _CreatorTab.videos &&
        generation == _contentGeneration &&
        discoveryBlocklistActionsReady &&
        !videos.any(_isCreatorVideoBlocked);
  }

  /// 判断 BV 号是否仍属于当前投稿结果，防止搜索或切页后更新旧列表。
  bool _isVideoDisplayed(String bvid) {
    return _selectedTab == _CreatorTab.videos &&
        discoveryBlocklistActionsReady &&
        _items.whereType<CreatorVideo>().any(
          (CreatorVideo item) =>
              item.bvid == bvid && !_isCreatorVideoBlocked(item),
        );
  }

  /// 在最多两个并发请求的限制内依次补查投稿详情，避免同时请求整屏视频。
  void _pumpPartCountLookups() {
    while (_activePartCountLookups < _maximumPartCountLookupConcurrency &&
        _partCountLookupQueue.isNotEmpty) {
      final CreatorVideo item = _partCountLookupQueue.removeFirst();
      if (!_isVideoDisplayed(item.bvid)) {
        continue;
      }
      _activePartCountLookups += 1;
      unawaited(_resolvePartCountFallback(item));
    }
  }

  /// 查询完整视频详情，并把真实分P数量缓存到对应投稿卡片。
  Future<void> _resolvePartCountFallback(CreatorVideo item) async {
    try {
      final VideoPreview video = await _videoService.lookupVideo(item.bvid);
      final int partCount = video.parts.length;
      if (mounted && partCount > 1 && _isVideoDisplayed(item.bvid)) {
        setState(() => _resolvedPartCounts[item.bvid] = partCount);
      }
    } catch (_) {
      // 集数补查失败不影响投稿列表和点击播放，同一 BV 本次页面只尝试一次。
    } finally {
      _activePartCountLookups -= 1;
      if (mounted) {
        _pumpPartCountLookups();
      }
    }
  }

  /// 返回列表接口或详情补查得到的较可靠集数，单P始终保持为 1。
  int _partCountFor(CreatorVideo item) {
    return _resolvedPartCounts[item.bvid] ?? item.partCount;
  }

  /// 查询投稿的完整详情并进入播放器。
  Future<void> _openVideo(CreatorVideo item) async {
    if (_openingBvid != null ||
        _addingBvid != null ||
        !_isVideoDisplayed(item.bvid)) {
      return;
    }
    final stillVisible = _visibleSourceGuard([item]);
    setState(() => _openingBvid = item.bvid);
    try {
      final VideoPreview video = await _videoService.lookupVideo(item.bvid);
      if (!mounted || !stillVisible()) return;
      await Navigator.of(context).pushNamed(AppRoutes.player, arguments: video);
      await _loadWatchHistory();
      await _loadLearningListMembership();
    } catch (error) {
      if (mounted) {
        _showMessage('无法打开视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingBvid = null);
      }
    }
  }

  /// Opens explicit P selection even when another P of the BV already exists.
  Future<void> _toggleVideoLearningList(CreatorVideo item) async {
    if (_openingBvid != null ||
        _addingBvid != null ||
        !_isVideoDisplayed(item.bvid)) {
      return;
    }
    final stillVisible = _visibleSourceGuard([item]);
    setState(() => _addingBvid = item.bvid);
    try {
      final video = await _videoService.lookupVideo(item.bvid);
      if (!mounted || !stillVisible()) return;
      setState(() => _addingBvid = null);
      final result = await LearningAddSheet.show(
        context,
        video: video,
        service: _learningListService,
        canConfirm: stillVisible,
      );
      if (result == null || !mounted) return;
      await _loadLearningListMembership();
      if (mounted) _showMessage('已加入所选分 P，已有进度已保留。');
    } catch (_) {
      if (mounted) _showMessage('详情读取或保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _addingBvid = null);
    }
  }

  /// 打开 UGC 合集详情，合集中的每一项仍会作为独立视频查询和播放。
  Future<void> _openCollection(CreatorCollection collection) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 合集详情构建函数复用当前公开服务与视频详情服务。
        builder: (BuildContext context) => CollectionDetailPage(
          collection: collection,
          publicContentService: _publicContentService,
          videoService: _videoService,
          learningListService: _learningListService,
        ),
      ),
    );
    await _loadLearningListMembership();
  }

  /// 显示统一三秒轻量提示，不改变主页已加载内容。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 将大数字格式化为万单位，保持主页统计紧凑。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  /// 将日期格式化为年月日，未知日期不占用额外空间。
  String _formatDate(DateTime? value) {
    if (value == null) {
      return '';
    }
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  /// 将视频时长格式化为 mm:ss 或 h:mm:ss。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建带磁盘缓存的头像或封面，失败时显示本地图标。
  Widget _buildImage(
    String url, {
    required double width,
    required double height,
    required BoxFit fit,
    IconData placeholderIcon = Icons.image_outlined,
  }) {
    if (url.isEmpty) {
      return _buildImagePlaceholder(width, height, placeholderIcon);
    }
    return AppNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: 480,
      placeholder: (BuildContext context, String value) =>
          _buildImagePlaceholder(width, height, placeholderIcon),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildImagePlaceholder(width, height, placeholderIcon),
    );
  }

  /// 创建远程图片加载中或失败时的固定尺寸占位。
  Widget _buildImagePlaceholder(double width, double height, IconData icon) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(icon),
      ),
    );
  }

  /// 创建关注、粉丝、获赞三列只读统计。
  Widget _buildStats(CreatorProfile profile) {
    final items = [
      (_formatCount(profile.followerCount), '粉丝'),
      (_formatCount(profile.followingCount), '关注'),
      (_formatCount(profile.likeCount), '获赞'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(20) / 20;
        if (constraints.maxWidth / scale < 190) {
          return Column(
            children: [
              for (final item in items)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.$2,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      item.$1,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
            ],
          );
        }
        return Row(
          children: [
            for (final item in items)
              Expanded(child: _buildStatItem(item.$1, item.$2)),
          ],
        );
      },
    );
  }

  /// 创建单个主页统计数字和文字标签。
  Widget _buildStatItem(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// 关注操作与资料内容栏等宽，保留忙碌和错误处理。
  Widget _buildFollowButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonalIcon(
        key: const Key('creator-follow-button'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: _followBusy ? null : () => unawaited(_toggleFollowing()),
        icon: _followBusy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                _isFollowing == true
                    ? Icons.check_rounded
                    : Icons.person_add_alt_1_rounded,
              ),
        label: Text(
          _followBusy
              ? '处理中…'
              : _isFollowing == true
              ? '取消关注'
              : '关注',
        ),
      ),
    );
  }

  Widget _buildSubscriptionButton() => FocusSubscriptionButton(
    addDirectly: true,
    service: widget.subscriptionService,
    source: SubscriptionSource(
      kind: SubscriptionKind.creator,
      mid: widget.mid,
      name: _profile?.name ?? widget.initialName,
      imageUrl: _profileAvatarUrl,
      token: DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );

  Widget _buildSearchField() => TextField(
    key: const Key('creator-video-search'),
    controller: _videoSearchController,
    autofocus: true,
    textInputAction: TextInputAction.search,
    onSubmitted: _submitVideoSearch,
    decoration: InputDecoration(
      hintText: '搜索该 UP 主的投稿',
      isDense: true,
      suffixIcon: IconButton(
        onPressed: _submitVideoSearch,
        icon: const Icon(Icons.arrow_forward_rounded),
        tooltip: '提交投稿搜索',
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );

  /// 创建昵称、UID、认证、简介和错误重试组成的资料文字区，供宽窄头部共享。
  Widget _buildProfileDescription({
    required String name,
    required String officialDescription,
    required String sign,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            _buildSubscriptionButton(),
          ],
        ),
        Text('UID：${widget.mid}', style: Theme.of(context).textTheme.bodySmall),
        if (officialDescription.isNotEmpty) ...<Widget>[
          const SizedBox(height: 5),
          Row(
            key: const Key('creator-certification'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.verified_rounded,
                size: 17,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '认证：$officialDescription',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (sign.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          _buildExpandableProfileSign(sign),
        ],
        if (_profileError != null) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _profileError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                // 资料重试按钮函数只重新读取主页头部。
                onPressed: _loadProfile,
                child: const Text('重试'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 创建资料统计区，并在资料仍加载时覆盖小型进度指示。
  Widget _buildProfileStatsPanel(
    CreatorProfile profile, {
    required bool showLoading,
  }) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        _buildStats(profile),
        if (showLoading)
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  /// 创建可随 Sliver 收起的响应式资料头，宽屏横向展开、手机保持紧凑纵向结构。
  Widget _buildProfileHeader() {
    final CreatorProfile? profile = _profile;
    final String name = profile?.name.isNotEmpty == true
        ? profile!.name
        : (widget.initialName.isEmpty ? 'UP 主主页' : widget.initialName);
    final String avatarUrl = _profileAvatarUrl;
    final String officialDescription =
        profile?.officialDescription.isNotEmpty == true
        ? profile!.officialDescription
        : widget.initialOfficialDescription;
    final String sign = profile?.sign.isNotEmpty == true
        ? profile!.sign
        : widget.initialSign;
    final CreatorProfile displayProfile =
        profile ??
        CreatorProfile(
          mid: widget.mid,
          name: name,
          avatarUrl: avatarUrl,
          sign: '',
          officialDescription: '',
        );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool useWideHeader = constraints.maxWidth >= 900;
        final bool stackStats =
            constraints.maxWidth /
                MediaQuery.textScalerOf(context).scale(14) *
                14 <
            260;
        return Padding(
          key: const Key('creator-profile-header'),
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
          child: useWideHeader
              ? Row(
                  key: const Key('creator-profile-wide-header'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    ClipOval(
                      child: _buildImage(
                        avatarUrl,
                        width: 96,
                        height: 96,
                        fit: BoxFit.cover,
                        placeholderIcon: Icons.person_rounded,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildProfileDescription(
                            name: name,
                            officialDescription: officialDescription,
                            sign: sign,
                          ),
                          const SizedBox(height: 10),
                          _buildFollowButton(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    SizedBox(
                      key: const Key('creator-profile-wide-stats'),
                      width: 320,
                      child: _buildProfileStatsPanel(
                        displayProfile,
                        showLoading: profile == null && _loadingProfile,
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Flex(
                      direction: stackStats ? Axis.vertical : Axis.horizontal,
                      crossAxisAlignment: stackStats
                          ? CrossAxisAlignment.stretch
                          : CrossAxisAlignment.center,
                      children: <Widget>[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ClipOval(
                            child: _buildImage(
                              avatarUrl,
                              width: 82,
                              height: 82,
                              fit: BoxFit.cover,
                              placeholderIcon: Icons.person_rounded,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: stackStats ? 0 : 14,
                          height: stackStats ? 12 : 0,
                        ),
                        Flexible(
                          flex: stackStats ? 0 : 1,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildProfileStatsPanel(
                                displayProfile,
                                showLoading: profile == null && _loadingProfile,
                              ),
                              const SizedBox(height: 8),
                              _buildFollowButton(),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildProfileDescription(
                      name: name,
                      officialDescription: officialDescription,
                      sign: sign,
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// 创建最多两行的 UP 简介；真实溢出时提供展开和收起，不再静默隐藏后半段。
  Widget _buildExpandableProfileSign(String sign) {
    final TextStyle style =
        Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: sign, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 2,
        )..layout(maxWidth: constraints.maxWidth);
        final bool exceedsTwoLines = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              sign,
              key: const Key('creator-profile-sign'),
              maxLines: _profileSignExpanded ? null : 2,
              overflow: _profileSignExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: style,
            ),
            if (exceedsTwoLines || _profileSignExpanded)
              TextButton(
                key: const Key('toggle-creator-profile-sign'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(
                  () => _profileSignExpanded = !_profileSignExpanded,
                ),
                child: Text(_profileSignExpanded ? '收起简介' : '展开简介'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _saveSelected() async {
    if (_batchBusy ||
        !discoveryBlocklistActionsReady ||
        _selection.ids.isEmpty) {
      return;
    }
    final videos = _visibleCreatorVideos(_items.cast<CreatorVideo>())
        .where((item) => _selection.ids.contains(item.bvid))
        .toList(growable: false);
    setState(() => _batchBusy = true);
    try {
      final saved = await _batchActions.run(
        context,
        videos: videos,
        sourceIsCurrent: _visibleSourceGuard(videos),
        ownerName: _profile?.name ?? widget.initialName,
      );
      if (mounted && saved) {
        setState(_selection.end);
        await _loadLearningListMembership();
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _saveOne(
    CreatorVideo item,
    VideoSaveDestination destination,
  ) async {
    if (_batchBusy ||
        _openingBvid != null ||
        _addingBvid != null ||
        !_isVideoDisplayed(item.bvid)) {
      return;
    }
    if (destination == VideoSaveDestination.learning) {
      await _toggleVideoLearningList(item);
      return;
    }
    setState(() => _batchBusy = true);
    try {
      await _batchActions.run(
        context,
        videos: [item],
        sourceIsCurrent: _visibleSourceGuard([item]),
        ownerName: _profile?.name ?? widget.initialName,
        destination: destination,
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  void _changeVisibleSelection(CreatorVideo item, {bool start = false}) {
    if (_batchBusy ||
        _openingBvid != null ||
        _addingBvid != null ||
        !_isVideoDisplayed(item.bvid)) {
      return;
    }
    setState(
      () => start ? _selection.start(item.bvid) : _selection.toggle(item.bvid),
    );
  }

  /// 创建横向投稿列表项，左侧使用 16:9 封面，右侧显示标题、日期和公开统计。
  Widget _buildVideoCard(CreatorVideo item, Key handleKey) {
    final bool opening = _openingBvid == item.bvid;
    final bool adding = _addingBvid == item.bvid;
    final bool added = _learningListBvids.contains(item.bvid);
    final selecting = _selection.active;
    final selected = _selection.ids.contains(item.bvid);
    final WatchHistoryEntry? watchHistory = _watchHistoryByBvid[item.bvid];
    _schedulePartCountFallback(item);
    final int partCount = _partCountFor(item);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        const selectionInset = 6.0;
        final double thumbnailWidth = selecting
            ? ((constraints.maxWidth - selectionInset * 2) * .36)
                  .clamp(0, 184)
                  .toDouble()
            : textScale > 1.4 && constraints.maxWidth < 450
            ? constraints.maxWidth * .34
            : (constraints.maxWidth * .42).clamp(148, 196).toDouble();
        final thumbnailHeight = selecting
            ? thumbnailWidth * 9 / 16
            : (thumbnailWidth * 9 / 16).clamp(64, 112).toDouble();
        final colors = Theme.of(context).colorScheme;
        final onSurfaceVariant = colors.onSurfaceVariant;
        return Material(
          color: selected
              ? colors.primary.withValues(
                  alpha: colors.brightness == Brightness.dark ? .14 : .08,
                )
              : _highlightedVideo == item.bvid
              ? colors.primaryContainer.withValues(alpha: .42)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(selecting ? 16 : 12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('creator-video-${item.bvid}'),
            // 投稿行点击函数查询完整详情后进入播放器。
            onTap:
                !discoveryBlocklistActionsReady ||
                    _batchBusy ||
                    opening ||
                    adding
                ? null
                : _selection.active
                ? () => _changeVisibleSelection(item)
                : () => unawaited(_openVideo(item)),
            onLongPress:
                !discoveryBlocklistActionsReady ||
                    _selection.active ||
                    _batchBusy ||
                    _addingBvid != null ||
                    _openingBvid != null
                ? null
                : () => _changeVisibleSelection(item, start: true),
            child: Padding(
              padding: selecting
                  ? const EdgeInsets.all(selectionInset)
                  : EdgeInsets.zero,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: selecting
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: <Widget>[
                    ClipRRect(
                      key: Key('creator-video-thumbnail-${item.bvid}'),
                      borderRadius: BorderRadius.circular(11),
                      child: Stack(
                        children: <Widget>[
                          _buildImage(
                            item.coverUrl,
                            width: thumbnailWidth,
                            height: thumbnailHeight,
                            fit: BoxFit.cover,
                            placeholderIcon: Icons.video_library_outlined,
                          ),
                          if (watchHistory != null)
                            Positioned(
                              left: 5,
                              top: 5,
                              child: WatchHistoryBadge(entry: watchHistory),
                            ),
                          if (partCount > 1)
                            Positioned(
                              right: 5,
                              top: 5,
                              child: DecoratedBox(
                                key: Key('creator-video-parts-${item.bvid}'),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    '$partCount集',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            right: 5,
                            bottom: 5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                child: Text(
                                  _formatDuration(item.duration),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (opening)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black38,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            key: Key('creator-video-title-${item.bvid}'),
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDate(item.publishedAt),
                            maxLines: 1,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: FittedBox(
                                  alignment: Alignment.centerLeft,
                                  fit: BoxFit.scaleDown,
                                  child: Row(
                                    children: <Widget>[
                                      Icon(
                                        Icons.play_circle_outline_rounded,
                                        size: 15,
                                        color: onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        _formatCount(item.stats.viewCount),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      const SizedBox(width: 10),
                                      Icon(
                                        Icons.subtitles_outlined,
                                        size: 15,
                                        color: onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        _formatCount(item.stats.danmakuCount),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!selecting) ...[
                                const SizedBox(width: 4),
                                PopupMenuButton<VideoSaveDestination>(
                                  key: Key('add-creator-video-${item.bvid}'),
                                  tooltip: '更多操作：${item.title}',
                                  enabled:
                                      discoveryBlocklistActionsReady &&
                                      !_batchBusy &&
                                      _openingBvid == null &&
                                      _addingBvid == null,
                                  onSelected: (destination) =>
                                      unawaited(_saveOne(item, destination)),
                                  icon: adding
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.more_horiz_rounded),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: VideoSaveDestination.learning,
                                      child: Text(
                                        added ? '学习清单 · 选择更多分 P' : '加入学习清单',
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: VideoSaveDestination.favorites,
                                      child: Text('加入收藏夹'),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (selecting) ...[
                      const SizedBox(width: 4),
                      SizedBox.square(
                        key: handleKey,
                        dimension: 48,
                        child: Checkbox(
                          key: ValueKey('check-creator-${item.bvid}'),
                          semanticLabel: '选择 ${item.title}',
                          value: selected,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          visualDensity: VisualDensity.standard,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          side: BorderSide(color: colors.outline, width: 1.5),
                          onChanged:
                              _batchBusy || !discoveryBlocklistActionsReady
                              ? null
                              : (_) => _changeVisibleSelection(item),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 创建只读专栏摘要卡片；当前不伪装尚未实现的站内文章阅读器。
  Widget _buildArticleCard(CreatorArticle item) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (item.coverUrl.isNotEmpty) ...<Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _buildImage(
                  item.coverUrl,
                  width: 116,
                  height: 78,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (item.summary.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      item.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '${_formatDate(item.publishedAt)} · ${_formatCount(item.viewCount)}阅读',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建 UGC 合集卡片，明确显示其中是多支独立视频。
  Widget _buildCollectionCard(CreatorCollection item) {
    return Card(
      key: Key('creator-collection-${item.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        // 合集卡点击函数进入独立合集详情页。
        onTap: () => unawaited(_openCollection(item)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildImage(
                    item.coverUrl,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.collections_bookmark_outlined,
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${item.totalCount} 支视频',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建当前标签的加载、错误、空状态或内容列表。
  Widget _buildContent() {
    if (_selectedTab == _CreatorTab.videos &&
        !discoveryBlocklistActionsReady &&
        (!discoveryBlocklistReady || _items.isEmpty)) {
      return ListView(children: [buildDiscoveryBlocklistStatus()]);
    }
    if (_loadingContent && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_contentError != null && _items.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline_rounded, size: 44),
              const SizedBox(height: 12),
              Text(_contentError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                // 内容重试按钮函数重新读取当前标签第一页。
                onPressed: _loadFirstContentPage,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(switch (_selectedTab) {
          _CreatorTab.videos => '暂无公开投稿',
          _CreatorTab.articles => '暂无公开专栏',
          _CreatorTab.collections => '暂无公开合集',
        }),
      );
    }
    if (_selectedTab == _CreatorTab.articles) {
      return RefreshIndicator(
        // 专栏下拉刷新函数重新读取当前标签第一页。
        onRefresh: _loadFirstContentPage,
        child: AdaptiveTwoColumnList(
          key: const Key('creator-article-list'),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          itemCount: _items.length,
          footer: _buildLoadingFooter(),
          mainAxisSpacing: 10,
          itemBuilder: (BuildContext context, int index) {
            return _buildArticleCard(_items[index] as CreatorArticle);
          },
        ),
      );
    }
    if (_selectedTab == _CreatorTab.videos) {
      final videos = _visibleCreatorVideos(_items.cast<CreatorVideo>());
      final hidden = _items.length - videos.length;
      final epoch = _selectionVisibilityEpoch;
      return Builder(
        builder: (context) {
          final inner = PrimaryScrollController.of(context);
          _videoListController = inner;
          return DragSelectionRegion(
            key: ValueKey('creator-drag-$_contentGeneration-$epoch'),
            controller: inner,
            itemCount: videos.length,
            enabled:
                discoveryBlocklistActionsReady &&
                _selection.active &&
                !_batchBusy,
            checkedAt: (index) => _selection.ids.contains(videos[index].bvid),
            onDragUpdate: (update) {
              if (discoveryBlocklistActionsReady &&
                  epoch == _selectionVisibilityEpoch) {
                setState(() => _selection.range(update, videos));
              }
            },
            builder: (context, dragging) => RefreshIndicator(
              notificationPredicate: (notification) =>
                  !_selection.active && notification.depth == 0,
              onRefresh: _loadFirstContentPage,
              child: AdaptiveTwoColumnList(
                key: const Key('creator-video-list'),
                controller: inner,
                physics: dragging
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: videos.length,
                header: hidden > 0 || !discoveryBlocklistActionsReady
                    ? Column(
                        children: [
                          if (!discoveryBlocklistActionsReady)
                            buildDiscoveryBlocklistStatus(),
                          if (hidden > 0)
                            DiscoveryBlocklistNotice(
                              hiddenCount: hidden,
                              onLoadNextPage: !_loadingMore && _hasMore
                                  ? () => unawaited(_loadMore())
                                  : null,
                            ),
                        ],
                      )
                    : null,
                footer: _buildLoadingFooter(),
                breakpoint: _videoListBreakpoint,
                mainAxisSpacing: _videoRowSpacing,
                itemBuilder: (context, index) {
                  final item = videos[index];
                  return DragSelectionTarget(
                    key: _currentPlaybackBvid == null
                        ? null
                        : _videoRowKeys.putIfAbsent(item.bvid, GlobalKey.new),
                    index: index,
                    builder: (context, key) => _buildVideoCard(item, key),
                  );
                },
              ),
            ),
          );
        },
      );
    }
    return RefreshIndicator(
      // 合集网格下拉刷新函数重新读取当前标签第一页。
      onRefresh: _loadFirstContentPage,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columnCount = constraints.maxWidth >= 1120
              ? 4
              : constraints.maxWidth >= 760
              ? 3
              : 2;
          return GridView.builder(
            key: const Key('creator-collection-grid'),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columnCount,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.9,
            ),
            itemCount: _items.length + 1,
            // 合集网格构建函数在最后一格保留分页状态，其余格展示独立合集卡。
            itemBuilder: (BuildContext context, int index) {
              if (index == _items.length) {
                return _buildLoadingFooter();
              }
              return _buildCollectionCard(_items[index] as CreatorCollection);
            },
          );
        },
      ),
    );
  }

  /// 创建分页加载状态，列表结束时保持少量底部留白。
  Widget _buildLoadingFooter() {
    return _loadingMore
        ? const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : const SizedBox.shrink();
  }

  /// 创建带可折叠资料头的公开主页，滚动后固定顶栏和内容标签并扩大视频区域。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selection.active,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _selection.active && !_batchBusy) {
          setState(_selection.end);
        }
      },
      child: Scaffold(
        appBar: _selection.active
            ? AppBar(
                leading: IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _batchBusy ? null : () => setState(_selection.end),
                ),
                title: Text(
                  '已选 ${_selection.ids.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  TextButton.icon(
                    key: const Key('creator-batch-save'),
                    onPressed:
                        _batchBusy ||
                            !discoveryBlocklistActionsReady ||
                            _selection.ids.isEmpty
                        ? null
                        : _saveSelected,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加到'),
                  ),
                ],
              )
            : AppBar(
                key: const Key('creator-profile-app-bar'),
                title:
                    _selectedTab == _CreatorTab.videos && _videoSearchExpanded
                    ? _buildSearchField()
                    : null,
                actions: <Widget>[
                  if (_currentPlaybackBvid != null)
                    IconButton(
                      key: const Key('creator-locate-current-video'),
                      tooltip: '定位到当前播放视频',
                      onPressed:
                          _locatingCurrentVideo ||
                              _loadingMore ||
                              (_loadingContent &&
                                  _selectedTab == _CreatorTab.videos) ||
                              !discoveryBlocklistActionsReady
                          ? null
                          : () => unawaited(_locateCurrentVideo()),
                      icon: _locatingCurrentVideo
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location_rounded),
                    ),
                  if (_selectedTab == _CreatorTab.videos)
                    IconButton(
                      // 搜索按钮函数展开或收起当前 UP 主的投稿搜索框。
                      onPressed: _toggleVideoSearch,
                      icon: Icon(
                        _videoSearchExpanded
                            ? Icons.search_off_rounded
                            : Icons.search_rounded,
                      ),
                      tooltip: _videoSearchExpanded ? '收起投稿搜索' : '搜索投稿',
                    ),
                ],
              ),
        body: AdaptivePageFrame(
          maxWidth: 1280,
          child: NestedScrollView(
            key: const Key('creator-profile-scroll'),
            controller: _profileScrollController,
            headerSliverBuilder:
                (BuildContext context, bool innerBoxIsScrolled) {
                  return <Widget>[
                    SliverToBoxAdapter(child: _buildProfileHeader()),
                    SliverOverlapAbsorber(
                      handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                        context,
                      ),
                      sliver: SliverPersistentHeader(
                        pinned: true,
                        delegate: _CreatorTabsHeader(
                          color: Theme.of(context).colorScheme.surface,
                          tabs: TabBar(
                            controller: _tabController,
                            tabs: const <Tab>[
                              Tab(text: '投稿'),
                              Tab(text: '专栏'),
                              Tab(text: '合集'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ];
                },
            // 吸收固定标签的重叠后，给不可滚动的排序工具栏保留同高空间。
            body: Padding(
              padding: const EdgeInsets.only(top: kTextTabBarHeight),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: <Widget>[
                    // 资料头高于视口时，工具栏随内容空间出现，不压缩字号或溢出。
                    if (_selectedTab == _CreatorTab.videos &&
                        constraints.maxHeight >=
                            MediaQuery.textScalerOf(context).scale(14) /
                                14 *
                                64)
                      _buildVideoToolbar(),
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                        // 滚动通知函数协调折叠资料头，并在接近底部时触发分页。
                        onNotification: _handleContentScrollNotification,
                        child: _buildContent(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreatorTabsHeader extends SliverPersistentHeaderDelegate {
  _CreatorTabsHeader({required this.tabs, required this.color});
  final TabBar tabs;
  final Color color;
  @override
  double get minExtent => tabs.preferredSize.height;
  @override
  double get maxExtent => minExtent;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(color: color, child: tabs);
  @override
  bool shouldRebuild(_CreatorTabsHeader oldDelegate) =>
      oldDelegate.tabs != tabs || oldDelegate.color != color;
}
