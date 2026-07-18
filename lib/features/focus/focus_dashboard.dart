import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import 'custom_focus_duration_dialog.dart';
import 'focus_interruption_dialog.dart';
import 'focus_timer_controller.dart';

/// 首页专注台，提供目标、计时控制、今日汇总和最近本机记录。
class FocusDashboard extends StatefulWidget {
  /// 创建专注台，并接收打开视频页签的回调和应用级计时控制器。
  const FocusDashboard({
    super.key,
    required this.controller,
    required this.onOpenVideo,
    required this.onOpenStatistics,
    this.onOpenLinkedVideo,
  });

  final FocusTimerController controller;
  final VoidCallback onOpenVideo;
  final VoidCallback onOpenStatistics;
  final ValueChanged<FocusSession>? onOpenLinkedVideo;

  /// 创建保存目标输入和预设时长选择的页面状态。
  @override
  State<FocusDashboard> createState() => _FocusDashboardState();
}

/// 管理专注台表单输入、确认弹窗和计时操作反馈。
class _FocusDashboardState extends State<FocusDashboard> {
  static const List<int> _presetMinutes = <int>[25, 45, 60];

  final TextEditingController _goalController = TextEditingController();
  int _selectedMinutes = 25;

  /// 监听目标文字变化，使开始按钮能立即更新可用状态。
  @override
  void initState() {
    super.initState();
    _goalController.addListener(_handleGoalChanged);
  }

  /// 目标输入变化时刷新开始按钮，不修改控制器中的活动计时。
  void _handleGoalChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 使用当前目标和所选分钟数开始专注，并在失败时给出可读提示。
  Future<void> _startFocus() async {
    final bool started = await widget.controller.startFocus(
      goal: _goalController.text,
      duration: Duration(minutes: _selectedMinutes),
      startImmediately: false,
    );
    if (!mounted) {
      return;
    }
    if (!started) {
      _showMessage('请填写目标，并选择 1 到 180 分钟。');
      return;
    }
    FocusScope.of(context).unfocus();
    final bool? openVideo = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('专注任务已创建'),
        content: const Text('请打开一个视频关联本次专注任务'),
        actions: <Widget>[
          TextButton(
            // 稍后打开函数保留等待关联的首页 Pin。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            // 打开视频函数关闭说明并进入用户主动搜索页。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.ondemand_video_rounded),
            label: const Text('打开视频'),
          ),
        ],
      ),
    );
    if (openVideo == true && mounted) {
      widget.onOpenVideo();
    }
  }

  /// 弹出自定义分钟输入框，只接受 1 到 180 的整数。
  Future<void> _selectCustomDuration() async {
    final int? result = await showCustomFocusDurationDialog(
      context,
      initialMinutes: _selectedMinutes,
    );
    if (result != null && mounted) {
      setState(() => _selectedMinutes = result);
    }
  }

  /// 询问用户是否提前结束，确认后由控制器保存实际专注时长。
  Future<void> _confirmEndFocus() async {
    final String? reason = await showFocusTerminationReasonDialog(context);
    if (reason != null) {
      await widget.controller.endFocusEarly(reason: reason);
    }
  }

  /// 手动暂停前显示鼓励，并在用户坚持时记录原因与可选提醒。
  Future<void> _pauseWithEncouragement() async {
    await showFocusInterruptionFlow(
      context,
      controller: widget.controller,
      kind: FocusInterruptionKind.manualPause,
    );
  }

  /// 继续按钮打开关联视频；未关联时进入视频搜索等待用户确认关联。
  void _continueFocus(FocusSession session) {
    if (session.hasVideoAssociation && widget.onOpenLinkedVideo != null) {
      widget.onOpenLinkedVideo!(session);
      return;
    }
    _showMessage('请先打开一个视频并确认关联，播放后计时会自动继续。');
    widget.onOpenVideo();
  }

  /// 根据暂停业务原因返回首页 Pin 中的明确状态文字。
  String _activeStatusLabel(FocusSession session) {
    if (session.status == FocusSessionStatus.running) {
      return '正在专注';
    }
    return switch (session.pauseReason) {
      FocusPauseReason.awaitingVideo => '等待关联视频',
      FocusPauseReason.playback => '等待视频播放',
      FocusPauseReason.interruption => '专注被打断',
      FocusPauseReason.manual => '已暂停',
      null => '已暂停',
    };
  }

  /// 给当前专注延长五分钟，超过三小时上限时显示可读提示。
  Future<void> _extendFocus() async {
    final bool extended = await widget.controller.extendFocus(
      const Duration(minutes: 5),
    );
    if (mounted && !extended) {
      _showMessage('计划总时长最多为 180 分钟。');
    }
  }

  /// 在首页底部显示一次短提示，避免操作失败时静默无反馈。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把倒计时格式化为“分:秒”或“时:分:秒”。
  String _formatCountdown(Duration duration) {
    final int totalSeconds = ((duration.inMilliseconds + 999) ~/ 1000).clamp(
      0,
      24 * 60 * 60,
    );
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// 把首页 Pin 保存的视频位置格式化为“视频时间点 12:34”一类的可读文字。
  String _formatVideoPosition(Duration duration) {
    final int totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// 把历史时间转换为紧凑的月日与时分，避免列表堆叠完整时间戳。
  String _formatRecordedAt(DateTime? value) {
    if (value == null) {
      return '--';
    }
    final DateTime local = value.toLocal();
    return '${local.month}月${local.day}日 '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// 创建目标输入、时长快捷选项和开始按钮组成的空闲卡片。
  Widget _buildReadyCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canStart = _goalController.text.trim().isNotEmpty;
    final bool customSelected = !_presetMinutes.contains(_selectedMinutes);
    return Card(
      key: const Key('focus-ready-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('准备专注', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text('先写下这段时间唯一要完成的事。', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 18),
            TextField(
              key: const Key('focus-goal-field'),
              controller: _goalController,
              maxLength: FocusTimerController.maximumGoalCharacters,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '专注目标',
                hintText: '例如：看完高数第三章',
                prefixIcon: Icon(Icons.flag_outlined),
              ),
            ),
            const SizedBox(height: 8),
            Text('计划时长', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ..._presetMinutes.map(
                  (int minutes) => ChoiceChip(
                    key: Key('focus-duration-$minutes'),
                    label: Text('$minutes 分钟'),
                    selected: _selectedMinutes == minutes,
                    // 预设时长选择函数只更新表单，不会自动开始计时。
                    onSelected: (_) =>
                        setState(() => _selectedMinutes = minutes),
                  ),
                ),
                ChoiceChip(
                  key: const Key('focus-duration-custom'),
                  label: Text(customSelected ? '$_selectedMinutes 分钟' : '自定义'),
                  selected: customSelected,
                  // 自定义时长函数打开分钟输入弹窗。
                  onSelected: (_) => unawaited(_selectCustomDuration()),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('start-focus-button'),
              // 开始按钮函数验证表单后创建应用级专注记录。
              onPressed: canStart ? () => unawaited(_startFocus()) : null,
              icon: const Icon(Icons.timer_rounded),
              label: const Text('开始专注'),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              key: const Key('open-video-without-focus'),
              // 直接打开函数允许用户暂时不计时，仍保持首页没有推荐流的主动入口。
              onPressed: widget.onOpenVideo,
              icon: const Icon(Icons.search_rounded),
              label: const Text('打开视频'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建进行中或暂停中的大号倒计时、进度条和控制按钮。
  Widget _buildActiveCard(BuildContext context, FocusSession session) {
    final ThemeData theme = Theme.of(context);
    final bool paused = session.status == FocusSessionStatus.paused;
    final String statusLabel = _activeStatusLabel(session);
    return Card(
      key: const Key('active-focus-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  paused ? Icons.pause_circle_outline : Icons.adjust_rounded,
                  color: paused ? theme.colorScheme.tertiary : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(statusLabel),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              session.goal,
              key: const Key('active-focus-goal'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _formatCountdown(widget.controller.remainingDuration),
              key: const Key('focus-countdown'),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: const Key('focus-progress'),
              value: widget.controller.progress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(999),
            ),
            if (session.latestInterruptionReason != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '上次打断：${session.latestInterruptionReason}',
                key: const Key('focus-last-interruption-reason'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
            if (session.hasVideoAssociation) ...<Widget>[
              const SizedBox(height: 14),
              InkWell(
                key: const Key('focus-linked-video-pin'),
                borderRadius: BorderRadius.circular(12),
                // Pin 点击函数直接恢复关联视频与最后播放位置。
                onTap: widget.onOpenLinkedVideo == null
                    ? null
                    : () => widget.onOpenLinkedVideo!(session),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        session.sourceVideoTitle ?? '关联视频',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'P${session.sourcePartPageNumber ?? 1} '
                        '${session.sourcePartTitle ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      const Text('上次看到'),
                      Text(
                        '视频时间点 ${_formatVideoPosition(session.sourcePosition)}',
                        key: const Key('focus-last-seen-position'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      if (session.sourceFramePath != null &&
                          File(session.sourceFramePath!).existsSync())
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Image.file(
                              File(session.sourceFramePath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Colors.black26,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        const AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ColoredBox(
                            color: Colors.black26,
                            child: Center(
                              child: Icon(Icons.ondemand_video_rounded),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    key: Key(
                      paused ? 'resume-focus-button' : 'pause-focus-button',
                    ),
                    // 暂停或继续函数由当前状态选择唯一合法的控制器操作。
                    onPressed: () => paused
                        ? _continueFocus(session)
                        : unawaited(_pauseWithEncouragement()),
                    icon: Icon(
                      paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    ),
                    label: Text(paused ? '继续' : '暂停'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('end-focus-button'),
                    // 结束函数先弹出确认，避免误触丢失正在进行的状态。
                    onPressed: () => unawaited(_confirmEndFocus()),
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('结束'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('extend-focus-button'),
              // 续时按钮函数在允许范围内给当前专注增加五分钟。
              onPressed: () => unawaited(_extendFocus()),
              icon: const Icon(Icons.more_time_rounded),
              label: const Text('+5 分钟'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建最近一次完成或提前结束的结果提示卡片。
  Widget _buildFinishedCard(BuildContext context, FocusSession session) {
    final bool completed = session.status == FocusSessionStatus.completed;
    return Card(
      key: const Key('focus-finished-card'),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
        leading: CircleAvatar(
          child: Icon(completed ? Icons.check_rounded : Icons.stop_rounded),
        ),
        title: Text(completed ? '专注完成' : '已提前结束'),
        subtitle: Text(
          '${session.goal}\n实际专注 ${session.accumulatedFocusDuration.inMinutes} 分钟',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          // 关闭结果函数仅隐藏提示，历史记录仍保存在本机。
          onPressed: widget.controller.dismissLastFinishedSession,
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
        ),
      ),
    );
  }

  /// 创建今日专注分钟和正常完成次数的轻量汇总卡片。
  Widget _buildTodaySummary(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: const Key('focus-today-summary'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _FocusMetric(
                label: '今日专注',
                value: '${widget.controller.todayFocusedDuration().inMinutes}',
                unit: '分钟',
              ),
            ),
            SizedBox(
              height: 46,
              child: VerticalDivider(color: theme.colorScheme.outlineVariant),
            ),
            Expanded(
              child: _FocusMetric(
                label: '按时完成',
                value: '${widget.controller.todayCompletedCount()}',
                unit: '次',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建最多五条最近专注记录，空历史时显示本机保存说明。
  Widget _buildRecentHistory(BuildContext context) {
    final List<FocusSession> recent = widget.controller.history
        .take(5)
        .toList(growable: false);
    return Card(
      key: const Key('focus-recent-history'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 8),
              child: Text(
                '最近记录',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            if (recent.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 4, 18, 14),
                child: Text('完成或结束一次专注后，记录会保存在当前设备。'),
              )
            else
              ...recent.map(
                (FocusSession session) => ListTile(
                  leading: Icon(
                    session.status == FocusSessionStatus.completed
                        ? Icons.check_circle_outline_rounded
                        : Icons.timelapse_rounded,
                  ),
                  title: Text(
                    session.goal,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_formatRecordedAt(session.finishedAt)} · '
                    '${session.accumulatedFocusDuration.inMinutes} 分钟',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 创建专注台完整滚动页面，并随控制器每秒更新活动倒计时和统计。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final FocusSession? activeSession = widget.controller.activeSession;
        final FocusSession? finishedSession =
            widget.controller.lastFinishedSession;
        return CustomScrollView(
          slivers: <Widget>[
            SliverAppBar.large(
              title: const Text('焦点哔哩'),
              actions: <Widget>[
                IconButton(
                  key: const Key('open-focus-statistics'),
                  // 统计按钮函数打开本机专注看板与统一记录管理页。
                  onPressed: widget.onOpenStatistics,
                  icon: const Icon(Icons.insights_rounded),
                  tooltip: '专注数据',
                ),
                IconButton(
                  // 顶部打开视频函数直接切换到搜索页。
                  onPressed: widget.onOpenVideo,
                  icon: const Icon(Icons.search_rounded),
                  tooltip: '打开视频',
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
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
                    if (finishedSession != null) ...<Widget>[
                      _buildFinishedCard(context, finishedSession),
                      const SizedBox(height: 12),
                    ],
                    if (activeSession != null)
                      _buildActiveCard(context, activeSession)
                    else
                      _buildReadyCard(context),
                    const SizedBox(height: 12),
                    _buildTodaySummary(context),
                    const SizedBox(height: 12),
                    _buildRecentHistory(context),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 释放目标输入控制器，离开应用后不再保留文本监听。
  @override
  void dispose() {
    _goalController
      ..removeListener(_handleGoalChanged)
      ..dispose();
    super.dispose();
  }
}

/// 在今日汇总卡中显示一个带单位的专注指标。
class _FocusMetric extends StatelessWidget {
  /// 创建单项指标文字，数值保持突出但不引入排行榜压力。
  const _FocusMetric({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  /// 创建指标标题、数值和单位的垂直布局。
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Text(label, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(
                text: value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(text: ' $unit'),
            ],
          ),
        ),
      ],
    );
  }
}
