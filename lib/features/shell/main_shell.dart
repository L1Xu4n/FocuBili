import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../core/router/app_router.dart';
import '../../services/subscription_service.dart';
import '../home/home_page.dart';
import '../profile/profile_page.dart';
import '../search/search_page.dart';
import '../subscriptions/subscription_updates_page.dart';

/// 应用主框架，负责首页、搜索和“我的”三个一级页面的切换。
class MainShell extends StatefulWidget {
  const MainShell({super.key, this.subscriptionService});

  final SubscriptionService? subscriptionService;

  /// 创建主框架的可变状态，用于保存当前一级页面位置。
  @override
  State<MainShell> createState() => _MainShellState();
}

/// 保存主框架页面状态，并负责不经过中间页的水平过渡动画。
class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _navigationController;
  final _homePageKey = GlobalKey();
  late final SubscriptionService _subscriptions =
      widget.subscriptionService ?? SubscriptionService.instance;
  static const _subscriptionDestinationIndex = 3;
  int _currentIndex = 0;
  int? _transitionFrom;
  int? _transitionTo;
  int _homeRefreshGeneration = 0;

  /// 初始化一级页面过渡控制器，并在动画完成后提交目标页面索引。
  @override
  void initState() {
    super.initState();
    _navigationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addStatusListener(_handleNavigationStatus);
  }

  /// 切换到指定一级页面；只让当前页和目标页参与直接滑入动画。
  void _selectPage(int index) {
    if (index < 0 ||
        index > 2 ||
        index == _currentIndex ||
        _transitionTo != null) {
      return;
    }
    // 一级页面会常驻组件树；切走前必须解除当前输入焦点，避免隐藏搜索框继续接收键盘输入。
    FocusManager.instance.primaryFocus?.unfocus();
    if (AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context))) {
      _navigationController.stop();
      setState(() {
        _currentIndex = index;
        _transitionFrom = null;
        _transitionTo = null;
        if (index == 0) {
          _homeRefreshGeneration += 1;
        }
      });
      return;
    }
    setState(() {
      _transitionFrom = _currentIndex;
      _transitionTo = index;
      if (index == 0) {
        _homeRefreshGeneration += 1;
      }
    });
    unawaited(_navigationController.forward(from: 0));
  }

  /// 动画完成后提交目标页面，让隐藏页面继续保留在同一层级中。
  void _handleNavigationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }
    final int? targetIndex = _transitionTo;
    if (targetIndex == null) {
      return;
    }
    setState(() {
      _currentIndex = targetIndex;
      _transitionFrom = null;
      _transitionTo = null;
    });
  }

  /// 从首页的搜索入口直接切换到搜索页面。
  void _openSearch() {
    _selectPage(1);
  }

  /// 从“我的”页返回首页，并触发首页重新读取学习清单和账号头像。
  void _openHome() {
    _selectPage(0);
  }

  /// 从首页右上角的账号入口打开“我的”页。
  void _openProfile() {
    _selectPage(2);
  }

  /// 处理 Android 系统返回：搜索页和“我的”页先回首页，首页再交给系统退出。
  void _handleSystemBack(bool didPop, Object? result) {
    if (didPop || _transitionTo != null || _currentIndex == 0) {
      return;
    }
    _openHome();
  }

  /// 创建需要挂载到主框架的三个一级页面，并保持它们的顺序稳定。
  List<Widget> _buildPages({
    required bool workspace,
    required bool homeWorkspace,
  }) {
    return <Widget>[
      HomePage(
        key: _homePageKey,
        workspace: homeWorkspace,
        onSearchRequested: _openSearch,
        onProfileRequested: _openProfile,
        refreshGeneration: _homeRefreshGeneration,
        subscriptionService: _subscriptions,
      ),
      SearchPage(onBackRequested: workspace ? null : _openHome),
      ProfilePage(onBackRequested: workspace ? null : _openHome),
    ];
  }

  /// 创建横屏平板和桌面宽窗口使用的左侧一级导航。
  Widget _buildWorkspaceNavigation(
    Size windowSize, {
    required bool showSubscription,
    required bool showAbout,
  }) {
    final bool extended = AdaptiveLayout.usesExpandedWorkspace(windowSize);
    return NavigationRail(
      key: const Key('workspace-navigation-rail'),
      selectedIndex: _currentIndex,
      extended: extended,
      minWidth: AdaptiveLayout.compactNavigationWidth,
      minExtendedWidth: AdaptiveLayout.expandedNavigationWidth,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _buildWorkspaceLogo(showAbout: showAbout),
      ),
      destinations: <NavigationRailDestination>[
        const NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: Text('首页'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.search_rounded),
          selectedIcon: Icon(Icons.manage_search_rounded),
          label: Text('搜索'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('我的'),
        ),
        if (showSubscription) _buildWorkspaceSubscriptionDestination(),
      ],
      scrollable: showSubscription,
      onDestinationSelected: (index) {
        if (index == _subscriptionDestinationIndex) {
          Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SubscriptionUpdatesPage(service: _subscriptions),
            ),
          );
        } else {
          _selectPage(index);
        }
      },
    );
  }

  /// 宽屏首页复用品牌图标，保留原先平板简介中的关于入口。
  Widget _buildWorkspaceLogo({required bool showAbout}) {
    final radius = BorderRadius.circular(12);
    final logo = ClipRRect(
      borderRadius: radius,
      child: Image.asset(
        'assets/icon/focubili_icon.png',
        width: 42,
        height: 42,
      ),
    );
    if (!showAbout) return logo;
    return IconButton(
      key: const Key('workspace-navigation-open-about'),
      tooltip: '关于焦点哔哩',
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      onPressed: () => Navigator.of(context).pushNamed(AppRoutes.about),
      icon: logo,
    );
  }

  /// 复用侧栏入口的悬停、按压和键盘焦点反馈，但打开独立路由。
  NavigationRailDestination _buildWorkspaceSubscriptionDestination() {
    final unread = _subscriptions.unreadCount;
    const icon = Icon(Icons.rss_feed);
    return NavigationRailDestination(
      icon: KeyedSubtree(
        key: const Key('workspace-navigation-open-subscription'),
        child: unread == 0 ? icon : Badge.count(count: unread, child: icon),
      ),
      label: Text(
        '焦点订阅',
        semanticsLabel: unread == 0 ? '焦点订阅' : '焦点订阅，$unread 条未读',
      ),
    );
  }

  /// 创建保持三个一级页面状态的页面堆栈，手机端可选择启用水平切换动画。
  Widget _buildPageStack({
    required List<Widget> pages,
    required double width,
    required bool animate,
  }) {
    if (!animate) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (int index = 0; index < pages.length; index++)
            Positioned.fill(
              child: Offstage(
                offstage: index != _currentIndex,
                child: ExcludeFocus(
                  excluding: index != _currentIndex,
                  child: TickerMode(
                    enabled: index == _currentIndex,
                    child: pages[index],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _navigationController,
      builder: (BuildContext context, Widget? child) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            for (int index = 0; index < pages.length; index++)
              _buildPageLayer(pages[index], index, width),
          ],
        );
      },
    );
  }

  /// 创建一个页面层；过渡期间目标页从相邻方向滑入，搜索页不会被绘制。
  Widget _buildPageLayer(Widget page, int index, double width) {
    final int? transitionFrom = _transitionFrom;
    final int? transitionTo = _transitionTo;
    final bool transitioning = transitionFrom != null && transitionTo != null;
    final bool isVisible = transitioning
        ? index == transitionFrom || index == transitionTo
        : index == _currentIndex;
    final double progress = Curves.easeOutCubic.transform(
      _navigationController.value,
    );
    final double direction = transitioning && transitionTo > transitionFrom
        ? 1
        : -1;
    final double translation = !transitioning
        ? 0
        : index == transitionTo
        ? (1 - progress) * direction * width
        : -progress * direction * width;
    return Positioned.fill(
      child: Offstage(
        offstage: !isVisible,
        child: ExcludeFocus(
          excluding: index != (_transitionTo ?? _currentIndex),
          child: TickerMode(
            enabled: isVisible,
            child: Transform.translate(
              offset: Offset(translation, 0),
              child: page,
            ),
          ),
        ),
      ),
    );
  }

  /// 创建直接页面过渡层；各页始终保留在树中，所以搜索输入和滚动状态不会丢失。
  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _currentIndex == 0 && _transitionTo == null,
      onPopInvokedWithResult: _handleSystemBack,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size windowSize = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              final bool workspace = AdaptiveLayout.usesWorkspace(windowSize);
              // 软键盘把可见区域压矮不是旋转，不能让宽竖屏首页切到右侧抽屉。
              final bool homeWorkspace =
                  workspace &&
                  AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context));
              final List<Widget> pages = _buildPages(
                workspace: workspace,
                homeWorkspace: homeWorkspace,
              );
              final Widget pageStack = ClipRect(
                child: _buildPageStack(
                  pages: pages,
                  width: constraints.maxWidth,
                  animate: !workspace,
                ),
              );
              if (workspace) {
                return Row(
                  children: <Widget>[
                    ListenableBuilder(
                      listenable: _subscriptions,
                      builder: (context, _) {
                        // 平板只在首页接管旧简介的订阅和关于入口；不改变其他一级页。
                        final bool showHomeActions =
                            AdaptiveLayout.isDesktopPlatform(
                              Theme.of(context).platform,
                            ) ||
                            (homeWorkspace && _currentIndex == 0);
                        return _buildWorkspaceNavigation(
                          windowSize,
                          showSubscription:
                              showHomeActions && _subscriptions.enabled,
                          showAbout: showHomeActions,
                        );
                      },
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pageStack),
                  ],
                );
              }
              return ClipRect(child: pageStack);
            },
          ),
        ),
      ),
    );
  }

  /// 释放页面动画控制器，避免主框架离开后继续持有动画资源。
  @override
  void dispose() {
    _navigationController
      ..removeStatusListener(_handleNavigationStatus)
      ..dispose();
    super.dispose();
  }
}
