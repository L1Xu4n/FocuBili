import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/focus_session.dart';
import '../../models/learning_list_entry.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import '../focus/focus_dashboard.dart';
import '../focus/focus_timer_scope.dart';
import '../focus/focus_video_launcher.dart';
import '../learning/learning_list_page.dart';
import '../learning/learning_video_launcher.dart';

/// 专注导向的首页，把目标计时作为主动观看前的第一入口。
class HomePage extends StatefulWidget {
  /// 创建首页，并接收切换到“打开视频”页的回调和可替换的学习清单服务。
  const HomePage({
    super.key,
    required this.onSearchRequested,
    this.learningListService,
    this.videoService,
  });

  final VoidCallback onSearchRequested;
  final LearningListService? learningListService;
  final BilibiliService? videoService;

  /// 创建首页状态，用于读取并刷新唯一突出显示的继续学习任务。
  @override
  State<HomePage> createState() => _HomePageState();
}

/// 管理首页的继续学习任务读取、打开清单和恢复播放操作。
class _HomePageState extends State<HomePage> {
  late final LearningListService _learningListService;
  late final BilibiliService _videoService;
  LearningListEntry? _continueLearningEntry;
  bool _learningListLoading = true;

  /// 初始化学习清单服务，并异步读取当前唯一需要突出的学习任务。
  @override
  void initState() {
    super.initState();
    _learningListService = widget.learningListService ?? LearningListService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _reloadContinueLearning();
  }

  /// 从本机清单选择一条当前任务；服务会优先返回最近更新的“学习中”任务。
  Future<void> _reloadContinueLearning() async {
    if (mounted) {
      setState(() => _learningListLoading = true);
    }
    final LearningListEntry? entry = await _learningListService
        .loadCurrentTask();
    if (!mounted) {
      return;
    }
    setState(() {
      _continueLearningEntry = entry;
      _learningListLoading = false;
    });
  }

  /// 打开专注统计看板，查看趋势并统一管理本机记录。
  void _openFocusStatistics(BuildContext context) {
    Navigator.of(context).pushNamed(AppRoutes.focusStatistics);
  }

  /// 从首页 Pin 查询视频详情并恢复到关联分P和上次看到的位置。
  void _openLinkedVideo(BuildContext context, FocusSession session) {
    FocusVideoLauncher.open(context, session);
  }

  /// 打开完整学习清单，返回首页后重新读取播放器或管理页可能更新的任务。
  Future<void> _openLearningList() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 清单页面构建函数复用首页同一服务，保证测试和返回刷新使用同一数据源。
        builder: (BuildContext context) => LearningListPage(
          learningListService: _learningListService,
          videoService: _videoService,
        ),
      ),
    );
    if (mounted) {
      await _reloadContinueLearning();
    }
  }

  /// 恢复首页突出任务的分P和时间点，返回后刷新当前任务的最新状态。
  Future<void> _continueLearning(LearningListEntry entry) async {
    await LearningVideoLauncher.open(
      context,
      entry,
      service: _videoService,
      learningListService: _learningListService,
    );
    if (mounted) {
      await _reloadContinueLearning();
    }
  }

  /// 把秒数格式化为紧凑时间，供首页继续学习任务显示已学进度。
  String _formatPosition(Duration value) {
    final int seconds = value.inSeconds.clamp(0, 24 * 60 * 60);
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建只突出一条当前学习任务的首页卡片，并保留完整清单入口。
  Widget _buildContinueLearningCard(BuildContext context) {
    if (_learningListLoading) {
      return const Card(
        key: Key('continue-learning-loading'),
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('正在读取继续学习任务…'),
            ],
          ),
        ),
      );
    }
    final LearningListEntry? entry = _continueLearningEntry;
    if (entry == null) {
      return Card(
        key: const Key('continue-learning-empty'),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              const Icon(Icons.menu_book_outlined),
              const SizedBox(width: 10),
              const Expanded(child: Text('继续学习\n还没有未完成的学习任务。')),
              TextButton(
                // 查看清单函数打开统一管理页面，方便用户确认已完成任务。
                onPressed: () => unawaited(_openLearningList()),
                child: const Text('学习清单'),
              ),
            ],
          ),
        ),
      );
    }
    final double progress = entry.duration > Duration.zero
        ? (entry.position.inMilliseconds / entry.duration.inMilliseconds)
              .clamp(0, 1)
              .toDouble()
        : 0;
    return Card(
      key: const Key('continue-learning-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '继续学习',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('home-open-learning-list'),
                  // 完整清单函数不在首页堆叠多条任务，只在需要时打开管理页。
                  onPressed: () => unawaited(_openLearningList()),
                  child: const Text('查看清单'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'P${entry.partPageNumber} ${entry.partTitle} · ${entry.status.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_formatPosition(entry.position)} / ${_formatPosition(entry.duration)}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('home-continue-learning'),
              // 继续按钮函数查询视频最新详情，再交给播放器恢复任务位置。
              onPressed: () => unawaited(_continueLearning(entry)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('继续学习'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建使用应用级计时控制器的专注台，切换标签不会丢失当前状态。
  @override
  Widget build(BuildContext context) {
    return FocusDashboard(
      controller: FocusTimerScope.of(context),
      onOpenVideo: widget.onSearchRequested,
      onOpenStatistics: () => _openFocusStatistics(context),
      onOpenLinkedVideo: (FocusSession session) =>
          _openLinkedVideo(context, session),
      continueLearningCard: _buildContinueLearningCard(context),
      onOpenLearningList: () => unawaited(_openLearningList()),
    );
  }
}
