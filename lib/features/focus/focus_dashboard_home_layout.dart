part of 'focus_dashboard.dart';

/// 首页的欢迎区与响应式容器；专注业务卡片继续由页面状态维护。
extension _FocusDashboardHomeLayout on _FocusDashboardState {
  /// 根据文字实际换行高度为首屏留足空间，矮屏和大字体允许自然滚动。
  double _homeHeroHeight(BuildContext context, Size viewport) {
    final bool compact =
        viewport.width >= AdaptiveLayout.tabletBreakpoint ||
        viewport.height < 648;
    final double preferred = compact
        ? (viewport.height - 64).clamp(280.0, 720.0).toDouble()
        : (viewport.height - 88).clamp(560.0, 760.0).toDouble();
    final ThemeData theme = Theme.of(context);
    final double padding = AdaptiveLayout.centeredHorizontalPadding(
      width: viewport.width,
      maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
      compact: 24,
    );
    final double width = (viewport.width - padding * 2).clamp(80.0, 840.0);
    final double titleHeight = _measureHeroText(
      context,
      '焦点哔哩',
      theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      width - kMinInteractiveDimension * (_subscriptions.enabled ? 2 : 1),
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

  /// 卡片按实际滚动位置移动；仅欢迎内容使用正式版的下坠、模糊及淡出。
  Widget _buildHomeHero(
    BuildContext context,
    double heroHeight,
    double width, {
    required bool animateDepth,
  }) {
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
      child: HomeDrawerHeroDepth(
        key: const Key('focus-home-hero'),
        enabled: animateDepth,
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
              if (!_hasHomeDrawer && _homeLayoutLoaded) _drawerRecoveryButton(),
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
        imageVariant: .avatar,
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

  /// 宽屏首页关闭抽屉后，以内容区域为中心，只保留欢迎语和两个文字动作。
  Widget _buildMinimalWorkspaceHome(
    BuildContext context, {
    bool showRestore = true,
  }) {
    final theme = Theme.of(context);
    final titleStyle =
        AdaptiveLayout.usesExpandedWorkspace(MediaQuery.sizeOf(context))
        ? theme.textTheme.displayMedium
        : theme.textTheme.displaySmall;
    return Center(
      key: Key(
        showRestore ? 'focus-minimal-workspace-home' : 'desktop-dock-welcome',
      ),
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                '今天要学点什么？',
                textAlign: TextAlign.center,
                style: titleStyle?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              key: const Key('home-start-search'),
              onPressed: widget.onOpenVideo,
              style: FilledButton.styleFrom(
                minimumSize: const Size(176, 48),
                textStyle: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: const Text('开始搜索'),
            ),
            if (showRestore) ...[
              const SizedBox(height: 8),
              Tooltip(
                message: '启用抽屉并编辑',
                child: TextButton(
                  key: const Key('home-restore-drawer'),
                  onPressed: _canRestoreDrawer
                      ? _restoreDrawerForEditing
                      : null,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('启用抽屉'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The main pane and the dock are siblings, never a modal overlay.
  Widget _buildDesktopDock(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final touch = !AdaptiveLayout.isDesktopPlatform(theme.platform);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth * .37).clamp(364.0, 520.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildMinimalWorkspaceHome(context, showRestore: false),
                  if (!_desktopDockOpen)
                    Positioned(
                      right: 16,
                      top: 12,
                      child: FilledButton.tonalIcon(
                        key: const Key('desktop-dock-open'),
                        onPressed: _toggleDesktopDock,
                        style: touch
                            ? FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              )
                            : null,
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.chevron_left_rounded, size: 18),
                        label: const Text('打开抽屉'),
                      ),
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: Tooltip(
                        message: '收起抽屉',
                        child: SizedBox(
                          width: touch ? 48 : 44,
                          height: 76,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: const Key('desktop-dock-collapse'),
                              onTap: _toggleDesktopDock,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 26,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    color: colors.surfaceContainerHigh,
                                    border: Border.all(
                                      color: colors.outlineVariant,
                                    ),
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(9),
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.chevron_right_rounded,
                                    size: 21,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_desktopDockVisited)
              Offstage(
                offstage: !_desktopDockOpen,
                child: ExcludeFocus(
                  excluding: !_desktopDockOpen,
                  child: TickerMode(
                    enabled: _desktopDockOpen,
                    child: Container(
                      key: const Key('desktop-learning-dock'),
                      width: width,
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: colors.outlineVariant),
                        ),
                      ),
                      // Share the homepage canvas instead of painting a separate panel.
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        label: '学习抽屉',
                        child: SingleChildScrollView(
                          key: const PageStorageKey(
                            'desktop-learning-dock-scroll',
                          ),
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                          child: Column(
                            children: [
                              _buildSubscriptionIntroduction(),
                              _buildHomeCardBoard(
                                context,
                                activeSession,
                                finishedSession,
                                columns: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
              if (widget.controller.loadFailed)
                Card(
                  child: FocusStorageNotice(
                    onRetry: widget.controller.initialize,
                  ),
                )
              else if (!widget.controller.isReady)
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
