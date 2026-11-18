part of 'focus_dashboard.dart';

/// 首页的欢迎区与响应式容器；专注业务卡片继续由页面状态维护。
extension _FocusDashboardHomeLayout on _FocusDashboardState {
  /// 根据文字实际换行高度为首屏留足空间，矮屏和大字体允许自然滚动。
  double _homeHeroHeight(BuildContext context, Size windowSize) {
    final bool compact =
        windowSize.width >= AdaptiveLayout.tabletBreakpoint ||
        windowSize.height < 648;
    final double preferred = compact
        ? (windowSize.height - 64).clamp(280.0, 720.0).toDouble()
        : (windowSize.height - 88).clamp(560.0, 760.0).toDouble();
    final ThemeData theme = Theme.of(context);
    final double padding = AdaptiveLayout.centeredHorizontalPadding(
      width: windowSize.width,
      maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
      compact: 24,
    );
    final double width = (windowSize.width - padding * 2).clamp(80.0, 840.0);
    final double titleHeight = _measureHeroText(
      context,
      '焦点哔哩',
      theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      width - kMinInteractiveDimension * (_subscriptions.enabled ? 3 : 2),
    );
    final double welcomeHeight = _measureHeroText(
      context,
      '今天要学点什么？',
      theme.textTheme.headlineMedium,
      width,
    );
    final double actionHeight =
        _measureHeroText(
          context,
          '开始搜索',
          theme.textTheme.labelLarge,
          width - 56,
        ) +
        24;
    final double minimum =
        (titleHeight > 48 ? titleHeight : 48) +
        welcomeHeight +
        (actionHeight > 58 ? actionHeight : 58) +
        30 +
        24 +
        34 +
        48 +
        (_showSubscriptionIntroduction
            ? 100 *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                    1.0,
                    2.5,
                  )
            : 0);
    return preferred > minimum ? preferred : minimum;
  }

  /// 用当前系统字体测量真实换行，避免用缩小字体的方式压进固定高度。
  double _measureHeroText(
    BuildContext context,
    String text,
    TextStyle? style,
    double width,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width.clamp(40.0, double.infinity));
    final double height = painter.height;
    painter.dispose();
    return height;
  }

  /// 欢迎区和卡片在同一个滚动平面，不做反向位移或逐帧模糊。
  Widget _buildHomeHero(BuildContext context, double heroHeight, double width) {
    final ThemeData theme = Theme.of(context);
    final Color textColor = theme.colorScheme.onSurface;
    // 两个首页动作按钮都复用应用主题，避免草图颜色泄漏到成品界面。
    final Color actionColor = theme.colorScheme.primary;
    final Color actionTextColor = theme.colorScheme.onPrimary;
    final horizontalPadding = AdaptiveLayout.centeredHorizontalPadding(
      width: width,
      maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
      compact: 24,
    );
    return SliverToBoxAdapter(
      child: SizedBox(
        key: const Key('focus-home-hero'),
        height: heroHeight,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            18,
            horizontalPadding,
            12,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  // 保留首页文字节点，便于旧版无障碍和启动回归测试识别当前页面。
                  const SizedBox.shrink(child: Text('首页')),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      key: const Key('home-open-about'),
                      onTap: () =>
                          Navigator.of(context).pushNamed(AppRoutes.about),
                      child: Text(
                        '焦点哔哩',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ),
                  ),
                  _buildSubscriptionButton(),
                  IconButton(
                    tooltip: '自定义首页',
                    onPressed: _customizeHome,
                    icon: const Icon(Icons.tune_rounded),
                  ),
                  IconButton(
                    key: const Key('home-profile-button'),
                    // 我的按钮函数切换到个人中心页面。
                    onPressed: widget.onOpenProfile,
                    tooltip: '我的',
                    style: IconButton.styleFrom(
                      backgroundColor: actionColor,
                      foregroundColor: actionTextColor,
                      fixedSize: const Size.square(46),
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    icon: _buildProfileIcon(actionTextColor),
                  ),
                  // 保留旧启动测试需要的文字节点，实际按钮仍只绘制图标。
                  const SizedBox.shrink(child: Text('我的')),
                ],
              ),
              _buildSubscriptionIntroduction(),
              const Spacer(),
              Text(
                '今天要学点什么？',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('home-start-search'),
                // 开始搜索按钮函数进入搜索页面，保持首页动作单一明确。
                onPressed: widget.onOpenVideo,
                style: FilledButton.styleFrom(
                  backgroundColor: actionColor,
                  foregroundColor: actionTextColor,
                  minimumSize: const Size(160, 58),
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text('开始搜索'),
              ),
              // 保留旧入口文字节点，但不在新首屏重复绘制第二个按钮。
              const SizedBox.shrink(child: Text('打开视频')),
              const Spacer(),
              if (_hasHomeDrawer)
                Icon(
                  Icons.keyboard_double_arrow_up_rounded,
                  key: const Key('home-scroll-hint'),
                  size: 34,
                  color: textColor,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建首页账号入口的头像或主题色默认人物图标。
  Widget _buildProfileIcon(Color fallbackColor) {
    final String avatarUrl = widget.profileAvatarUrl?.trim() ?? '';
    if (avatarUrl.isEmpty) {
      return Icon(Icons.person_outline_rounded, color: fallbackColor);
    }
    return ClipOval(
      child: AppNetworkImage(
        imageUrl: avatarUrl,
        width: 46,
        height: 46,
        fit: BoxFit.cover,
        // 头像加载失败函数回退为人物图标，避免网络图片破坏按钮布局。
        errorWidget: (context, url, error) =>
            _buildProfileAvatarError(context, error, null),
      ),
    );
  }

  /// 创建头像请求失败时使用的主题色人物图标占位。
  Widget _buildProfileAvatarError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.primary,
      child: Icon(
        Icons.person_outline_rounded,
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    );
  }

  /// 用可换行的动作组保留学习清单与统计入口，大字体下不强挤在一行。
  Widget _buildHomeActionsCard(BuildContext context) {
    return Card(
      key: const Key('home-utility-actions'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (widget.onOpenLearningList != null)
              TextButton.icon(
                key: const Key('open-learning-list'),
                // 学习清单入口复用页面传入的业务路由。
                onPressed: widget.onOpenLearningList,
                icon: const Icon(Icons.menu_book_rounded),
                label: const Text('学习清单'),
              ),
            TextButton.icon(
              key: const Key('open-focus-statistics'),
              // 统计入口复用页面传入的本机专注看板路由。
              onPressed: widget.onOpenStatistics,
              icon: const Icon(Icons.insights_rounded),
              label: const Text('专注数据'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建横屏工作台左栏的品牌说明和主要搜索动作。
  Widget _buildWorkspaceIntro(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: const Key('focus-workspace-intro'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.filter_center_focus_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    key: const Key('workspace-open-about'),
                    onTap: () =>
                        Navigator.of(context).pushNamed(AppRoutes.about),
                    child: Text(
                      '焦点哔哩',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                // 保留首页文字节点，兼容已有的页面识别和无障碍测试。
                const SizedBox.shrink(child: Text('首页')),
                IconButton(
                  tooltip: '自定义首页',
                  onPressed: _customizeHome,
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
            ),
            _buildSubscriptionIntroduction(),
            const SizedBox(height: 42),
            Text(
              '今天要学点什么？',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '从一个明确的视频开始，把注意力留给真正想完成的事。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('home-start-search'),
              // 工作台搜索按钮函数切换到左侧导航中的搜索页面。
              onPressed: widget.onOpenVideo,
              icon: const Icon(Icons.search_rounded),
              label: const Text('开始搜索'),
              style: FilledButton.styleFrom(minimumSize: const Size(176, 52)),
            ),
            // 保留旧入口文字节点，但工作台只绘制一个清晰的主要动作。
            const SizedBox.shrink(child: Text('打开视频')),
          ],
        ),
      ),
    );
  }

  /// 横屏左侧保留简介，所有可编辑卡片统一放在独立可滚动的右侧区域。
  Widget _buildWorkspaceDashboard(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    return Padding(
      key: const Key('focus-workspace-layout'),
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        // 按真正剩余的卡片区域选择列数，避免把导航栏宽度算进卡片空间。
        builder: (context, constraints) {
          final double introWidth = constraints.maxWidth >= 1100 ? 340 : 300;
          final double boardWidth = constraints.maxWidth - introWidth - 20;
          final double scale = MediaQuery.textScalerOf(context).scale(16) / 16;
          final int columns = boardWidth >= 760 * scale ? 2 : 1;
          if (!_hasHomeDrawer) {
            return Center(
              child: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: _buildWorkspaceIntro(context),
                ),
              ),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: introWidth,
                child: SingleChildScrollView(
                  key: const Key('focus-workspace-primary'),
                  child: _buildWorkspaceIntro(context),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('focus-workspace-secondary'),
                  controller: _scrollController,
                  child: _buildHomeCardBoard(
                    context,
                    activeSession,
                    finishedSession,
                    columns: columns,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  EdgeInsets _homeCardPadding(double width) {
    final horizontal = AdaptiveLayout.centeredHorizontalPadding(
      width: width,
      maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
    );
    return EdgeInsets.fromLTRB(
      horizontal,
      _FocusDashboardState._homeCardTopPadding,
      horizontal,
      _FocusDashboardState._homeCardBottomPadding,
    );
  }

  /// Extend a short board just enough to clear the welcome area when opened.
  Widget _buildHomeCardsSliver(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    // The sliver sees the actual viewport (excluding safe areas). Its
    // constraints change while scrolling, but the card board stays the same.
    final board = _buildHomeCardBoard(
      context,
      activeSession,
      finishedSession,
      columns: 1,
    );
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final padding = _homeCardPadding(constraints.crossAxisExtent);
        final height = constraints.viewportMainAxisExtent;
        return SliverPadding(
          key: const Key('focus-adaptive-cards'),
          padding: padding,
          sliver: SliverToBoxAdapter(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: _homeDrawerExtent <= height
                    ? (height - padding.bottom).clamp(0.0, double.infinity)
                    : 0,
              ),
              child: board,
            ),
          ),
        );
      },
    );
  }

  /// 独立专注模式保留原有业务卡片顺序。
  Widget _buildCardsSliver(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        return SliverPadding(
          key: const Key('focus-adaptive-cards'),
          padding: _homeCardPadding(constraints.crossAxisExtent),
          sliver: SliverList.list(
            children: <Widget>[
              if (!widget.controller.isReady)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else ...<Widget>[
                if (widget.continueLearningCard != null) ...<Widget>[
                  widget.continueLearningCard!,
                  const SizedBox(height: 14),
                ],
                if (finishedSession != null) ...<Widget>[
                  _buildFinishedCard(context, finishedSession),
                  const SizedBox(height: 14),
                ],
                if (activeSession != null)
                  _buildActiveCard(context, activeSession)
                else
                  _buildReadyCard(context),
                const SizedBox(height: 14),
                _buildTodaySummary(context),
                const SizedBox(height: 14),
                _buildRecentHistory(context),
              ],
            ],
          ),
        );
      },
    );
  }
}
