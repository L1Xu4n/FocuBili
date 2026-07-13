import 'package:flutter/material.dart';

import '../home/home_page.dart';
import '../profile/profile_page.dart';
import '../search/search_page.dart';

/// 应用主框架，负责首页、搜索和“我的”三个一级页面的切换。
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  /// 创建主框架的可变状态，用于保存当前底部导航位置。
  @override
  State<MainShell> createState() => _MainShellState();
}

/// 保存主框架当前页面，并维持各页面的滚动与输入状态。
class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  /// 切换到底部导航指定页面，并触发主框架刷新。
  void _selectPage(int index) {
    setState(() => _currentIndex = index);
  }

  /// 从首页的搜索入口直接切换到搜索页面。
  void _openSearch() {
    _selectPage(1);
  }

  /// 创建带 IndexedStack 的主界面，切页时不销毁已有页面状态。
  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      HomePage(onSearchRequested: _openSearch),
      const SearchPage(),
      const ProfilePage(),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _currentIndex, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        // 导航选择函数只更新本地页面索引，不进行网络请求。
        onDestinationSelected: _selectPage,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_rounded),
            selectedIcon: Icon(Icons.manage_search_rounded),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
