part of 'focus_dashboard.dart';

/// 统一登记首页下方卡片；新增功能只需在登记表追加一个稳定编号。
extension _FocusDashboardHomeCards on _FocusDashboardState {
  /// 始终登记全部编号，暂时不可用的卡片只暂停显示而不删除用户顺序。
  List<DashboardCardDefinition> _homeCardDefinitions(
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    final bool ready = widget.controller.isReady;
    return <DashboardCardDefinition>[
      DashboardCardDefinition(
        id: 'home.continue_learning',
        title: '继续学习',
        icon: Icons.play_circle_outline_rounded,
        available: widget.continueLearningCard != null,
        // 继续学习构建函数复用外层服务维护的加载、空状态和任务卡片。
        builder: (_) => widget.continueLearningCard ?? const SizedBox.shrink(),
      ),
      DashboardCardDefinition(
        id: 'home.focus_finished',
        title: '专注结果',
        icon: Icons.check_circle_outline_rounded,
        available: ready && finishedSession != null,
        // 结果构建函数使用当前快照，关闭提示仍由原专注控制器处理。
        builder: (context) => finishedSession == null
            ? const SizedBox.shrink()
            : _buildFinishedCard(context, finishedSession),
      ),
      DashboardCardDefinition(
        id: 'home.focus_session',
        title: '专注任务',
        icon: Icons.timer_outlined,
        available: ready,
        // 同一编号在准备和计时状态之间切换，不因状态变化重置布局。
        builder: (context) => activeSession == null
            ? _buildReadyCard(context)
            : _buildActiveCard(context, activeSession),
      ),
      DashboardCardDefinition(
        id: 'home.today_summary',
        title: '今日汇总',
        icon: Icons.insights_rounded,
        available: ready,
        builder: _buildTodaySummary,
      ),
      DashboardCardDefinition(
        id: 'home.recent_history',
        title: '最近记录',
        icon: Icons.history_rounded,
        available: ready,
        builder: _buildRecentHistory,
      ),
      DashboardCardDefinition(
        id: 'home.quick_actions',
        title: '快捷入口',
        icon: Icons.apps_rounded,
        builder: _buildHomeActionsCard,
      ),
      DashboardCardDefinition(
        id: 'home.focus_subscriptions',
        title: '焦点订阅',
        icon: Icons.rss_feed_rounded,
        builder: (_) => const SubscriptionHomeCard(),
      ),
    ];
  }

  /// 所有首页卡片共享一个容器、存储身份和状态，跨行排序不会分成两套配置。
  Widget _buildHomeCardBoard(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession, {
    required int columns,
  }) {
    return EditableCardBoard(
      key: _homeBoardKey,
      storageId: 'home',
      items: _homeCardDefinitions(activeSession, finishedSession),
      service: widget.layoutService,
      scrollController: _scrollController,
      onEditingChanged: _handleHomeEditingChanged,
      columnCount: columns,
      spacing: 14,
    );
  }
}
