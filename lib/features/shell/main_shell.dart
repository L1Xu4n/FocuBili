import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_layout.dart';
import '../home/home_page.dart';
import '../profile/profile_page.dart';
import '../search/search_page.dart';

/// 应用主框架，负责首页、搜索和“我的”三个一级页面的切换。
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  /// 创建主框架的可变状态，用于保存当前一级页面位置。
  @override
  State<MainShell> createState() => _MainShellState();
}

/// 保存主框架页面状态，并负责不经过中间页的水平过渡动画。
class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _navigationController;
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
  List<Widget> _buildPages({required bool workspace}) {
    return <Widget>[
      HomePage(
        onSearchRequested: _openSearch,
        onProfileRequested: _openProfile,
        refreshGeneration: _homeRefreshGeneration,
      ),
      SearchPage(onBackRequested: workspace ? null : _openHome),
      ProfilePage(onBackRequested: workspace ? null : _openHome),
    ];
  }

  /// 创建横屏平板和桌面宽窗口使用的左侧一级导航。
  Widget _buildWorkspaceNavigation(Size windowSize) {
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/icon/focubili_icon.png',
            width: 42,
            height: 42,
          ),
        ),
      ),
      destinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: Text('首页'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.search_rounded),
          selectedIcon: Icon(Icons.manage_search_rounded),
          label: Text('搜索'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('我的'),
        ),
      ],
      onDestinationSelected: _selectPage,
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
              final List<Widget> pages = _buildPages(workspace: workspace);
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
                    _buildWorkspaceNavigation(windowSize),
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
