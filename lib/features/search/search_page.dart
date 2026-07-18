import 'dart:async';
import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/user_search.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/search_history_service.dart';
import '../profile/user_profile_page.dart';

/// 标识搜索页当前查找公开视频还是公开用户。
enum _SearchMode { videos, users }

/// 保存搜索筛选面板中的内容分区编号和中文名称。
class _SearchCategory {
  /// 创建一个可以传给 B 站搜索接口的内容分区选项。
  const _SearchCategory(this.id, this.label);

  final int? id;
  final String label;
}

/// 搜索页支持关键词候选、筛选、分页、BV 直达和主动选择的视频结果。
class SearchPage extends StatefulWidget {
  /// 创建搜索页面；测试可传入不访问真实网络的服务替身。
  const SearchPage({super.key, this.service, this.userSearchService});

  final BilibiliService? service;
  final BilibiliUserSearchService? userSearchService;

  /// 创建搜索页状态，保存输入、分页、筛选、候选词和结果列表。
  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 管理关键词搜索、BV 查询、增量加载、筛选和进入播放器的页面状态。
class _SearchPageState extends State<SearchPage> {
  static const int _maxEpisodeCountLookupConcurrency = 2;
  static final RegExp _bvidPattern = RegExp(
    r'BV[0-9A-Za-z]{10}',
    caseSensitive: false,
  );
  static const List<_SearchCategory> _categories = <_SearchCategory>[
    _SearchCategory(null, '全部'),
    _SearchCategory(1, '动画'),
    _SearchCategory(13, '番剧'),
    _SearchCategory(168, '国创'),
    _SearchCategory(3, '音乐'),
    _SearchCategory(129, '舞蹈'),
    _SearchCategory(4, '游戏'),
    _SearchCategory(36, '知识'),
    _SearchCategory(188, '科技'),
    _SearchCategory(234, '运动'),
    _SearchCategory(223, '汽车'),
    _SearchCategory(160, '生活'),
    _SearchCategory(211, '美食'),
    _SearchCategory(217, '动物'),
    _SearchCategory(119, '鬼畜'),
    _SearchCategory(155, '时尚'),
    _SearchCategory(202, '资讯'),
    _SearchCategory(5, '娱乐'),
    _SearchCategory(181, '影视'),
    _SearchCategory(177, '纪录'),
    _SearchCategory(23, '电影'),
    _SearchCategory(11, '电视'),
  ];

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _resultScrollController = ScrollController();
  final SearchHistoryService _historyService = SearchHistoryService();
  final Queue<VideoSearchResult> _episodeCountLookupQueue =
      Queue<VideoSearchResult>();
  final Set<String> _episodeCountLookupAttemptedBvids = <String>{};
  final Map<String, String> _fallbackEpisodeCountTexts = <String, String>{};
  late final BilibiliService _service;
  late final BilibiliUserSearchService _userSearchService;
  Timer? _suggestionDebounce;
  VideoPreview? _directResult;
  List<VideoSearchResult> _searchResults = const <VideoSearchResult>[];
  List<String> _suggestions = const <String>[];
  String? _errorMessage;
  String? _openingBvid;
  String _activeQuery = '';
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasSubmitted = false;
  int _currentPage = 0;
  int _totalPages = 0;
  int _activeEpisodeCountLookups = 0;
  VideoSearchFilter _filter = const VideoSearchFilter();
  UserSearchFilter _userFilter = const UserSearchFilter();
  List<UserSearchResult> _userResults = const <UserSearchResult>[];
  _SearchMode _searchMode = _SearchMode.videos;
  List<String> _searchHistory = const <String>[];

  /// 页面创建后初始化服务、滚动监听、焦点监听和本机搜索记录。
  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BilibiliVideoInfoService();
    _userSearchService =
        widget.userSearchService ??
        (_service is BilibiliUserSearchService
            ? _service as BilibiliUserSearchService
            : BilibiliVideoInfoService());
    _resultScrollController.addListener(_handleResultScroll);
    _searchFocusNode.addListener(_handleSearchFocusChange);
    _loadSearchHistory();
  }

  /// 释放输入、焦点、滚动和候选词计时器，避免页面销毁后继续请求。
  @override
  void dispose() {
    _suggestionDebounce?.cancel();
    _resultScrollController
      ..removeListener(_handleResultScroll)
      ..dispose();
    _searchFocusNode
      ..removeListener(_handleSearchFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 搜索结果接近底部时自动请求下一页，并防止同一页重复加载。
  void _handleResultScroll() {
    if (!_resultScrollController.hasClients ||
        _resultScrollController.position.extentAfter > 420) {
      return;
    }
    unawaited(_loadMoreResults());
  }

  /// 焦点变化时刷新候选词区域，失去焦点后隐藏候选列表。
  void _handleSearchFocusChange() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 输入变化后延迟请求候选词，避免每输入一个字符都立即访问网络。
  void _handleSearchInputChanged(String value) {
    _suggestionDebounce?.cancel();
    final String input = value.trim();
    if (_searchMode == _SearchMode.users ||
        input.isEmpty ||
        _bvidPattern.hasMatch(input)) {
      setState(() => _suggestions = const <String>[]);
      return;
    }
    _suggestionDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_loadSuggestions(input));
    });
  }

  /// 请求并显示与当前输入完全对应的候选词，忽略已经过时的异步结果。
  Future<void> _loadSuggestions(String input) async {
    try {
      final List<String> suggestions = await _service.suggestKeywords(input);
      if (!mounted || _controller.text.trim() != input) {
        return;
      }
      setState(() => _suggestions = suggestions);
    } catch (_) {
      if (mounted && _controller.text.trim() == input) {
        setState(() => _suggestions = const <String>[]);
      }
    }
  }

  /// BV 号直接查询详情，普通文字按当前筛选条件请求第一页真实结果。
  Future<void> _submitSearch() async {
    final String input = _controller.text.trim();
    _searchFocusNode.unfocus();
    _suggestionDebounce?.cancel();
    setState(() {
      _loading = true;
      _hasSubmitted = true;
      _errorMessage = null;
      _directResult = null;
      _searchResults = const <VideoSearchResult>[];
      _userResults = const <UserSearchResult>[];
      _suggestions = const <String>[];
      _activeQuery = input;
      _currentPage = 0;
      _totalPages = 0;
    });
    try {
      if (input.isEmpty) {
        throw BilibiliLookupException(
          _searchMode == _SearchMode.videos
              ? '请输入关键词、BV 号或视频链接。'
              : '请输入要搜索的用户名。',
        );
      }
      final List<String> history = await _historyService.addHistory(input);
      final bool opensDirectly =
          _searchMode == _SearchMode.videos && _bvidPattern.hasMatch(input);
      final VideoPreview? directResult = opensDirectly
          ? await _service.lookupVideo(input)
          : null;
      final VideoSearchPage? searchPage =
          opensDirectly || _searchMode == _SearchMode.users
          ? null
          : await _service.searchVideos(input, page: 1, filter: _filter);
      final UserSearchPage? userPage = _searchMode == _SearchMode.users
          ? await _userSearchService.searchUsers(
              input,
              page: 1,
              filter: _userFilter,
            )
          : null;
      if (!mounted) {
        return;
      }
      setState(() {
        _searchHistory = history;
        _directResult = directResult;
        _searchResults = searchPage?.results ?? const <VideoSearchResult>[];
        _userResults = userPage?.results ?? const <UserSearchResult>[];
        _currentPage = searchPage?.page ?? userPage?.page ?? 0;
        _totalPages = searchPage?.totalPages ?? userPage?.totalPages ?? 0;
        _loading = false;
      });
      if (_resultScrollController.hasClients) {
        _resultScrollController.jumpTo(0);
      }
    } on BilibiliLookupException catch (error) {
      _showLookupError(error.message);
    } catch (_) {
      _showLookupError('搜索失败，请检查网络或稍后再试。');
    }
  }

  /// 请求下一页并按 BV 号去重追加，失败时保留已经显示的搜索结果。
  Future<void> _loadMoreResults() async {
    if (_loading ||
        _loadingMore ||
        _activeQuery.isEmpty ||
        (_searchMode == _SearchMode.videos &&
            _bvidPattern.hasMatch(_activeQuery)) ||
        _currentPage <= 0 ||
        _currentPage >= _totalPages) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      if (_searchMode == _SearchMode.users) {
        final UserSearchPage nextPage = await _userSearchService.searchUsers(
          _activeQuery,
          page: _currentPage + 1,
          filter: _userFilter,
        );
        if (!mounted) {
          return;
        }
        final Set<int> existingMids = _userResults
            .map((UserSearchResult result) => result.mid)
            .toSet();
        setState(() {
          _userResults = <UserSearchResult>[
            ..._userResults,
            ...nextPage.results.where(
              (UserSearchResult result) => existingMids.add(result.mid),
            ),
          ];
          _currentPage = nextPage.page;
          _totalPages = nextPage.totalPages;
          _loadingMore = false;
        });
        return;
      }
      final VideoSearchPage nextPage = await _service.searchVideos(
        _activeQuery,
        page: _currentPage + 1,
        filter: _filter,
      );
      if (!mounted) {
        return;
      }
      final Set<String> existingBvids = _searchResults
          .map((VideoSearchResult result) => result.bvid)
          .toSet();
      setState(() {
        _searchResults = <VideoSearchResult>[
          ..._searchResults,
          ...nextPage.results.where(
            (VideoSearchResult result) => existingBvids.add(result.bvid),
          ),
        ];
        _currentPage = nextPage.page;
        _totalPages = nextPage.totalPages;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingMore = false);
        _showTransientMessage('下一页加载失败，请稍后重试。');
      }
    }
  }

  /// 从本地存储加载搜索记录，并在页面仍存在时更新记录栏。
  Future<void> _loadSearchHistory() async {
    final List<String> history = await _historyService.loadHistory();
    if (mounted) {
      setState(() => _searchHistory = history);
    }
  }

  /// 将候选词或搜索记录放入输入框，并立即按当前筛选条件搜索。
  void _selectSuggestedQuery(String value) {
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
    unawaited(_submitSearch());
  }

  /// 清空设备中的搜索记录，并同步移除页面上的记录按钮。
  Future<void> _clearSearchHistory() async {
    final List<String> history = await _historyService.clearHistory();
    if (mounted) {
      setState(() => _searchHistory = history);
    }
  }

  /// 在异步搜索失败时安全更新错误状态，并清除本轮空结果。
  void _showLookupError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _loadingMore = false;
      _directResult = null;
      _searchResults = const <VideoSearchResult>[];
      _userResults = const <UserSearchResult>[];
      _errorMessage = message;
    });
  }

  /// 清空输入、候选词、结果和错误说明，让用户开始新的主动搜索。
  void _clearInput() {
    _suggestionDebounce?.cancel();
    _controller.clear();
    setState(() {
      _directResult = null;
      _searchResults = const <VideoSearchResult>[];
      _userResults = const <UserSearchResult>[];
      _suggestions = const <String>[];
      _errorMessage = null;
      _hasSubmitted = false;
      _activeQuery = '';
      _currentPage = 0;
      _totalPages = 0;
    });
  }

  /// 切换视频或用户搜索，并清除上一模式结果，避免两类卡片混在同一列表。
  void _changeSearchMode(Set<_SearchMode> values) {
    if (values.isEmpty || values.first == _searchMode) {
      return;
    }
    setState(() {
      _searchMode = values.first;
      _directResult = null;
      _searchResults = const <VideoSearchResult>[];
      _userResults = const <UserSearchResult>[];
      _suggestions = const <String>[];
      _errorMessage = null;
      _hasSubmitted = false;
      _activeQuery = '';
      _currentPage = 0;
      _totalPages = 0;
    });
  }

  /// 打开用户搜索结果对应的公开主页。
  void _openUserResult(UserSearchResult result) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // 用户主页构建函数先显示搜索资料，再由公开接口补全内容。
        builder: (BuildContext context) => UserProfilePage(
          mid: result.mid,
          initialName: result.name,
          initialAvatarUrl: result.avatarUrl,
          initialSign: result.signature,
          initialOfficialDescription: result.certification,
        ),
      ),
    );
  }

  /// 把查询到的完整视频作为参数打开原生播放器页面。
  void _openVideo(VideoPreview video) {
    Navigator.of(context).pushNamed(AppRoutes.player, arguments: video);
  }

  /// 点击关键词结果后查询完整分P信息，再把可播放视频交给播放器页面。
  Future<void> _openSearchResult(VideoSearchResult result) async {
    if (_openingBvid != null) {
      return;
    }
    setState(() => _openingBvid = result.bvid);
    try {
      final VideoPreview video = await _service.lookupVideo(result.bvid);
      if (!mounted) {
        return;
      }
      setState(() => _openingBvid = null);
      _openVideo(video);
    } on BilibiliLookupException catch (error) {
      _showSearchResultError(error.message);
    } catch (_) {
      _showSearchResultError('无法打开这条搜索结果，请检查网络后重试。');
    }
  }

  /// 保留当前列表并用三秒系统提示展示单条结果的详情查询错误。
  void _showSearchResultError(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _openingBvid = null);
    _showTransientMessage(message);
  }

  /// 显示统一为三秒的临时系统提示。
  void _showTransientMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 为当前已渲染、且服务端未返回分集文字的卡片安排一次详情补查。
  ///
  /// 该函数在绘制完成后才入队，避免为尚未出现的搜索结果消耗网络；同一
  /// BV 号无论成功或失败都只会尝试一次，避免滚动列表重复触发详情请求。
  void _scheduleEpisodeCountFallback(VideoSearchResult result) {
    if (result.episodeCountText.isNotEmpty ||
        _fallbackEpisodeCountTexts.containsKey(result.bvid)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isSearchResultDisplayed(result.bvid)) {
        return;
      }
      if (!_episodeCountLookupAttemptedBvids.add(result.bvid)) {
        return;
      }
      _episodeCountLookupQueue.addLast(result);
      _pumpEpisodeCountLookups();
    });
  }

  /// 判断某个 BV 号是否仍在当前搜索列表中，防止切换关键词后补查旧卡片。
  bool _isSearchResultDisplayed(String bvid) {
    return _searchResults.any(
      (VideoSearchResult result) => result.bvid == bvid,
    );
  }

  /// 在最多两个并发请求的限制内，依次启动已渲染卡片的分集详情补查。
  void _pumpEpisodeCountLookups() {
    while (_activeEpisodeCountLookups < _maxEpisodeCountLookupConcurrency &&
        _episodeCountLookupQueue.isNotEmpty) {
      final VideoSearchResult result = _episodeCountLookupQueue.removeFirst();
      if (!_isSearchResultDisplayed(result.bvid)) {
        continue;
      }
      _activeEpisodeCountLookups += 1;
      unawaited(_resolveEpisodeCountFallback(result));
    }
  }

  /// 查询视频详情并仅在分P数大于一时写入“共 N P”的补充角标。
  ///
  /// 请求失败会被静默保留在“已尝试”集合中：卡片仍能点击播放，且不会因
  /// 每次滚动重新发起同一条失败请求。
  Future<void> _resolveEpisodeCountFallback(VideoSearchResult result) async {
    try {
      final VideoPreview video = await _service.lookupVideo(result.bvid);
      final int partCount = video.parts.length;
      if (mounted && partCount > 1 && _isSearchResultDisplayed(result.bvid)) {
        setState(() {
          _fallbackEpisodeCountTexts[result.bvid] = '共 $partCount P';
        });
      }
    } catch (_) {
      // 分集补查失败不影响现有结果的展示或点击播放。
    } finally {
      _activeEpisodeCountLookups -= 1;
      if (mounted) {
        _pumpEpisodeCountLookups();
      }
    }
  }

  /// 返回服务端原始分集文字；仅在它缺失时使用详情补查得到的文字。
  String _episodeCountTextFor(VideoSearchResult result) {
    return result.episodeCountText.isNotEmpty
        ? result.episodeCountText
        : (_fallbackEpisodeCountTexts[result.bvid] ?? '');
  }

  /// 切换排序方式并立即重新请求第一页结果。
  void _changeSearchOrder(VideoSearchOrder order) {
    if (_filter.order == order) {
      return;
    }
    setState(() => _filter = _filter.copyWith(order: order));
    if (_controller.text.trim().isNotEmpty) {
      unawaited(_submitSearch());
    }
  }

  /// 切换用户排序方式，并在输入非空时立即重新请求第一页。
  void _changeUserSearchOrder(UserSearchOrder order) {
    if (_userFilter.order == order) {
      return;
    }
    setState(() => _userFilter = _userFilter.copyWith(order: order));
    if (_controller.text.trim().isNotEmpty) {
      unawaited(_submitSearch());
    }
  }

  /// 打开用户类型筛选面板，支持全部、UP 主、普通用户和认证用户。
  Future<void> _openUserFilterSheet() async {
    final UserSearchType? selectedType =
        await showModalBottomSheet<UserSearchType>(
          context: context,
          showDragHandle: true,
          builder: (BuildContext context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('用户分类', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: UserSearchType.values
                        .map((UserSearchType type) {
                          return ChoiceChip(
                            label: Text(_userTypeLabel(type)),
                            selected: type == _userFilter.type,
                            // 用户分类标签函数把选择返回搜索页面，网络请求由外层统一发起。
                            onSelected: (_) => Navigator.of(context).pop(type),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
          ),
        );
    if (!mounted || selectedType == null || selectedType == _userFilter.type) {
      return;
    }
    setState(() => _userFilter = _userFilter.copyWith(type: selectedType));
    if (_controller.text.trim().isNotEmpty) {
      unawaited(_submitSearch());
    }
  }

  /// 返回用户排序在搜索栏中显示的短标签。
  String _userOrderLabel(UserSearchOrder order) {
    return switch (order) {
      UserSearchOrder.defaultOrder => '默认排序',
      UserSearchOrder.fansDescending => '粉丝多',
      UserSearchOrder.fansAscending => '粉丝少',
      UserSearchOrder.levelDescending => '等级高',
      UserSearchOrder.levelAscending => '等级低',
    };
  }

  /// 返回用户分类在筛选面板中显示的中文名称。
  String _userTypeLabel(UserSearchType type) {
    return switch (type) {
      UserSearchType.all => '全部用户',
      UserSearchType.uploader => 'UP 主',
      UserSearchType.normal => '普通用户',
      UserSearchType.certified => '认证用户',
    };
  }

  /// 打开参考图样式的筛选面板，并在用户确认后重新搜索。
  Future<void> _openFilterSheet() async {
    VideoSearchFilter editingFilter = _filter;
    final VideoSearchFilter?
    selectedFilter = await showModalBottomSheet<VideoSearchFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) {
        return StatefulBuilder(
          // 筛选面板构建函数只修改临时条件，点击应用后才请求网络。
          builder: (BuildContext context, StateSetter setModalState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  20 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('筛选', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 20),
                    _buildFilterSection<VideoPublishedRange>(
                      title: '发布日期',
                      values: VideoPublishedRange.values,
                      selectedValue: editingFilter.publishedRange,
                      labelBuilder: _publishedRangeLabel,
                      onSelected: (VideoPublishedRange value) {
                        setModalState(() {
                          editingFilter = editingFilter.copyWith(
                            publishedRange: value,
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 20),
                    _buildFilterSection<VideoDurationRange>(
                      title: '内容时长',
                      values: VideoDurationRange.values,
                      selectedValue: editingFilter.durationRange,
                      labelBuilder: _durationRangeLabel,
                      onSelected: (VideoDurationRange value) {
                        setModalState(() {
                          editingFilter = editingFilter.copyWith(
                            durationRange: value,
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '内容分区',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: _categories
                          .map((_SearchCategory category) {
                            return ChoiceChip(
                              label: Text(category.label),
                              selected: editingFilter.categoryId == category.id,
                              // 分区选择函数更新筛选面板中的临时内容分区。
                              onSelected: (_) {
                                setModalState(() {
                                  editingFilter = editingFilter.copyWith(
                                    categoryId: category.id,
                                    categoryLabel: category.label,
                                    clearCategory: category.id == null,
                                  );
                                });
                              },
                            );
                          })
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            // 筛选重置函数恢复默认条件但仍等待用户确认。
                            onPressed: () {
                              setModalState(() {
                                editingFilter = VideoSearchFilter(
                                  order: editingFilter.order,
                                );
                              });
                            },
                            child: const Text('重置'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            // 筛选应用函数把临时条件返回搜索页面。
                            onPressed: () =>
                                Navigator.of(context).pop(editingFilter),
                            child: const Text('应用筛选'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted || selectedFilter == null) {
      return;
    }
    setState(() => _filter = selectedFilter);
    if (_controller.text.trim().isNotEmpty) {
      unawaited(_submitSearch());
    }
  }

  /// 创建筛选面板中一组带标题的单选标签。
  Widget _buildFilterSection<T>({
    required String title,
    required List<T> values,
    required T selectedValue,
    required String Function(T value) labelBuilder,
    required ValueChanged<T> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: values
              .map((T value) {
                return ChoiceChip(
                  label: Text(labelBuilder(value)),
                  selected: value == selectedValue,
                  // 筛选标签函数把选中的枚举值交给调用方更新临时条件。
                  onSelected: (_) => onSelected(value),
                );
              })
              .toList(growable: false),
        ),
      ],
    );
  }

  /// 返回排序枚举在搜索栏中显示的简短中文名称。
  String _orderLabel(VideoSearchOrder order) {
    switch (order) {
      case VideoSearchOrder.relevance:
        return '默认排序';
      case VideoSearchOrder.mostPlayed:
        return '播放多';
      case VideoSearchOrder.newest:
        return '新发布';
      case VideoSearchOrder.mostDanmaku:
        return '弹幕多';
      case VideoSearchOrder.mostFavorited:
        return '收藏多';
    }
  }

  /// 返回发布日期范围在筛选面板中显示的中文名称。
  String _publishedRangeLabel(VideoPublishedRange range) {
    switch (range) {
      case VideoPublishedRange.any:
        return '全部日期';
      case VideoPublishedRange.lastDay:
        return '最近一天';
      case VideoPublishedRange.lastWeek:
        return '最近一周';
      case VideoPublishedRange.lastHalfYear:
        return '最近半年';
    }
  }

  /// 返回视频时长范围在筛选面板中显示的中文名称。
  String _durationRangeLabel(VideoDurationRange range) {
    switch (range) {
      case VideoDurationRange.any:
        return '全部时长';
      case VideoDurationRange.underTenMinutes:
        return '0-10分钟';
      case VideoDurationRange.tenToThirtyMinutes:
        return '10-30分钟';
      case VideoDurationRange.thirtyToSixtyMinutes:
        return '30-60分钟';
      case VideoDurationRange.overSixtyMinutes:
        return '60分钟+';
    }
  }

  /// 返回当前启用的日期、时长和分区筛选数量，供筛选按钮显示徽标。
  int _activeFilterCount() {
    int count = 0;
    if (_filter.publishedRange != VideoPublishedRange.any) {
      count += 1;
    }
    if (_filter.durationRange != VideoDurationRange.any) {
      count += 1;
    }
    if (_filter.categoryId != null) {
      count += 1;
    }
    return count;
  }

  /// 把时长转换成封面角标使用的“分:秒”或“时:分:秒”。
  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      final int hours = duration.inHours;
      final int minutes = duration.inMinutes.remainder(60);
      final int seconds = duration.inSeconds.remainder(60);
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 把发布日期转换为“年-月-日 时:分”格式。
  String _formatPublishedAt(DateTime? dateTime) {
    if (dateTime == null) {
      return '发布日期未知';
    }
    return '${dateTime.year.toString().padLeft(4, '0')}-'
        '${dateTime.month.toString().padLeft(2, '0')}-'
        '${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}';
  }

  /// 将播放和弹幕数量转换为万、亿单位的紧凑文字。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  /// 创建搜索输入、候选词、筛选栏、记录和结果区域。
  @override
  Widget build(BuildContext context) {
    final bool keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('搜索')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _controller,
              focusNode: _searchFocusNode,
              autofocus: false,
              textInputAction: TextInputAction.search,
              // 输入变化函数延迟请求候选词。
              onChanged: _handleSearchInputChanged,
              // 键盘确认函数复用标准搜索流程。
              onSubmitted: (_) => _submitSearch(),
              decoration: InputDecoration(
                hintText: _searchMode == _SearchMode.videos
                    ? '搜索关键词、BV 号或 B 站视频链接'
                    : '搜索用户名',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  // 输入清空函数同时移除旧候选词和搜索结果。
                  onPressed: _clearInput,
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '清空',
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_SearchMode>(
                key: const Key('search-mode-selector'),
                segments: const <ButtonSegment<_SearchMode>>[
                  ButtonSegment<_SearchMode>(
                    value: _SearchMode.videos,
                    icon: Icon(Icons.ondemand_video_outlined),
                    label: Text('视频'),
                  ),
                  ButtonSegment<_SearchMode>(
                    value: _SearchMode.users,
                    icon: Icon(Icons.person_search_outlined),
                    label: Text('用户'),
                  ),
                ],
                selected: <_SearchMode>{_searchMode},
                // 搜索模式函数在视频和用户结果之间切换。
                onSelectionChanged: _changeSearchMode,
              ),
            ),
            if (!keyboardVisible) ...<Widget>[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  // 搜索按钮函数请求 BV 详情或关键词第一页结果。
                  onPressed: _loading ? null : _submitSearch,
                  child: Text(_loading ? '正在搜索…' : '搜索'),
                ),
              ),
              const SizedBox(height: 6),
              _buildSortAndFilterBar(),
            ],
            _buildSearchHistory(),
            Expanded(child: _buildResultOverlay()),
          ],
        ),
      ),
    );
  }

  /// 将候选词覆盖在结果列表顶部，避免候选区域预留空白或挤走搜索结果。
  Widget _buildResultOverlay() {
    return Stack(
      key: const Key('search-result-overlay'),
      fit: StackFit.expand,
      children: <Widget>[
        _buildResultArea(),
        if (_searchFocusNode.hasFocus && _suggestions.isNotEmpty)
          Positioned(top: 0, left: 0, right: 0, child: _buildSuggestions()),
      ],
    );
  }

  /// 创建输入框下方的候选词列表，失去焦点时自动隐藏。
  Widget _buildSuggestions() {
    if (!_searchFocusNode.hasFocus || _suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Card(
        margin: const EdgeInsets.only(top: 6),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _suggestions.length,
          itemBuilder: (BuildContext context, int index) {
            final String suggestion = _suggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.search_rounded, size: 20),
              title: Text(suggestion),
              // 候选词点击函数立即执行所选关键词搜索。
              onTap: () => _selectSuggestedQuery(suggestion),
            );
          },
        ),
      ),
    );
  }

  /// 创建可横向滚动的排序标签和带已启用数量的筛选按钮。
  Widget _buildSortAndFilterBar() {
    if (_searchMode == _SearchMode.users) {
      return _buildUserSortAndFilterBar();
    }
    final int filterCount = _activeFilterCount();
    return SizedBox(
      height: 46,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: VideoSearchOrder.values.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 6),
              itemBuilder: (BuildContext context, int index) {
                final VideoSearchOrder order = VideoSearchOrder.values[index];
                return ChoiceChip(
                  label: Text(_orderLabel(order)),
                  selected: _filter.order == order,
                  // 排序标签函数立即用新顺序重新搜索第一页。
                  onSelected: (_) => _changeSearchOrder(order),
                );
              },
            ),
          ),
          const VerticalDivider(indent: 8, endIndent: 8),
          Badge(
            isLabelVisible: filterCount > 0,
            label: Text(filterCount.toString()),
            child: IconButton(
              // 筛选按钮函数打开日期、时长和内容分区面板。
              onPressed: _openFilterSheet,
              icon: const Icon(Icons.filter_list_rounded),
              tooltip: '筛选',
            ),
          ),
        ],
      ),
    );
  }

  /// 创建用户搜索的粉丝数、等级排序标签和用户类型筛选按钮。
  Widget _buildUserSortAndFilterBar() {
    return SizedBox(
      height: 46,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: UserSearchOrder.values.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 6),
              itemBuilder: (BuildContext context, int index) {
                final UserSearchOrder order = UserSearchOrder.values[index];
                return ChoiceChip(
                  label: Text(_userOrderLabel(order)),
                  selected: _userFilter.order == order,
                  // 用户排序标签函数按所选粉丝数或等级顺序重新搜索。
                  onSelected: (_) => _changeUserSearchOrder(order),
                );
              },
            ),
          ),
          const VerticalDivider(indent: 8, endIndent: 8),
          Badge(
            isLabelVisible: _userFilter.type != UserSearchType.all,
            child: IconButton(
              // 用户筛选按钮函数打开账号分类选择面板。
              onPressed: _openUserFilterSheet,
              icon: const Icon(Icons.filter_list_rounded),
              tooltip: '用户分类',
            ),
          ),
        ],
      ),
    );
  }

  /// 创建横向搜索记录栏，并提供重新搜索与清空全部记录入口。
  Widget _buildSearchHistory() {
    if (_searchHistory.isEmpty || _hasSubmitted || _searchFocusNode.hasFocus) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('搜索记录', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                // 清空记录按钮函数删除设备中的全部搜索记录。
                onPressed: _clearSearchHistory,
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: '清空搜索记录',
              ),
            ],
          ),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _searchHistory.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int index) {
                final String value = _searchHistory[index];
                return ActionChip(
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(value, overflow: TextOverflow.ellipsis),
                  ),
                  // 历史记录按钮函数把内容放回输入框并重新搜索。
                  onPressed: () => _selectSuggestedQuery(value),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 根据当前状态构建加载、错误、空状态、BV 直达或分页关键词结果。
  Widget _buildResultArea() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return _SearchMessage(
        icon: Icons.error_outline_rounded,
        text: _errorMessage!,
      );
    }
    final VideoPreview? directResult = _directResult;
    if (directResult != null) {
      return ListView(
        controller: _resultScrollController,
        children: <Widget>[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: const CircleAvatar(
                child: Icon(Icons.play_arrow_rounded),
              ),
              title: Text(directResult.title),
              subtitle: Text('UP主：${directResult.ownerName}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              // BV 直达结果点击函数直接打开完整视频。
              onTap: () => _openVideo(directResult),
            ),
          ),
        ],
      );
    }
    if (_userResults.isNotEmpty) {
      return ListView.separated(
        controller: _resultScrollController,
        itemCount: _userResults.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 6),
        itemBuilder: (BuildContext context, int index) {
          if (index == _userResults.length) {
            return _buildLoadMoreFooter();
          }
          return _buildUserResultCard(_userResults[index]);
        },
      );
    }
    if (_searchResults.isNotEmpty) {
      return ListView.separated(
        controller: _resultScrollController,
        itemCount: _searchResults.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 6),
        itemBuilder: (BuildContext context, int index) {
          if (index == _searchResults.length) {
            return _buildLoadMoreFooter();
          }
          return _buildSearchResultCard(_searchResults[index]);
        },
      );
    }
    if (_hasSubmitted) {
      return _SearchMessage(
        icon: Icons.search_off_rounded,
        text: _searchMode == _SearchMode.videos
            ? '没有找到相关公开视频，可以调整筛选或更换关键词。'
            : '没有找到相关用户，可以调整分类或更换用户名。',
      );
    }
    return const _SearchEmptyState();
  }

  /// 创建用户头像、等级、粉丝数、投稿数、认证和签名组成的搜索卡片。
  Widget _buildUserResultCard(UserSearchResult result) {
    return Card(
      key: ValueKey<String>('user-search-${result.mid}'),
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: CircleAvatar(
          radius: 28,
          backgroundImage: result.avatarUrl.isEmpty
              ? null
              : CachedNetworkImageProvider(
                  result.avatarUrl,
                  headers: const <String, String>{
                    'Referer': 'https://www.bilibili.com/',
                  },
                ),
          child: result.avatarUrl.isEmpty
              ? const Icon(Icons.person_rounded)
              : null,
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                result.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  'LV${result.level}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
            if (result.isCertified) ...<Widget>[
              const SizedBox(width: 5),
              Icon(
                Icons.verified_rounded,
                size: 17,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 3),
            Text(
              '粉丝 ${_formatCount(result.followerCount)}  ·  视频 ${result.videoCount}',
            ),
            if (result.isCertified)
              Text(
                result.certification,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              )
            else if (result.signature.isNotEmpty)
              Text(
                result.signature,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        // 用户卡片点击函数打开对应 MID 的公开主页。
        onTap: () => _openUserResult(result),
      ),
    );
  }

  /// 创建包含缓存缩略图、角标、发布日期、UP、播放和弹幕数的结果卡片。
  Widget _buildSearchResultCard(VideoSearchResult result) {
    final bool opening = _openingBvid == result.bvid;
    final String episodeCountText = _episodeCountTextFor(result);
    _scheduleEpisodeCountFallback(result);
    return Card(
      key: ValueKey<String>('search-${result.bvid}'),
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        // 搜索结果点击函数先补全 cid 与分P，再进入播放器。
        onTap: opening ? null : () => _openSearchResult(result),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildSearchThumbnail(result, episodeCountText: episodeCountText),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 92,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        _formatPublishedAt(result.publishedAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        result.ownerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.play_circle_outline_rounded,
                            size: 16,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(result.playCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 12),
                          const Icon(Icons.subtitles_outlined, size: 16),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(result.danmakuCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const Spacer(),
                          if (opening)
                            const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建缓存封面，并叠加时长和服务端或详情补查得到的分集角标。
  Widget _buildSearchThumbnail(
    VideoSearchResult result, {
    required String episodeCountText,
  }) {
    return SizedBox(
      width: 146,
      height: 92,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (result.thumbnailUrl.isEmpty)
              _buildThumbnailPlaceholder(context, '')
            else
              CachedNetworkImage(
                imageUrl: result.thumbnailUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 320,
                maxWidthDiskCache: 640,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: _buildThumbnailPlaceholder,
                errorWidget: _buildThumbnailError,
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: _buildThumbnailBadge(_formatDuration(result.duration)),
            ),
            if (episodeCountText.isNotEmpty)
              Positioned(
                left: 5,
                top: 5,
                child: _buildThumbnailBadge(episodeCountText),
              ),
          ],
        ),
      ),
    );
  }

  /// 创建封面加载过程中的低流量本地占位底图。
  Widget _buildThumbnailPlaceholder(BuildContext context, String url) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.image_outlined, color: Colors.black38),
      ),
    );
  }

  /// 创建封面加载失败时使用的本地播放图标。
  Widget _buildThumbnailError(BuildContext context, String url, Object error) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.play_arrow_rounded)),
    );
  }

  /// 创建封面上的半透明时长或分集文字角标。
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

  /// 创建分页列表底部的加载状态或“已经到底”说明。
  Widget _buildLoadMoreFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_currentPage > 0 && _currentPage >= _totalPages) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: Center(child: Text('已经到底了')),
      );
    }
    return const SizedBox(height: 24);
  }
}

/// 显示搜索失败或无结果的居中状态信息。
class _SearchMessage extends StatelessWidget {
  /// 创建带图标和说明文字的搜索状态。
  const _SearchMessage({required this.icon, required this.text});

  final IconData icon;
  final String text;

  /// 创建居中的图标和说明文字。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 64),
                    const SizedBox(height: 16),
                    Text(text, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 搜索前的空状态，说明候选词、筛选和 BV 直达都由用户主动触发。
class _SearchEmptyState extends StatelessWidget {
  /// 创建没有结果时的专注搜索说明。
  const _SearchEmptyState();

  /// 创建居中的输入格式说明，不展示任何推荐视频。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.manage_search_rounded, size: 72),
                    SizedBox(height: 16),
                    Text('搜索你真正想看的内容'),
                    SizedBox(height: 6),
                    Text('支持关键词候选、筛选、分页和 BV 直达'),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
