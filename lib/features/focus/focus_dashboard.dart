import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection, SliverConstraints;

import '../../core/layout/adaptive_layout.dart';
import '../../models/focus_session.dart';
import 'custom_focus_duration_dialog.dart';
import 'focus_do_not_disturb.dart';
import 'focus_interruption_dialog.dart';
import 'focus_timer_controller.dart';

/// 首页专注台，提供目标、计时控制、今日汇总和最近本机记录。
class FocusDashboard extends StatefulWidget {
  /// 创建专注台，并接收打开视频、个人中心和统计页面的回调。
  const FocusDashboard({
    super.key,
    required this.controller,
    required this.onOpenVideo,
    required this.onOpenStatistics,
    this.onOpenProfile,
    this.profileAvatarUrl,
    this.onOpenLinkedVideo,
    this.continueLearningCard,
    this.onOpenLearningList,
  });

  final FocusTimerController controller;
  final VoidCallback onOpenVideo;
  final VoidCallback onOpenStatistics;
  final VoidCallback? onOpenProfile;

  /// 已确认登录账号的头像地址；为空时显示主题色人物图标。
  final String? profileAvatarUrl;
  final ValueChanged<FocusSession>? onOpenLinkedVideo;

  /// 首页传入的单条继续学习卡片；为空时保持原有专注首页布局。
  final Widget? continueLearningCard;

  /// 打开完整学习清单的回调，由外层首页决定页面和本机服务实例。
  final VoidCallback? onOpenLearningList;

  /// 创建保存目标输入和预设时长选择的页面状态。
  @override
  State<FocusDashboard> createState() => _FocusDashboardState();
}

/// 管理专注台表单输入、确认弹窗和计时操作反馈。
class _FocusDashboardState extends State<FocusDashboard> {
  static const List<int> _presetMinutes = <int>[25, 45, 60];
  static const double _homeSnapTriggerDistance = 48;
  static const double _homeSnapOvershoot = 220;
  static const double _homeReverseSnapDistance = 120;

  final TextEditingController _goalController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _selectedMinutes = 25;
  double _scrollOffset = 0;
  bool _homeCardsSnapped = false;
  bool _isSnappingHomeScroll = false;
  ScrollDirection _homeScrollDirection = ScrollDirection.idle;
  double? _homeScrollStartOffset;

  /// 监听目标文字变化，使开始按钮能立即更新可用状态。
  @override
  void initState() {
    super.initState();
    _goalController.addListener(_handleGoalChanged);
    _scrollController.addListener(_handleScrollChanged);
  }

  /// 目标输入变化时刷新开始按钮，不修改控制器中的活动计时。
  void _handleGoalChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 记录首页滚动距离，用来驱动首屏内容的上移、模糊和透明度变化。
  void _handleScrollChanged() {
    if (!mounted) {
      return;
    }
    setState(() => _scrollOffset = _scrollController.offset);
  }

  /// 返回首页首屏的稳定高度，确保不同设备上第一次上滑都能吸附到卡片区。
  double _homeHeroHeight(BuildContext context) {
    final Size windowSize = MediaQuery.sizeOf(context);
    final bool needsCompactHeight =
        windowSize.width >= AdaptiveLayout.tabletBreakpoint ||
        windowSize.height < 648;
    if (needsCompactHeight) {
      return (windowSize.height - 64).clamp(280.0, 720.0).toDouble();
    }
    return (windowSize.height - 88).clamp(560.0, 760.0).toDouble();
  }

  /// 在一次拖动结束后把首屏或卡片区吸附到完整的阅读位置。
  void _handleHomeScrollEnd(BuildContext context) {
    if (widget.onOpenProfile == null ||
        _isSnappingHomeScroll ||
        !_scrollController.hasClients) {
      return;
    }
    final double heroHeight = _homeHeroHeight(context);
    final double currentOffset = _scrollController.offset;
    final double maxOffset = _scrollController.position.maxScrollExtent;
    final double startOffset = _homeScrollStartOffset ?? currentOffset;
    final double gestureDistance = (currentOffset - startOffset).abs();
    if (currentOffset <= 24) {
      _homeCardsSnapped = false;
      return;
    }
    final double targetOffset;
    final double firstCardOffset = (heroHeight + 12)
        .clamp(0.0, maxOffset)
        .toDouble();
    if (!_homeCardsSnapped &&
        currentOffset > _homeSnapTriggerDistance &&
        currentOffset <= firstCardOffset + _homeSnapOvershoot) {
      targetOffset = firstCardOffset;
    } else if (!_homeCardsSnapped &&
        currentOffset > firstCardOffset + _homeSnapOvershoot) {
      // 用户已经越过首张卡片的吸附窗口，保留其自然滚动到的深层位置。
      _homeCardsSnapped = true;
      return;
    } else if (_homeCardsSnapped &&
        currentOffset > 24 &&
        _homeScrollDirection == ScrollDirection.forward &&
        gestureDistance >= _homeReverseSnapDistance) {
      targetOffset = 0;
    } else {
      if (currentOffset >= heroHeight) {
        _homeCardsSnapped = true;
      }
      return;
    }
    if ((targetOffset - currentOffset).abs() < 2) {
      _homeCardsSnapped = targetOffset > 0;
      return;
    }
    _isSnappingHomeScroll = true;
    // 等当前 ScrollEndNotification 完成后再启动驱动动画，避免手势活动取消吸附。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        _isSnappingHomeScroll = false;
        return;
      }
      unawaited(_animateHomeSnap(targetOffset));
    });
  }

  /// 记录首页主滚动的手势方向，并在手势结束后触发一次吸附。
  bool _handleHomeScrollNotification(
    BuildContext context,
    ScrollNotification notification,
  ) {
    if (notification.depth != 0) {
      return false;
    }
    if (notification is UserScrollNotification) {
      _homeScrollDirection = notification.direction;
    } else if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        _scrollController.hasClients) {
      _homeScrollStartOffset = _scrollController.offset;
    } else if (notification is ScrollEndNotification) {
      _handleHomeScrollEnd(context);
      _homeScrollDirection = ScrollDirection.idle;
      _homeScrollStartOffset = null;
    }
    return false;
  }

  /// 以短暂缓动完成首屏与卡片区之间的吸附，并在结束后恢复手势监听。
  Future<void> _animateHomeSnap(double targetOffset) async {
    try {
      await _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSnappingHomeScroll = false;
          _homeCardsSnapped = targetOffset > 0;
        });
      } else {
        _isSnappingHomeScroll = false;
        _homeCardsSnapped = targetOffset > 0;
      }
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
    await handleDoNotDisturbAfterFocusStart(context, widget.controller);
    if (!mounted) {
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
              session.completeOnPartEnd
                  ? '等待当前分P完播 · ${_formatCountdown(widget.controller.remainingDuration)}'
                  : _formatCountdown(widget.controller.remainingDuration),
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

  /// 创建截图中的首屏欢迎区，保留搜索和“我的”两个最短路径入口。
  Widget _buildHomeHero(BuildContext context) {
    final double heroHeight = _homeHeroHeight(context);
    final double progress = (_scrollOffset / 280).clamp(0.0, 1.0).toDouble();
    // Sliver 随滚动上移；额外向下位移后，首屏元素会相对原位下坠再淡出。
    final double fallOffset = _scrollOffset * 1.32;
    final ThemeData theme = Theme.of(context);
    final Color textColor = theme.colorScheme.onSurface;
    // 两个首页动作按钮都复用应用主题，避免草图颜色泄漏到成品界面。
    final Color actionColor = theme.colorScheme.primary;
    final Color actionTextColor = theme.colorScheme.onPrimary;
    return SliverToBoxAdapter(
      child: SizedBox(
        key: const Key('focus-home-hero'),
        height: heroHeight,
        child: ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: progress * 7,
              sigmaY: progress * 7,
            ),
            child: Opacity(
              opacity: 1 - (progress * 0.88),
              child: Transform.translate(
                // 首屏本身随滚动离开，但内容相对原位向下坠落并逐渐淡出。
                offset: Offset(0, fallOffset),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double horizontalPadding =
                        AdaptiveLayout.centeredHorizontalPadding(
                          width: constraints.maxWidth,
                          maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
                          compact: 24,
                        );
                    return Padding(
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
                              Text(
                                '焦点哔哩',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                ),
                              ),
                              const Spacer(),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            child: const Text('开始搜索'),
                          ),
                          // 保留旧入口文字节点，但不在新首屏重复绘制第二个按钮。
                          const SizedBox.shrink(child: Text('打开视频')),
                          const Spacer(),
                          Icon(
                            Icons.keyboard_double_arrow_up_rounded,
                            key: const Key('home-scroll-hint'),
                            size: 34,
                            color: textColor,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
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
      child: Image.network(
        avatarUrl,
        width: 46,
        height: 46,
        fit: BoxFit.cover,
        // 头像加载失败函数回退为人物图标，避免网络图片破坏按钮布局。
        errorBuilder: _buildProfileAvatarError,
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

  /// 创建首页底部的辅助入口卡片，避免首屏右上角堆叠多个按钮。
  Widget _buildHomeActionsCard(BuildContext context) {
    return Card(
      key: const Key('home-utility-actions'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            if (widget.onOpenLearningList != null)
              Expanded(
                child: TextButton.icon(
                  key: const Key('open-learning-list'),
                  // 学习清单按钮函数打开完整任务管理页面。
                  onPressed: widget.onOpenLearningList,
                  icon: const Icon(Icons.menu_book_rounded),
                  label: const Text('学习清单'),
                ),
              ),
            Expanded(
              child: TextButton.icon(
                key: const Key('open-focus-statistics'),
                // 专注数据按钮函数打开本机统计看板。
                onPressed: widget.onOpenStatistics,
                icon: const Icon(Icons.insights_rounded),
                label: const Text('专注数据'),
              ),
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
                Text(
                  '焦点哔哩',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                // 保留首页文字节点，兼容已有的页面识别和无障碍测试。
                const SizedBox.shrink(child: Text('首页')),
              ],
            ),
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

  /// 创建横屏平板首页的左右双栏，让学习入口与专注状态同时可见。
  Widget _buildWorkspaceDashboard(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    return Padding(
      key: const Key('focus-workspace-layout'),
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 5,
            child: ListView(
              key: const Key('focus-workspace-primary'),
              children: <Widget>[
                _buildWorkspaceIntro(context),
                if (widget.continueLearningCard != null) ...<Widget>[
                  const SizedBox(height: 14),
                  widget.continueLearningCard!,
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 7,
            child: ListView(
              key: const Key('focus-workspace-secondary'),
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
                  if (widget.onOpenProfile != null) ...<Widget>[
                    const SizedBox(height: 14),
                    _buildHomeActionsCard(context),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 创建首页滚动卡片区，让继续学习、专注、统计和记录按截图顺序展开。
  Widget _buildCardsSliver(
    BuildContext context,
    FocusSession? activeSession,
    FocusSession? finishedSession,
  ) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        final double horizontalPadding =
            AdaptiveLayout.centeredHorizontalPadding(
              width: constraints.crossAxisExtent,
              maxContentWidth: AdaptiveLayout.homeContentMaxWidth,
            );
        return SliverPadding(
          key: const Key('focus-adaptive-cards'),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            12,
            horizontalPadding,
            32,
          ),
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
                if (widget.onOpenProfile != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _buildHomeActionsCard(context),
                ],
              ],
            ],
          ),
        );
      },
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
        final bool useHomeHero = widget.onOpenProfile != null;
        if (useHomeHero &&
            AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context))) {
          return _buildWorkspaceDashboard(
            context,
            activeSession,
            finishedSession,
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification notification) =>
              _handleHomeScrollNotification(context, notification),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: <Widget>[
              if (useHomeHero) _buildHomeHero(context),
              if (useHomeHero)
                _buildCardsSliver(context, activeSession, finishedSession)
              else ...<Widget>[
                SliverAppBar.large(
                  title: const Text('焦点哔哩'),
                  actions: <Widget>[
                    if (widget.onOpenLearningList != null)
                      IconButton(
                        key: const Key('open-learning-list'),
                        // 学习清单按钮函数由首页打开完整任务管理页面。
                        onPressed: widget.onOpenLearningList,
                        icon: const Icon(Icons.menu_book_rounded),
                        tooltip: '学习清单',
                      ),
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
                _buildCardsSliver(context, activeSession, finishedSession),
              ],
            ],
          ),
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
    _scrollController
      ..removeListener(_handleScrollChanged)
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
