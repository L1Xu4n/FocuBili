import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import '../../models/focus_statistics.dart';
import 'focus_timer_controller.dart';
import 'focus_timer_scope.dart';
import 'focus_share_preview.dart';
import 'focus_video_launcher.dart';

/// 定义记录列表可以使用的完成状态筛选条件。
enum _FocusRecordStatusFilter { all, completed, endedEarly }

/// 定义记录列表支持的三种本机排序方式。
enum _FocusRecordOrder { newest, oldest, longest }

/// 展示专注指标、趋势和全部本机记录的统一统计管理页。
class FocusStatisticsPage extends StatefulWidget {
  /// 创建统计页；独立组件测试可以直接注入专注控制器。
  const FocusStatisticsPage({super.key, this.controller});

  final FocusTimerController? controller;

  /// 创建保存范围、筛选、排序和搜索文字的页面状态。
  @override
  State<FocusStatisticsPage> createState() => _FocusStatisticsPageState();
}

/// 管理统计看板的本机筛选条件和记录删除确认。
class _FocusStatisticsPageState extends State<FocusStatisticsPage> {
  final TextEditingController _searchController = TextEditingController();
  FocusStatisticsRange _range = FocusStatisticsRange.sevenDays;
  _FocusRecordStatusFilter _statusFilter = _FocusRecordStatusFilter.all;
  _FocusRecordOrder _order = _FocusRecordOrder.newest;

  /// 返回页面实际使用的应用级专注控制器。
  FocusTimerController _controller(BuildContext context) {
    return widget.controller ?? FocusTimerScope.of(context);
  }

  /// 在搜索文字变化时刷新本机记录列表。
  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
  }

  /// 搜索框变化只刷新列表，不修改原始历史记录。
  void _handleSearchChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 根据时间、状态、关键词和排序生成当前可见记录的副本。
  List<FocusSession> _visibleHistory(List<FocusSession> history, DateTime now) {
    final String keyword = _searchController.text.trim().toLowerCase();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? rangeStart = switch (_range) {
      FocusStatisticsRange.sevenDays => today.subtract(const Duration(days: 6)),
      FocusStatisticsRange.thirtyDays => today.subtract(
        const Duration(days: 29),
      ),
      FocusStatisticsRange.all => null,
    };
    final List<FocusSession> visible = history
        .where((FocusSession session) {
          final DateTime? finishedAt = session.finishedAt?.toLocal();
          if (finishedAt == null ||
              (rangeStart != null && finishedAt.isBefore(rangeStart))) {
            return false;
          }
          final bool statusMatches = switch (_statusFilter) {
            _FocusRecordStatusFilter.all => true,
            _FocusRecordStatusFilter.completed =>
              session.status == FocusSessionStatus.completed,
            _FocusRecordStatusFilter.endedEarly =>
              session.status == FocusSessionStatus.endedEarly,
          };
          if (!statusMatches) {
            return false;
          }
          if (keyword.isEmpty) {
            return true;
          }
          return session.goal.toLowerCase().contains(keyword) ||
              (session.sourceVideoTitle?.toLowerCase().contains(keyword) ??
                  false) ||
              (session.sourcePartTitle?.toLowerCase().contains(keyword) ??
                  false) ||
              (session.sourceBvid?.toLowerCase().contains(keyword) ?? false);
        })
        .toList(growable: true);
    switch (_order) {
      case _FocusRecordOrder.newest:
        visible.sort(_compareNewest);
        break;
      case _FocusRecordOrder.oldest:
        visible.sort(_compareOldest);
        break;
      case _FocusRecordOrder.longest:
        visible.sort(
          (FocusSession left, FocusSession right) => right
              .accumulatedFocusDuration
              .compareTo(left.accumulatedFocusDuration),
        );
        break;
    }
    return visible;
  }

  /// 按结束时间从新到旧比较两条记录。
  int _compareNewest(FocusSession left, FocusSession right) {
    return (right.finishedAt ?? right.startedAt).compareTo(
      left.finishedAt ?? left.startedAt,
    );
  }

  /// 按结束时间从旧到新比较两条记录。
  int _compareOldest(FocusSession left, FocusSession right) {
    return (left.finishedAt ?? left.startedAt).compareTo(
      right.finishedAt ?? right.startedAt,
    );
  }

  /// 删除前显示确认弹窗，防止统计记录被误操作移除。
  Future<void> _confirmDelete(
    FocusTimerController controller,
    FocusSession session,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除这条专注记录？'),
        content: Text('“${session.goal}”删除后无法恢复。'),
        actions: <Widget>[
          TextButton(
            // 取消删除函数只关闭弹窗，保留原始记录。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            // 确认删除函数把肯定结果交回页面统一处理。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteHistoryEntry(session.id);
    }
  }

  /// 清空前显示二次确认，活动专注不会随历史记录一起删除。
  Future<void> _confirmClearHistory(FocusTimerController controller) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空全部专注历史？'),
        content: const Text('已结束记录和统计会被清空，当前正在进行的专注会保留。'),
        actions: <Widget>[
          TextButton(
            // 取消清空函数关闭弹窗，不修改本机数据。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            // 确认清空函数只返回结果，实际存储操作由控制器完成。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('全部清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearHistory();
    }
  }

  /// 按当前时间范围生成冻结快照，并打开不会上传数据的分享预览。
  void _shareStatistics(FocusTimerController controller) {
    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: controller.history,
      range: _range,
      now: DateTime.now(),
      activeSession: controller.activeSession,
    );
    unawaited(showFocusStatisticsSharePreview(context, snapshot));
  }

  /// 将时长转换为适合指标卡和记录卡使用的紧凑文字。
  String _formatDuration(Duration duration) {
    final int totalMinutes = duration.inMinutes;
    if (totalMinutes < 60) {
      return '$totalMinutes 分钟';
    }
    final int hours = totalMinutes ~/ 60;
    final int minutes = totalMinutes % 60;
    return minutes == 0 ? '$hours 小时' : '$hours 小时 $minutes 分';
  }

  /// 将记录结束时间转换为本地年月日和时分。
  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '--';
    }
    final DateTime local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// 返回当前排序方式对应的中文名称。
  String _orderLabel(_FocusRecordOrder order) {
    return switch (order) {
      _FocusRecordOrder.newest => '最新',
      _FocusRecordOrder.oldest => '最早',
      _FocusRecordOrder.longest => '时长最多',
    };
  }

  /// 创建顶部四项核心指标组成的自适应看板网格。
  Widget _buildMetricBoard(FocusStatisticsSnapshot snapshot) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            _FocusMetricCard(
              key: const Key('focus-total-duration'),
              width: width,
              icon: Icons.timer_outlined,
              label: '专注总时长',
              value: _formatDuration(snapshot.totalFocusedDuration),
            ),
            _FocusMetricCard(
              key: const Key('focus-session-count'),
              width: width,
              icon: Icons.check_circle_outline_rounded,
              label: '专注记录',
              value: '${snapshot.sessionCount} 次',
            ),
            _FocusMetricCard(
              key: const Key('focus-completion-rate'),
              width: width,
              icon: Icons.track_changes_rounded,
              label: '按时完成率',
              value: '${(snapshot.completionRate * 100).round()}%',
            ),
            _FocusMetricCard(
              key: const Key('focus-day-count'),
              width: width,
              icon: Icons.calendar_today_outlined,
              label: '投入天数',
              value: '${snapshot.focusDayCount} 天',
            ),
          ],
        );
      },
    );
  }

  /// 创建完成率、平均时长、最长时长和连续天数的详细分析卡片。
  Widget _buildInsightCard(FocusStatisticsSnapshot snapshot) {
    return Card(
      key: const Key('focus-insight-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '完成情况',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: snapshot.completionRate,
              minHeight: 8,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 8),
            Text(
              '按时完成 ${snapshot.completedCount} 次 · '
              '提前结束 ${snapshot.endedEarlyCount} 次 · '
              '打断 ${snapshot.interruptionCount} 次',
            ),
            const Divider(height: 26),
            Wrap(
              spacing: 20,
              runSpacing: 10,
              children: <Widget>[
                Text('平均 ${_formatDuration(snapshot.averageFocusedDuration)}'),
                Text('最长 ${_formatDuration(snapshot.longestFocusedDuration)}'),
                Text('连续 ${snapshot.currentStreakDays} 天'),
                Text('关联视频 ${snapshot.linkedVideoCount} 个'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 创建关键词、状态和排序组成的记录管理工具栏。
  Widget _buildRecordFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: const Key('focus-history-search'),
          controller: _searchController,
          decoration: InputDecoration(
            hintText: '搜索目标、视频标题、分P或 BV 号',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    // 清除搜索函数恢复当前时间范围内的全部记录。
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '清除搜索',
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterChip(
                    label: const Text('全部'),
                    selected: _statusFilter == _FocusRecordStatusFilter.all,
                    // 全部筛选函数同时显示正常完成和提前结束记录。
                    onSelected: (_) => setState(
                      () => _statusFilter = _FocusRecordStatusFilter.all,
                    ),
                  ),
                  FilterChip(
                    label: const Text('按时完成'),
                    selected:
                        _statusFilter == _FocusRecordStatusFilter.completed,
                    // 完成筛选函数只显示倒计时自然结束的记录。
                    onSelected: (_) => setState(
                      () => _statusFilter = _FocusRecordStatusFilter.completed,
                    ),
                  ),
                  FilterChip(
                    label: const Text('提前结束'),
                    selected:
                        _statusFilter == _FocusRecordStatusFilter.endedEarly,
                    // 提前结束筛选函数只显示用户主动停止的记录。
                    onSelected: (_) => setState(
                      () => _statusFilter = _FocusRecordStatusFilter.endedEarly,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<_FocusRecordOrder>(
              key: const Key('focus-history-order'),
              initialValue: _order,
              tooltip: '记录排序',
              // 排序选择函数只重排当前副本，不改变存储顺序。
              onSelected: (_FocusRecordOrder value) =>
                  setState(() => _order = value),
              itemBuilder: (BuildContext context) => _FocusRecordOrder.values
                  .map(
                    (_FocusRecordOrder order) =>
                        PopupMenuItem<_FocusRecordOrder>(
                          value: order,
                          child: Text(_orderLabel(order)),
                        ),
                  )
                  .toList(growable: false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.sort_rounded),
                    const SizedBox(width: 4),
                    Text(_orderLabel(_order)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 创建单条记录卡片，包括来源视频、实际时长、状态和删除入口。
  Widget _buildHistoryCard(
    FocusTimerController controller,
    FocusSession session,
  ) {
    final bool completed = session.status == FocusSessionStatus.completed;
    final String? sourceTitle = session.sourceVideoTitle;
    return Card(
      key: Key('focus-history-${session.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // 记录点击函数查询关联 BV 并恢复到对应分P；无关联记录保持只读。
        onTap: session.hasBrowsableVideo
            ? () => unawaited(FocusVideoLauncher.open(context, session))
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CircleAvatar(
                child: Icon(
                  completed ? Icons.check_rounded : Icons.stop_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      session.goal,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${completed ? '按时完成' : '提前结束'} · '
                      '${_formatDuration(session.accumulatedFocusDuration)} / '
                      '${_formatDuration(session.plannedDuration)}',
                    ),
                    const SizedBox(height: 3),
                    Text(_formatDateTime(session.finishedAt)),
                    if (sourceTitle != null) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        '视频：$sourceTitle'
                        '${session.sourcePartPageNumber == null ? '' : ' · P${session.sourcePartPageNumber}'}'
                        '${session.sourcePartTitle == null ? '' : ' ${session.sourcePartTitle}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (session.interruptions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        '打断 ${session.interruptions.length} 次 · '
                        '最近原因：${session.latestInterruptionReason}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      ),
                    ],
                    if (session.terminationReason != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '终止原因：${session.terminationReason}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: Key('delete-focus-history-${session.id}'),
                // 删除按钮函数先要求确认，再从本机统计中移除该记录。
                onPressed: () => unawaited(_confirmDelete(controller, session)),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: '删除记录',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建统计看板、趋势、筛选工具和记录列表组成的完整页面。
  @override
  Widget build(BuildContext context) {
    final FocusTimerController controller = _controller(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('专注数据'),
        actions: <Widget>[
          IconButton(
            key: const Key('share-focus-statistics'),
            // 统计分享按钮函数按当前范围生成高清分享图预览。
            onPressed: () => _shareStatistics(controller),
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: '分享专注统计',
          ),
          IconButton(
            key: const Key('clear-focus-history'),
            // 清空按钮函数弹出统一管理确认框，活动计时始终保留。
            onPressed: controller.history.isEmpty
                ? null
                : () => unawaited(_confirmClearHistory(controller)),
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空专注历史',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (BuildContext context, Widget? child) {
          final DateTime now = DateTime.now();
          final FocusStatisticsSnapshot snapshot =
              FocusStatisticsCalculator.build(
                history: controller.history,
                range: _range,
                now: now,
                activeSession: controller.activeSession,
              );
          final List<FocusSession> visibleHistory = _visibleHistory(
            controller.history,
            now,
          );
          return ListView(
            key: const Key('focus-statistics-list'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              SegmentedButton<FocusStatisticsRange>(
                key: const Key('focus-statistics-range'),
                segments: const <ButtonSegment<FocusStatisticsRange>>[
                  ButtonSegment<FocusStatisticsRange>(
                    value: FocusStatisticsRange.sevenDays,
                    label: Text('7 天'),
                  ),
                  ButtonSegment<FocusStatisticsRange>(
                    value: FocusStatisticsRange.thirtyDays,
                    label: Text('30 天'),
                  ),
                  ButtonSegment<FocusStatisticsRange>(
                    value: FocusStatisticsRange.all,
                    label: Text('全部'),
                  ),
                ],
                selected: <FocusStatisticsRange>{_range},
                // 范围切换函数同时更新指标、趋势和下方记录列表。
                onSelectionChanged: (Set<FocusStatisticsRange> values) {
                  setState(() => _range = values.first);
                },
              ),
              if (controller.activeSession != null) ...<Widget>[
                const SizedBox(height: 12),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.adjust_rounded),
                    title: const Text('当前专注已计入今日趋势'),
                    subtitle: Text(controller.activeSession!.goal),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildMetricBoard(snapshot),
              const SizedBox(height: 12),
              _FocusTrendCard(snapshot: snapshot),
              const SizedBox(height: 12),
              _buildInsightCard(snapshot),
              const SizedBox(height: 22),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '专注记录管理',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text('${visibleHistory.length} 条'),
                ],
              ),
              const SizedBox(height: 10),
              _buildRecordFilters(),
              const SizedBox(height: 10),
              if (visibleHistory.isEmpty)
                const Card(
                  key: Key('empty-focus-history'),
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: Text('当前条件下没有专注记录')),
                  ),
                )
              else
                ...visibleHistory.map(
                  (FocusSession session) =>
                      _buildHistoryCard(controller, session),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 释放搜索输入控制器，离开统计页后不再保留文字监听。
  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }
}

/// 在看板网格中展示单项核心指标。
class _FocusMetricCard extends StatelessWidget {
  /// 创建固定宽度的图标、名称和指标值卡片。
  const _FocusMetricCard({
    super.key,
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  /// 创建单项指标卡的视觉布局。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 使用自适应折线图绘制最近 7 天或 30 天的每日专注趋势。
class _FocusTrendCard extends StatelessWidget {
  /// 创建读取统计快照的趋势卡片。
  const _FocusTrendCard({required this.snapshot});

  final FocusStatisticsSnapshot snapshot;

  /// 创建随卡片宽度伸缩的折线图，全部范围仍展示最近 30 天趋势。
  @override
  Widget build(BuildContext context) {
    final int maximumMilliseconds = snapshot.dailyTrend.fold<int>(
      0,
      (int current, FocusDailyStatistic item) =>
          item.focusedDuration.inMilliseconds > current
          ? item.focusedDuration.inMilliseconds
          : current,
    );
    final bool sevenDay = snapshot.dailyTrend.length == 7;
    return Card(
      key: const Key('focus-trend-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              sevenDay ? '近 7 天趋势' : '近 30 天趋势',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              snapshot.range == FocusStatisticsRange.all
                  ? '全部指标使用完整历史，趋势图展示最近 30 天'
                  : '折线表示每天实际投入的专注时间',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              key: const Key('focus-trend-line-chart'),
              height: 170,
              child: CustomPaint(
                painter: _FocusTrendPainter(
                  trend: snapshot.dailyTrend,
                  maximumMilliseconds: maximumMilliseconds,
                  lineColor: Theme.of(context).colorScheme.primary,
                  gridColor: Theme.of(context).colorScheme.outlineVariant,
                  labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按可用尺寸计算折线点、渐变填充、网格和稀疏日期标签。
class _FocusTrendPainter extends CustomPainter {
  /// 创建一张只依赖统计数据与主题颜色的趋势图。
  const _FocusTrendPainter({
    required this.trend,
    required this.maximumMilliseconds,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
  });

  final List<FocusDailyStatistic> trend;
  final int maximumMilliseconds;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;

  /// 在任意宽度上等距分布数据点，并为零数据保留可见基线。
  @override
  void paint(Canvas canvas, Size size) {
    if (trend.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final int verticalStepMinutes = _trendAxisStepMinutes(maximumMilliseconds);
    final int verticalMaximumMinutes = verticalStepMinutes * 3;
    final TextStyle axisLabelStyle = TextStyle(color: labelColor, fontSize: 9);
    final TextPainter widestVerticalLabel = TextPainter(
      text: TextSpan(
        text: _formatTrendAxisDuration(verticalMaximumMinutes),
        style: axisLabelStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double left = widestVerticalLabel.width + 12;
    const double right = 4;
    const double top = 8;
    const double bottom = 28;
    final Rect chart = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final Paint gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (int row = 0; row <= 3; row += 1) {
      final double y = chart.top + chart.height * row / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final int minutes = verticalMaximumMinutes - verticalStepMinutes * row;
      final TextPainter labelPainter = TextPainter(
        text: TextSpan(
          text: _formatTrendAxisDuration(minutes),
          style: axisLabelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(
          chart.left - labelPainter.width - 7,
          y - labelPainter.height / 2,
        ),
      );
    }
    final List<Offset> points = List<Offset>.generate(trend.length, (
      int index,
    ) {
      final double x = trend.length == 1
          ? chart.center.dx
          : chart.left + chart.width * index / (trend.length - 1);
      final double ratio =
          trend[index].focusedDuration.inMilliseconds /
          Duration(minutes: verticalMaximumMinutes).inMilliseconds;
      return Offset(x, chart.bottom - chart.height * ratio.clamp(0.0, 1.0));
    }, growable: false);
    final Path linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final Offset point in points.skip(1)) {
      linePath.lineTo(point.dx, point.dy);
    }
    final Path areaPath = Path.from(linePath)
      ..lineTo(points.last.dx, chart.bottom)
      ..lineTo(points.first.dx, chart.bottom)
      ..close();
    final Paint areaPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          lineColor.withValues(alpha: 0.28),
          lineColor.withValues(alpha: 0.02),
        ],
      ).createShader(chart);
    canvas.drawPath(areaPath, areaPaint);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final Paint pointPaint = Paint()..color = lineColor;
    for (final Offset point in points) {
      canvas.drawCircle(point, trend.length == 7 ? 3.5 : 2, pointPaint);
    }
    _paintDateLabels(canvas, chart, points);
  }

  /// 根据画布宽度抽样日期标签，始终保留起止日期且避免长范围挤在一起。
  void _paintDateLabels(Canvas canvas, Rect chart, List<Offset> points) {
    final List<int> labelIndexes = _adaptiveDateLabelIndexes(
      itemCount: trend.length,
      availableWidth: chart.width,
    );
    for (final int index in labelIndexes) {
      final DateTime date = trend[index].date;
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: '${date.month}/${date.day}',
          style: TextStyle(color: labelColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final double x = (points[index].dx - painter.width / 2).clamp(
        chart.left,
        chart.right - painter.width,
      );
      painter.paint(canvas, Offset(x, chart.bottom + 7));
    }
  }

  /// 数据或主题颜色改变时请求 Flutter 重绘趋势图。
  @override
  bool shouldRepaint(covariant _FocusTrendPainter oldDelegate) {
    return oldDelegate.trend != trend ||
        oldDelegate.maximumMilliseconds != maximumMilliseconds ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.labelColor != labelColor;
  }
}

/// 返回趋势图三等分纵轴使用的易读分钟步长。
int _trendAxisStepMinutes(int maximumMilliseconds) {
  final int maximumMinutes = maximumMilliseconds <= 0
      ? 1
      : (maximumMilliseconds / Duration.millisecondsPerMinute).ceil();
  final int target = (maximumMinutes / 3).ceil();
  const List<int> preferred = <int>[
    1,
    2,
    5,
    10,
    15,
    20,
    30,
    60,
    120,
    180,
    240,
    360,
    480,
    720,
    1440,
  ];
  for (final int value in preferred) {
    if (value >= target) {
      return value;
    }
  }
  return ((target / 1440).ceil()) * 1440;
}

/// 把纵轴分钟值压缩成不易挤占图表空间的中文时长。
String _formatTrendAxisDuration(int minutes) {
  if (minutes == 0) {
    return '0';
  }
  if (minutes < 60) {
    return '$minutes 分';
  }
  if (minutes % 60 == 0) {
    return '${minutes ~/ 60} 时';
  }
  return '${(minutes / 60).toStringAsFixed(1)} 时';
}

/// 按可用宽度决定日期标签数量，短范围尽量全显，长范围自动稀疏。
List<int> _adaptiveDateLabelIndexes({
  required int itemCount,
  required double availableWidth,
}) {
  if (itemCount <= 0) {
    return const <int>[];
  }
  if (itemCount == 1) {
    return const <int>[0];
  }
  final int maximumLabels = (availableWidth / 42).floor().clamp(2, itemCount);
  final int step = ((itemCount - 1) / (maximumLabels - 1)).ceil();
  final List<int> indexes = <int>[
    for (int index = 0; index < itemCount; index += step) index,
  ];
  if (indexes.last != itemCount - 1) {
    indexes.add(itemCount - 1);
  }
  return indexes;
}
