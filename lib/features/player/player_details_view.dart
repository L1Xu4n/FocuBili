part of 'player_page.dart';

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

  /// 创建只读互动统计项，不伪装未实现的点赞、投币或收藏写操作。
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
        Text(
          _activeVideo.title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
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
            _buildReadOnlyStat(
              Icons.thumb_up_alt_outlined,
              '点赞',
              stats.likeCount,
            ),
            _buildReadOnlyStat(Icons.paid_outlined, '投币', stats.coinCount),
            _buildReadOnlyStat(
              Icons.star_border_rounded,
              '收藏',
              stats.favoriteCount,
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
            Text.rich(
              TextSpan(style: style, children: _buildDescriptionSpans(style)),
              key: const Key('video-description'),
              maxLines: _descriptionExpanded ? null : 3,
              overflow: _descriptionExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
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
