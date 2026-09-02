part of 'player_page.dart';

/// 保存收藏夹多选面板的最终勾选结果，以及用户是否希望继续创建新目录。
class _FavoriteFolderSelection {
  /// 创建一份不会再被弹窗内部修改的收藏夹选择结果。
  _FavoriteFolderSelection({
    required Set<int> selectedMediaIds,
    this.createNewFolder = false,
  }) : selectedMediaIds = Set<int>.unmodifiable(selectedMediaIds);

  final Set<int> selectedMediaIds;
  final bool createNewFolder;
}

/// 组合播放器的详情、合集预览、UP 主资料和播放反馈视图。
extension _PlayerDetailsView on _PlayerPageState {
  /// 将公开统计格式化为紧凑的万或亿单位。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.clamp(0, 1 << 31).toString();
  }

  /// 将发布日期格式化为年月日和小时分钟；接口没有日期时返回“日期未知”。
  String _formatPublishedAt(DateTime? value) {
    if (value == null) {
      return '日期未知';
    }
    final String month = value.month.toString().padLeft(2, '0');
    final String day = value.day.toString().padLeft(2, '0');
    final String hour = value.hour.toString().padLeft(2, '0');
    final String minute = value.minute.toString().padLeft(2, '0');
    return '${value.year}-$month-$day $hour:$minute';
  }

  /// 把当前 BV 号复制到系统剪贴板，并用轻量提示确认操作成功。
  Future<void> _copyBvid() async {
    await Clipboard.setData(ClipboardData(text: _activeVideo.bvid));
    if (mounted) {
      _showTransientSnackBar('已复制 ${_activeVideo.bvid}');
    }
  }

  /// 创建低流量缓存封面或头像，失败时显示固定占位图标。
  Widget _buildDetailImage(
    String url, {
    required double width,
    required double height,
    required BoxFit fit,
    IconData placeholderIcon = Icons.image_outlined,
  }) {
    if (url.isEmpty) {
      return _buildDetailImagePlaceholder(width, height, placeholderIcon);
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: 480,
      maxWidthDiskCache: 720,
      placeholder: (BuildContext context, String value) =>
          _buildDetailImagePlaceholder(width, height, placeholderIcon),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildDetailImagePlaceholder(width, height, placeholderIcon),
    );
  }

  /// 创建详情远程图片加载中或失败时使用的固定尺寸占位。
  Widget _buildDetailImagePlaceholder(
    double width,
    double height,
    IconData icon,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(icon),
      ),
    );
  }

  /// 读取当前视频的关注、点赞、投币和收藏状态，失败时保留默认未操作状态。
  Future<void> _loadVideoInteractionState() async {
    if (_activeVideo.aid <= 0) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    final Set<int> authorMids = <int>{
      if (_activeVideo.ownerMid > 0) _activeVideo.ownerMid,
      ..._activeVideo.authors
          .map((VideoAuthor author) => author.mid)
          .where((int mid) => mid > 0),
    };
    if (mounted) {
      _updatePlayerState(() => _interactionLoading = true);
    }
    try {
      final BilibiliInteractionState state = await _interactionService
          .loadVideoState(
            bvid: _activeVideo.bvid,
            aid: _activeVideo.aid,
            ownerMid: _activeVideo.ownerMid,
          );
      final Map<int, bool> followingStates = <int, bool>{
        if (_activeVideo.ownerMid > 0) _activeVideo.ownerMid: state.isFollowing,
      };
      await Future.wait(
        authorMids.where((int mid) => mid != _activeVideo.ownerMid).map((
          int mid,
        ) async {
          try {
            followingStates[mid] = await _interactionService.loadFollowingState(
              mid,
            );
          } on Object {
            // 单个合作作者关系读取失败时保留未关注显示，不影响其他作者和视频互动状态。
          }
        }),
      );
      if (mounted && _activeVideo.bvid == bvid) {
        _updatePlayerState(() {
          _interactionState = state;
          _authorFollowingStates
            ..clear()
            ..addAll(followingStates);
        });
      }
    } on Object {
      // 未登录或状态接口暂时不可用时，写操作仍会给出明确提示。
    } finally {
      if (mounted) {
        _updatePlayerState(() => _interactionLoading = false);
      }
    }
  }

  /// 执行指定作者的关注或取消关注，并只更新该作者按钮状态。
  Future<void> _toggleVideoFollow(VideoAuthor author) async {
    if (_interactionAction != null ||
        author.mid <= 0 ||
        _authorFollowActions.contains(author.mid)) {
      return;
    }
    final bool following =
        _authorFollowingStates[author.mid] ??
        (author.mid == _activeVideo.ownerMid && _interactionState.isFollowing);
    _updatePlayerState(() => _authorFollowActions.add(author.mid));
    try {
      await _interactionService.setFollowing(
        mid: author.mid,
        following: !following,
      );
      if (mounted) {
        _updatePlayerState(() {
          _authorFollowingStates[author.mid] = !following;
          if (author.mid == _activeVideo.ownerMid) {
            _interactionState = _interactionState.copyWith(
              isFollowing: !following,
            );
          }
        });
        _showTransientSnackBar(
          following ? '已取消关注 ${author.name}' : '已关注 ${author.name}',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showTransientSnackBar(error.toString());
      }
    } finally {
      if (mounted) {
        _updatePlayerState(() => _authorFollowActions.remove(author.mid));
      }
    }
  }

  /// 执行点赞或取消点赞，并在接口成功后更新按钮状态。
  Future<void> _toggleVideoLike() async {
    if (_interactionAction != null || _activeVideo.aid <= 0) {
      return;
    }
    final bool liked = _interactionState.isLiked;
    _updatePlayerState(() => _interactionAction = 'like');
    try {
      await _interactionService.setLiked(aid: _activeVideo.aid, liked: !liked);
      if (mounted) {
        _updatePlayerState(() {
          _interactionState = _interactionState.copyWith(isLiked: !liked);
          _likeCountDelta += liked ? -1 : 1;
        });
        _showTransientSnackBar(liked ? '已取消点赞' : '已点赞');
      }
    } on Object catch (error) {
      if (mounted) {
        _showTransientSnackBar(error.toString());
      }
    } finally {
      if (mounted) {
        _updatePlayerState(() => _interactionAction = null);
      }
    }
  }

  /// 弹出硬币数量选择面板，并按当前剩余额度隐藏不可用选项。
  Future<int?> _showCoinAmountSheet(int remainingCoins) {
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '选择投币数量',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ListTile(
                key: const Key('coin-option-1'),
                leading: const Icon(Icons.paid_outlined),
                title: const Text('投 1 枚硬币'),
                onTap: () => Navigator.of(sheetContext).pop(1),
              ),
              if (remainingCoins >= 2)
                ListTile(
                  key: const Key('coin-option-2'),
                  leading: const Icon(Icons.paid),
                  title: const Text('投 2 枚硬币'),
                  onTap: () => Navigator.of(sheetContext).pop(2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 让用户选择投一枚或两枚硬币，并在接口成功后更新已投数量和公开计数。
  Future<void> _addVideoCoin() async {
    if (_interactionAction != null || _activeVideo.aid <= 0) {
      return;
    }
    final int remainingCoins = 2 - _interactionState.coinCount;
    if (remainingCoins <= 0) {
      _showTransientSnackBar('这支视频已经投满 2 枚硬币');
      return;
    }
    final int? multiply = await _showCoinAmountSheet(remainingCoins);
    if (!mounted || multiply == null) {
      return;
    }
    _updatePlayerState(() => _interactionAction = 'coin');
    try {
      await _interactionService.addCoin(
        aid: _activeVideo.aid,
        multiply: multiply,
      );
      if (mounted) {
        _updatePlayerState(() {
          _interactionState = _interactionState.copyWith(
            coinCount: (_interactionState.coinCount + multiply).clamp(0, 2),
          );
          _coinCountDelta += multiply;
        });
        _showTransientSnackBar('已投 $multiply 枚硬币');
      }
    } on Object catch (error) {
      if (mounted) {
        _showTransientSnackBar(error.toString());
      }
    } finally {
      if (mounted) {
        _updatePlayerState(() => _interactionAction = null);
      }
    }
  }

  /// 显示可多选的收藏夹列表，并保留当前已经包含视频的预选状态。
  Future<_FavoriteFolderSelection?> _showFavoriteFolderSheet(
    List<BilibiliFavoriteFolder> folders,
  ) {
    final Set<int> selectedMediaIds = folders
        .where((BilibiliFavoriteFolder folder) => folder.containsVideo)
        .map((BilibiliFavoriteFolder folder) => folder.mediaId)
        .toSet();
    return showModalBottomSheet<_FavoriteFolderSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        // 弹窗状态函数只维护本次勾选集合，提交前不修改播放器或服务端状态。
        builder: (BuildContext context, StateSetter setSheetState) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.76,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '选择收藏夹',
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('create-favorite-folder'),
                          onPressed: () => Navigator.of(sheetContext).pop(
                            _FavoriteFolderSelection(
                              selectedMediaIds: selectedMediaIds,
                              createNewFolder: true,
                            ),
                          ),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('新建收藏夹'),
                        ),
                      ],
                    ),
                  ),
                  if (folders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Text('当前还没有收藏夹，可以先创建一个。'),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        itemCount: folders.length,
                        // 收藏夹构建函数切换单个目录的临时勾选状态，不会提前发起网络请求。
                        itemBuilder: (BuildContext context, int index) {
                          final BilibiliFavoriteFolder folder = folders[index];
                          final bool selected = selectedMediaIds.contains(
                            folder.mediaId,
                          );
                          return CheckboxListTile(
                            key: Key('favorite-folder-${folder.mediaId}'),
                            value: selected,
                            controlAffinity: ListTileControlAffinity.trailing,
                            title: Text(folder.title),
                            subtitle: Text('${folder.mediaCount} 个视频'),
                            onChanged: (bool? value) {
                              setSheetState(() {
                                if (value ?? false) {
                                  selectedMediaIds.add(folder.mediaId);
                                } else {
                                  selectedMediaIds.remove(folder.mediaId);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const Key('confirm-favorite-folders'),
                          onPressed: () => Navigator.of(sheetContext).pop(
                            _FavoriteFolderSelection(
                              selectedMediaIds: selectedMediaIds,
                            ),
                          ),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 请求用户输入新收藏夹名称，空名称时禁用创建按钮。
  Future<String?> _showCreateFavoriteFolderDialog() {
    String title = '';
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        // 对话框状态函数只刷新名称校验，不改动播放器页面状态。
        builder: (BuildContext context, StateSetter setDialogState) {
          return AlertDialog(
            title: const Text('创建收藏夹'),
            content: TextField(
              key: const Key('favorite-folder-name'),
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(hintText: '输入收藏夹名称'),
              // 名称变化函数用于即时启用或禁用确认按钮。
              onChanged: (String value) {
                setDialogState(() => title = value.trim());
              },
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: title.isEmpty
                    ? null
                    : () => Navigator.of(dialogContext).pop(title),
                child: const Text('创建'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 打开收藏夹多选面板，一次提交全部新增和移除目录，也允许创建新目录后共同提交。
  Future<void> _toggleVideoFavorite() async {
    if (_interactionAction != null || _activeVideo.aid <= 0) {
      return;
    }
    List<BilibiliFavoriteFolder> folders;
    _updatePlayerState(() => _interactionAction = 'favorite');
    try {
      folders = await _interactionService.loadFavoriteFolders(
        aid: _activeVideo.aid,
      );
    } on Object catch (error) {
      if (mounted) {
        _showTransientSnackBar(error.toString());
      }
      return;
    } finally {
      if (mounted) {
        _updatePlayerState(() => _interactionAction = null);
      }
    }
    if (!mounted) {
      return;
    }
    final _FavoriteFolderSelection? selection = await _showFavoriteFolderSheet(
      folders,
    );
    if (!mounted || selection == null) {
      return;
    }
    final Set<int> initialMediaIds = folders
        .where((BilibiliFavoriteFolder folder) => folder.containsVideo)
        .map((BilibiliFavoriteFolder folder) => folder.mediaId)
        .toSet();
    final Set<int> selectedMediaIds = selection.selectedMediaIds.toSet();
    String? newFolderTitle;
    if (selection.createNewFolder) {
      newFolderTitle = await _showCreateFavoriteFolderDialog();
      if (!mounted || newFolderTitle == null) {
        return;
      }
    }
    _updatePlayerState(() => _interactionAction = 'favorite');
    try {
      if (newFolderTitle != null) {
        final BilibiliFavoriteFolder createdFolder = await _interactionService
            .createFavoriteFolder(title: newFolderTitle);
        selectedMediaIds.add(createdFolder.mediaId);
      }
      final Set<int> additions = selectedMediaIds.difference(initialMediaIds);
      final Set<int> deletions = initialMediaIds.difference(selectedMediaIds);
      await _interactionService.setFavoriteFolders(
        aid: _activeVideo.aid,
        addMediaIds: additions,
        deleteMediaIds: deletions,
      );
      if (mounted) {
        final bool wasFavorited = _interactionState.isFavorited;
        final bool nextFavorited = selectedMediaIds.isNotEmpty;
        _updatePlayerState(() {
          _interactionState = _interactionState.copyWith(
            isFavorited: nextFavorited,
            favoriteMediaId: nextFavorited ? selectedMediaIds.first : null,
            favoriteMediaIds: Set<int>.unmodifiable(selectedMediaIds),
            clearFavoriteMediaId: !nextFavorited,
            clearFavoriteMediaIds: !nextFavorited,
          );
          if (wasFavorited != nextFavorited) {
            _favoriteCountDelta += nextFavorited ? 1 : -1;
          }
        });
        if (additions.isEmpty && deletions.isEmpty) {
          _showTransientSnackBar('收藏夹没有变化');
        } else {
          _showTransientSnackBar(
            '已更新收藏夹：新增 ${additions.length} 个，移除 ${deletions.length} 个',
          );
        }
      }
    } on Object catch (error) {
      if (mounted) {
        _showTransientSnackBar(error.toString());
      }
    } finally {
      if (mounted) {
        _updatePlayerState(() => _interactionAction = null);
      }
    }
  }

  /// 创建可执行互动按钮，忙碌时显示固定尺寸进度指示。
  Widget _buildInteractionStat({
    required Key key,
    required IconData icon,
    required String label,
    required int value,
    required String action,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    final bool busy = _interactionAction == action;
    final bool disabled = _interactionLoading || _interactionAction != null;
    return Expanded(
      child: TextButton(
        key: key,
        onPressed: disabled ? null : onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            busy
                ? const SizedBox.square(
                    dimension: 25,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    icon,
                    size: 25,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
            const SizedBox(height: 4),
            Text(
              value > 0 ? _formatCount(value) : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// 把公开统计和当前页面尚未重新拉取的本地增减量合并，并避免显示负数。
  int _adjustedInteractionCount(int baseValue, int delta) {
    return (baseValue + delta).clamp(0, 1 << 31);
  }

  /// 创建分享等仍为只读统计的展示项，不向用户伪造尚未接入的写操作。
  Widget _buildReadOnlyStat(IconData icon, String label, int value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 25),
          const SizedBox(height: 4),
          Text(
            value > 0 ? _formatCount(value) : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 创建标题、播放统计、简介和 BV 编号信息区，不显示评论或发弹幕入口。
  Widget _buildVideoDescription() {
    final VideoStats stats = _activeVideo.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SelectionArea(
          child: Text(
            _activeVideo.title,
            key: const Key('video-title'),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: <Widget>[
            _DetailMeta(
              icon: Icons.play_circle_outline_rounded,
              text: '${_formatCount(stats.viewCount)}播放',
            ),
            _DetailMeta(
              icon: Icons.subtitles_outlined,
              text: '${_formatCount(stats.danmakuCount)}弹幕',
            ),
            _DetailMeta(
              icon: Icons.calendar_today_outlined,
              text: _formatPublishedAt(_activeVideo.publishedAt),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: '长按复制 BV 号',
          child: InkWell(
            key: const Key('copy-bvid'),
            // BV 文字长按函数只复制 BV 号，旁边显示的 AV 号不会混入剪贴板。
            onLongPress: () => unawaited(_copyBvid()),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _activeVideo.aid > 0
                    ? '${_activeVideo.bvid}  AV${_activeVideo.aid}'
                    : _activeVideo.bvid,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        if (_activeVideo.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _buildExpandableDescription(),
        ],
        if (_activeVideo.tags.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Wrap(
            key: const Key('video-tags'),
            spacing: 8,
            runSpacing: 6,
            children: _activeVideo.tags
                .map(
                  (String tag) => Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(tag),
                  ),
                )
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            _buildInteractionStat(
              key: const Key('video-like-button'),
              icon: _interactionState.isLiked
                  ? Icons.thumb_up_alt
                  : Icons.thumb_up_alt_outlined,
              label: _interactionState.isLiked ? '已点赞' : '点赞',
              value: _adjustedInteractionCount(
                stats.likeCount,
                _likeCountDelta,
              ),
              action: 'like',
              selected: _interactionState.isLiked,
              onPressed: _activeVideo.aid > 0 ? _toggleVideoLike : null,
            ),
            _buildInteractionStat(
              key: const Key('video-coin-button'),
              icon: _interactionState.isCoined
                  ? Icons.paid
                  : Icons.paid_outlined,
              label: _interactionState.isCoined ? '已投币' : '投币',
              value: _adjustedInteractionCount(
                stats.coinCount,
                _coinCountDelta,
              ),
              action: 'coin',
              selected: _interactionState.isCoined,
              onPressed: _activeVideo.aid > 0 && _interactionState.coinCount < 2
                  ? _addVideoCoin
                  : null,
            ),
            _buildInteractionStat(
              key: const Key('video-favorite-button'),
              icon: _interactionState.isFavorited
                  ? Icons.star
                  : Icons.star_border_rounded,
              label: _interactionState.isFavorited ? '已收藏' : '收藏',
              value: _adjustedInteractionCount(
                stats.favoriteCount,
                _favoriteCountDelta,
              ),
              action: 'favorite',
              selected: _interactionState.isFavorited,
              onPressed: _activeVideo.aid > 0 ? _toggleVideoFavorite : null,
            ),
            _buildReadOnlyStat(Icons.share_outlined, '分享', stats.shareCount),
          ],
        ),
      ],
    );
  }

  /// 创建放在“记笔记”左侧的学习清单按钮，并根据加入状态切换文字和图标。
  Widget _buildCurrentVideoLearningListButton() {
    final LearningListEntry? currentEntry = _currentLearningListEntry;
    final bool busy =
        _learningListLoading || _addingLearningBvid == _activeVideo.bvid;
    return Tooltip(
      message: currentEntry == null ? '加入学习清单' : '取消加入学习清单',
      child: TextButton.icon(
        key: const Key('current-video-learning-list-button'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        // 顶部学习清单按钮函数会在加入与取消加入之间切换，并在取消前要求确认。
        onPressed: busy
            ? null
            : () => unawaited(_handleCurrentVideoLearningListTap()),
        icon: busy
            ? const SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                currentEntry == null
                    ? Icons.playlist_add_rounded
                    : Icons.playlist_add_check_rounded,
                size: 20,
              ),
        label: Text(
          _learningListLoading
              ? '读取中…'
              : currentEntry == null
              ? '加入 P${_currentPart.pageNumber}'
              : currentEntry.status == LearningListStatus.completed
              ? 'P${_currentPart.pageNumber} 已完成'
              : 'P${_currentPart.pageNumber} 已加入',
        ),
      ),
    );
  }

  /// 创建最多三行的简介；确实溢出时才显示蓝色展开文字，并保留 @UP 点击能力。
  Widget _buildExpandableDescription() {
    final TextStyle style =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: _activeVideo.description, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 3,
        )..layout(maxWidth: constraints.maxWidth);
        final bool exceedsThreeLines = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectionArea(
              child: Text.rich(
                TextSpan(style: style, children: _buildDescriptionSpans(style)),
                key: const Key('video-description'),
                maxLines: _descriptionExpanded ? null : 3,
                overflow: _descriptionExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
              ),
            ),
            if (exceedsThreeLines || _descriptionExpanded)
              TextButton(
                key: const Key('toggle-video-description'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                // 展开按钮只改变简介行数，不影响播放器或页面滚动位置。
                onPressed: _toggleDescriptionExpanded,
                child: Text(_descriptionExpanded ? '收起' : '展开'),
              ),
          ],
        );
      },
    );
  }

  /// 把普通简介、结构化 @UP 和 HTTP(S) 地址转换为富文本及可点击入口。
  List<InlineSpan> _buildDescriptionSpans(TextStyle baseStyle) {
    final List<VideoDescriptionSegment> segments =
        _activeVideo.descriptionSegments.isEmpty
        ? <VideoDescriptionSegment>[
            VideoDescriptionSegment(text: _activeVideo.description),
          ]
        : _activeVideo.descriptionSegments;
    return segments
        .map((VideoDescriptionSegment segment) {
          if (segment.isLink) {
            return TextSpan(
              text: segment.text,
              // 外链点击识别器先展示风险确认，不会直接把用户带离应用。
              recognizer: _descriptionLinkRecognizer(segment),
              style: baseStyle.copyWith(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: Theme.of(context).colorScheme.primary,
              ),
            );
          }
          if (!segment.isMention) {
            return TextSpan(text: segment.text);
          }
          return TextSpan(
            text: segment.text,
            // UP 提及点击识别器让 @ 文本像普通文字一样参与换行，并保持可点击。
            recognizer: _descriptionMentionRecognizer(segment),
            style: baseStyle.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        })
        .toList(growable: false);
  }

  /// 为一个 @UP 片段复用稳定的点击识别器，避免每次重建富文本都泄漏手势对象。
  TapGestureRecognizer _descriptionMentionRecognizer(
    VideoDescriptionSegment segment,
  ) {
    final String key = '${segment.mentionedMid}:${segment.text}';
    final TapGestureRecognizer recognizer = _descriptionMentionRecognizers
        .putIfAbsent(key, TapGestureRecognizer.new);
    recognizer.onTap = () => unawaited(_openDescriptionMention(segment));
    return recognizer;
  }

  /// 为一个外链片段复用稳定的点击识别器，保留原有的安全确认流程。
  TapGestureRecognizer _descriptionLinkRecognizer(
    VideoDescriptionSegment segment,
  ) {
    final String key = '${segment.linkUri}:${segment.text}';
    final TapGestureRecognizer recognizer = _descriptionLinkRecognizers
        .putIfAbsent(key, TapGestureRecognizer.new);
    recognizer.onTap = () => unawaited(_confirmAndOpenDescriptionLink(segment));
    return recognizer;
  }

  /// 释放简介富文本持有的手势识别器，避免播放器退出后仍保留点击回调。
  void _disposeDescriptionRecognizers() {
    for (final TapGestureRecognizer recognizer
        in _descriptionMentionRecognizers.values) {
      recognizer.dispose();
    }
    for (final TapGestureRecognizer recognizer
        in _descriptionLinkRecognizers.values) {
      recognizer.dispose();
    }
    _descriptionMentionRecognizers.clear();
    _descriptionLinkRecognizers.clear();
  }

  /// 打开简介中被提及 UP 主的公开主页，昵称只作为加载前的占位标题。
  Future<void> _openDescriptionMention(VideoDescriptionSegment segment) async {
    final int? mid = segment.mentionedMid;
    if (mid == null || mid <= 0) {
      return;
    }
    final bool shouldResume = _playing;
    if (shouldResume) {
      await _playbackService.pause();
    }
    if (!mounted) {
      return;
    }
    await _showStandardSystemUiForNestedRoute();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 用户主页构建函数把 @ 文本去掉后作为初始昵称，随后由公开接口校正。
        builder: (BuildContext context) => UserProfilePage(
          mid: mid,
          initialName: segment.text.replaceFirst('@', '').trim(),
          publicContentService: _publicContentService,
          videoService: _bilibiliService,
          learningListService: _learningListService,
          watchHistoryService: _watchHistoryService,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _resumePlayerSystemUiAfterNestedRoute();
    await _restorePlaybackAfterNestedPlayer(shouldResume: shouldResume);
    if (mounted && shouldResume && !_playing) {
      await _playbackService.play();
    }
  }

  /// 展示明确的离开应用风险说明，用户确认后才调用可注入的系统浏览器启动器。
  Future<void> _confirmAndOpenDescriptionLink(
    VideoDescriptionSegment segment,
  ) async {
    final Uri? uri = segment.linkUri;
    if (uri == null || !segment.isLink) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('即将打开外部链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('外部网站的内容和安全性不由焦点哔哩控制，请确认链接可信后再继续。'),
            const SizedBox(height: 12),
            SelectableText(
              uri.toString(),
              key: const Key('external-link-risk-uri'),
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.primary,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('cancel-external-link'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-external-link'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续访问'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    bool opened = false;
    try {
      opened = await (widget.externalLinkLauncher ?? launchExternalLink)(uri);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开默认浏览器，请稍后重试。')));
    }
  }
}
