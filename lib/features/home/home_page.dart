import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/video_preview.dart';

/// 专注导向的首页，只提供主动打开公开视频和播放实验入口，不展示推荐流。
class HomePage extends StatelessWidget {
  /// 创建首页，并接收切换到“打开视频”页的回调。
  const HomePage({super.key, required this.onSearchRequested});

  final VoidCallback onSearchRequested;

  /// 打开公开 BV 播放实验页，用于检查原生播放桥的页面跳转。
  void _openPlayerPreview(BuildContext context) {
    Navigator.of(context).pushNamed(
      AppRoutes.player,
      arguments: VideoPreview.placeholder(),
    );
  }

  /// 创建首页欢迎区、视频打开入口、播放实验卡片和阶段提示。
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar.large(
          title: const Text('焦点哔哩'),
          actions: <Widget>[
            IconButton(
              // 打开视频按钮函数切换到主框架的输入标签页。
              onPressed: onSearchRequested,
              icon: const Icon(Icons.search_rounded),
              tooltip: '打开视频',
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          sliver: SliverList.list(
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('一次只看一支视频', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(
                        '首页没有推荐流。粘贴 BV 号或视频链接，开始一次有目的的观看。',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        // 主打开按钮函数进入输入视频编号的标签页。
                        onPressed: onSearchRequested,
                        icon: const Icon(Icons.search_rounded),
                        label: const Text('打开视频'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('播放实验', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading:
                      const CircleAvatar(child: Icon(Icons.play_arrow_rounded)),
                  title: const Text('原生播放实验'),
                  subtitle: const Text('通过直接播放数据加载公开 BV 视频'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  // 预览卡片函数打开播放器页面。
                  onTap: () => _openPlayerPreview(context),
                ),
              ),
              const SizedBox(height: 16),
              const _ArchitectureCard(),
            ],
          ),
        ),
      ],
    );
  }
}

/// 展示当前重构进度，让尚未接入的功能有清楚预期。
class _ArchitectureCard extends StatelessWidget {
  /// 创建当前架构能力状态卡片。
  const _ArchitectureCard();

  /// 创建新框架的模块状态列表。
  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('新框架已就绪',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            SizedBox(height: 12),
            _StatusRow(icon: Icons.check_circle_rounded, label: '页面与路由'),
            _StatusRow(icon: Icons.check_circle_rounded, label: '主题与底部导航'),
            _StatusRow(icon: Icons.check_circle_rounded, label: '公开 BV 视频详情'),
            _StatusRow(icon: Icons.pending_rounded, label: '原生视频流与弹幕'),
          ],
        ),
      ),
    );
  }
}

/// 用统一样式显示单个模块的完成状态。
class _StatusRow extends StatelessWidget {
  /// 创建一条图标加文字的架构状态。
  const _StatusRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  /// 创建图标和状态文字组成的一行内容。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }
}
