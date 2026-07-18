import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import 'custom_focus_duration_dialog.dart';
import 'focus_interruption_dialog.dart';
import 'focus_timer_controller.dart';

/// 显示首页任务与当前视频的关联确认面板，并返回用户是否确认。
Future<bool?> showFocusVideoAssociationSheet(
  BuildContext context, {
  required String goal,
  required String videoTitle,
  required int partPageNumber,
  required String partTitle,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '是否将“$goal”关联到当前播放的视频？',
            style: Theme.of(sheetContext).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '$videoTitle · P$partPageNumber $partTitle',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: const Key('cancel-focus-video-association'),
                  // 取消关联函数仅忽略当前候选，切换视频后仍可再次询问。
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: const Key('confirm-focus-video-association'),
                  // 确认关联函数只返回选择，播放器随后采集点击时的真实画面。
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: const Text('确认关联'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 定义从播放器开始专注时可选择的计划方式。
enum _PlayerFocusDurationChoice {
  twentyFiveMinutes,
  fortyFiveMinutes,
  part,
  custom,
}

/// 提供播放器内开始和控制专注的底部面板。
class PlayerFocusSheet extends StatefulWidget {
  /// 创建播放器专注面板，并携带当前视频与分P来源信息。
  const PlayerFocusSheet({
    super.key,
    required this.controller,
    required this.defaultGoal,
    required this.partRemainingDuration,
    required this.bvid,
    required this.videoTitle,
    required this.partCid,
    required this.partPageNumber,
    required this.partTitle,
    this.videoIsPlaying = true,
    this.sourceFramePath,
    this.sourcePosition = Duration.zero,
  });

  final FocusTimerController controller;
  final String defaultGoal;
  final Duration partRemainingDuration;
  final String bvid;
  final String videoTitle;
  final int partCid;
  final int partPageNumber;
  final String partTitle;
  final bool videoIsPlaying;
  final String? sourceFramePath;
  final Duration sourcePosition;

  /// 创建保存目标输入和时长选择的面板状态。
  @override
  State<PlayerFocusSheet> createState() => _PlayerFocusSheetState();
}

/// 管理播放器专注面板中的表单、确认和控制器操作。
class _PlayerFocusSheetState extends State<PlayerFocusSheet> {
  late final TextEditingController _goalController;
  _PlayerFocusDurationChoice _choice =
      _PlayerFocusDurationChoice.twentyFiveMinutes;
  int _customMinutes = 25;

  /// 初始化默认目标，并监听输入变化以更新开始按钮。
  @override
  void initState() {
    super.initState();
    _goalController = TextEditingController(text: widget.defaultGoal);
    _goalController.addListener(_handleGoalChanged);
  }

  /// 目标文字变化时刷新面板，不提前创建专注记录。
  void _handleGoalChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 返回当前选择对应的实际计划时长。
  Duration _selectedDuration() {
    return switch (_choice) {
      _PlayerFocusDurationChoice.twentyFiveMinutes => const Duration(
        minutes: 25,
      ),
      _PlayerFocusDurationChoice.fortyFiveMinutes => const Duration(
        minutes: 45,
      ),
      _PlayerFocusDurationChoice.part => widget.partRemainingDuration,
      _PlayerFocusDurationChoice.custom => Duration(minutes: _customMinutes),
    };
  }

  /// 打开安全的自定义分钟弹窗，并只在确认后切换当前选项。
  Future<void> _selectCustomDuration() async {
    final int? minutes = await showCustomFocusDurationDialog(
      context,
      initialMinutes: _customMinutes,
    );
    if (minutes != null && mounted) {
      setState(() {
        _customMinutes = minutes;
        _choice = _PlayerFocusDurationChoice.custom;
      });
    }
  }

  /// 从播放器创建带视频和分P来源的新专注记录。
  Future<void> _startFocus() async {
    final bool started = await widget.controller.startFocus(
      goal: _goalController.text,
      duration: _selectedDuration(),
      sourceBvid: widget.bvid,
      sourceVideoTitle: widget.videoTitle,
      sourcePartCid: widget.partCid,
      sourcePartPageNumber: widget.partPageNumber,
      sourcePartTitle: widget.partTitle,
      sourceFramePath: widget.sourceFramePath,
      sourcePosition: widget.sourcePosition,
      startImmediately: widget.videoIsPlaying,
    );
    if (!mounted) {
      return;
    }
    if (!started) {
      _showMessage('请填写目标；当前分P剩余时间需在 1 到 180 分钟内。');
      return;
    }
    FocusScope.of(context).unfocus();
  }

  /// 给当前专注延长五分钟，并在达到三小时上限时显示提示。
  Future<void> _extendFiveMinutes() async {
    final bool extended = await widget.controller.extendFocus(
      const Duration(minutes: 5),
    );
    if (mounted && !extended) {
      _showMessage('计划总时长最多为 180 分钟。');
    }
  }

  /// 提前结束前要求用户确认，避免在播放器中误触。
  Future<void> _confirmEndFocus() async {
    final String? reason = await showFocusTerminationReasonDialog(context);
    if (reason != null) {
      await widget.controller.endFocusEarly(reason: reason);
    }
  }

  /// 手动暂停时先鼓励继续，坚持暂停才追加一条打断记录。
  Future<void> _pauseWithEncouragement() async {
    await showFocusInterruptionFlow(
      context,
      controller: widget.controller,
      kind: FocusInterruptionKind.manualPause,
    );
  }

  /// 在当前底部面板上方显示一次短操作提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 将倒计时格式化为分秒或时分秒。
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

  /// 将当前分P剩余时长转换为选择按钮使用的分钟提示。
  String _formatPartDuration() {
    final int minutes = (widget.partRemainingDuration.inSeconds / 60)
        .ceil()
        .clamp(1, 180);
    return '当前分P（约 $minutes 分）';
  }

  /// 创建没有活动专注时的目标和时长选择表单。
  Widget _buildReadyContent() {
    final bool canStart =
        widget.controller.isReady && _goalController.text.trim().isNotEmpty;
    return Column(
      key: const Key('player-focus-ready'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: const Key('player-focus-goal'),
          controller: _goalController,
          maxLength: FocusTimerController.maximumGoalCharacters,
          decoration: const InputDecoration(
            labelText: '本次专注目标',
            prefixIcon: Icon(Icons.flag_outlined),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ChoiceChip(
              key: const Key('player-focus-25'),
              label: const Text('25 分钟'),
              selected: _choice == _PlayerFocusDurationChoice.twentyFiveMinutes,
              // 25 分钟选择函数只更新开始前的计划时长。
              onSelected: (_) => setState(
                () => _choice = _PlayerFocusDurationChoice.twentyFiveMinutes,
              ),
            ),
            ChoiceChip(
              key: const Key('player-focus-custom'),
              label: Text(
                _choice == _PlayerFocusDurationChoice.custom
                    ? '$_customMinutes 分钟'
                    : '自定义',
              ),
              selected: _choice == _PlayerFocusDurationChoice.custom,
              // 自定义选择函数打开可输入 1 到 180 分钟的安全弹窗。
              onSelected: (_) => unawaited(_selectCustomDuration()),
            ),
            ChoiceChip(
              key: const Key('player-focus-45'),
              label: const Text('45 分钟'),
              selected: _choice == _PlayerFocusDurationChoice.fortyFiveMinutes,
              // 45 分钟选择函数只更新开始前的计划时长。
              onSelected: (_) => setState(
                () => _choice = _PlayerFocusDurationChoice.fortyFiveMinutes,
              ),
            ),
            ChoiceChip(
              key: const Key('player-focus-current-part'),
              label: Text(_formatPartDuration()),
              selected: _choice == _PlayerFocusDurationChoice.part,
              // 当前分P选择函数使用画面真实剩余时长作为专注计划。
              onSelected: (_) =>
                  setState(() => _choice = _PlayerFocusDurationChoice.part),
            ),
          ],
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const Key('start-player-focus'),
          // 开始函数把目标、时长和当前视频来源一起保存。
          onPressed: canStart ? () => unawaited(_startFocus()) : null,
          icon: const Icon(Icons.timer_rounded),
          label: const Text('开始专注'),
        ),
      ],
    );
  }

  /// 创建活动专注的倒计时、暂停继续、续时和结束控制区。
  Widget _buildActiveContent(FocusSession session) {
    final bool paused = session.status == FocusSessionStatus.paused;
    return Column(
      key: const Key('player-focus-active'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          session.goal,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Text(
          _formatCountdown(widget.controller.remainingDuration),
          key: const Key('player-focus-countdown'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: widget.controller.progress,
          minHeight: 7,
          borderRadius: BorderRadius.circular(999),
        ),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: Key(paused ? 'resume-player-focus' : 'pause-player-focus'),
              // 暂停继续函数根据当前状态调用唯一合法的控制器操作。
              onPressed: () => unawaited(
                paused
                    ? widget.controller.resumeFocus()
                    : _pauseWithEncouragement(),
              ),
              icon: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              ),
              label: Text(paused ? '继续' : '暂停'),
            ),
            OutlinedButton.icon(
              key: const Key('extend-player-focus'),
              // 续时函数在不超过三小时上限时增加五分钟。
              onPressed: () => unawaited(_extendFiveMinutes()),
              icon: const Icon(Icons.more_time_rounded),
              label: const Text('+5 分钟'),
            ),
            TextButton.icon(
              key: const Key('end-player-focus'),
              // 结束函数先显示确认弹窗，再归档实际专注时间。
              onPressed: () => unawaited(_confirmEndFocus()),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('结束'),
            ),
          ],
        ),
      ],
    );
  }

  /// 创建随控制器状态实时切换的播放器专注底部面板。
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) {
            final FocusSession? active = widget.controller.activeSession;
            return Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        '播放器专注',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      // 关闭面板函数仅返回播放器，不改变计时状态。
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                Text(
                  '${widget.videoTitle} · P${widget.partPageNumber} ${widget.partTitle}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 18),
                if (active == null)
                  _buildReadyContent()
                else
                  _buildActiveContent(active),
                const Spacer(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 释放目标输入控制器和文字监听。
  @override
  void dispose() {
    _goalController
      ..removeListener(_handleGoalChanged)
      ..dispose();
    super.dispose();
  }
}
