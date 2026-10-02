part of 'player_page.dart';

/// 区分关闭定时、按分钟倒计时和按完整播放次数暂停三种选择。
enum _SleepTimerChoiceKind { off, durationMinutes, playCount }

/// 保存定时关闭对话框的选择；value 为空表示用户还需要输入自定义数值。
class _SleepTimerChoice {
  /// 创建带明确类型和可选数值的定时关闭选择，避免再用正负数暗示业务含义。
  const _SleepTimerChoice(this.kind, [this.value]);

  final _SleepTimerChoiceKind kind;
  final int? value;
}

/// 在独立状态对象中管理自定义定时输入，确保控制器跟随弹窗动画完整释放。
class _CustomSleepTimerValueDialog extends StatefulWidget {
  /// 创建分钟数或播放次数输入弹窗。
  const _CustomSleepTimerValueDialog({required this.kind});

  final _SleepTimerChoiceKind kind;

  /// 创建持有输入控制器和校验错误的弹窗状态。
  @override
  State<_CustomSleepTimerValueDialog> createState() =>
      _CustomSleepTimerValueDialogState();
}

/// 管理自定义定时输入、范围校验和输入控制器生命周期。
class _CustomSleepTimerValueDialogState
    extends State<_CustomSleepTimerValueDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  /// 判断当前输入的是分钟数而不是播放次数。
  bool get _durationMode =>
      widget.kind == _SleepTimerChoiceKind.durationMinutes;

  /// 返回当前模式允许的最大正整数。
  int get _maximum => _durationMode ? 10080 : 9999;

  /// 释放输入控制器；此时弹窗退场动画已经不再使用它。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 校验输入并返回结果；非法输入只更新范围提示，不关闭弹窗。
  void _submit() {
    final int? value = int.tryParse(_controller.text.trim());
    if (value == null || value < 1 || value > _maximum) {
      setState(() => _errorText = '请输入 1～$_maximum 之间的整数');
      return;
    }
    Navigator.of(context).pop(value);
  }

  /// 创建数字输入框与取消、确定按钮。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_durationMode ? '自定义定时时长' : '自定义播放次数'),
      content: TextField(
        key: Key(
          _durationMode
              ? 'sleep-timer-custom-duration-input'
              : 'sleep-timer-custom-play-count-input',
        ),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: _durationMode ? '分钟数' : '播放次数',
          hintText: _durationMode ? '例如：25' : '例如：3',
          helperText: _durationMode
              ? '可输入 1～10080 分钟（最长 7 天）'
              : '当前这一轮也计入次数，可输入 1～9999 次',
          errorText: _errorText,
        ),
        // 键盘提交函数复用确认按钮的校验，输入无效时不会关闭对话框。
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          // 取消按钮函数关闭输入框并保留原来的定时设置。
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('sleep-timer-custom-confirm'),
          // 确认按钮函数只在输入为允许范围内的正整数时返回结果。
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 每秒刷新定时窗口的显示文字；这个计时器只重绘，不控制播放。
class _SleepTimerStatusPanel extends StatefulWidget {
  /// 接收读取当前倒计时和剩余次数的函数。
  const _SleepTimerStatusPanel({
    required this.timeStatus,
    required this.countStatus,
  });
  final String Function() timeStatus;
  final String Function() countStatus;

  /// 创建只在窗口显示期间存活的重绘计时器。
  @override
  State<_SleepTimerStatusPanel> createState() => _SleepTimerStatusPanelState();
}

class _SleepTimerStatusPanelState extends State<_SleepTimerStatusPanel> {
  late final Timer _refresh;

  /// 定时请求重绘，使暂停期间也能看到剩余秒数递减。
  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// 关闭窗口即释放显示计时器。
  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  /// 在选项顶部始终显示时间与次数状态。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.timeStatus(),
              key: const Key('sleep-timer-remaining-time'),
            ),
            const SizedBox(height: 4),
            Text(
              widget.countStatus(),
              key: const Key('sleep-timer-remaining-count'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 负责定时选择与剩余状态展示；后台截止时间由播放服务拥有。
mixin _PlayerSleepTimerCoordinator
    on State<PlayerPage>, _PlayerPlaybackSession {
  /// 当前页面的定时对象，由退出清理统一取消。
  Timer? get _sleepTimer;
  set _sleepTimer(Timer? value);

  /// 供界面展示剩余时长的截止时间，不重复控制后端计时。
  DateTime? get _sleepTimerDeadline;
  set _sleepTimerDeadline(DateTime? value);

  /// 到期时通过现有播放命令暂停。
  Future<void> _setPlaybackActive(bool shouldPlay);

  /// 读取剩余次数；当前这一轮计入剩余次数。
  int? get _remainingSleepPlayCount => _pauseAfterPlayCount == null
      ? null
      : (_pauseAfterPlayCount! - _completedPlayCount).clamp(0, 9999);

  /// 从截止时间和后端快照中取较短值，暂停时也持续递减显示。
  Duration get _remainingSleepTime {
    final deadline = _sleepTimerDeadline;
    if (deadline == null) return Duration.zero;
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return Duration.zero;
    if (_playbackService is ListeningPlaybackService &&
        _playbackSnapshot.sleepTimerRemaining < remaining) {
      return _playbackSnapshot.sleepTimerRemaining;
    }
    return remaining;
  }

  /// 格式化含秒的倒计时，未启用时明确显示未设置。
  String _sleepTimeStatus() {
    final remaining = _remainingSleepTime;
    if (_sleepTimerDeadline == null) return '剩余时间：未设置';
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final tail =
        '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return seconds == 0
        ? '剩余时间：00:00（已到期）'
        : '剩余时间：${hours > 0 ? '${hours.toString().padLeft(2, '0')}:' : ''}$tail 后暂停';
  }

  /// 显示按次数暂停的实时余量，而不是设置时的总次数。
  String _sleepCountStatus() => _remainingSleepPlayCount == null
      ? '剩余次数：未设置'
      : '剩余次数：$_remainingSleepPlayCount 次后暂停（含当前这一轮）';

  /// 返回当前定时关闭设置的简短菜单文字。
  String get _sleepTimerSummary {
    if (_pauseAfterPlayCount != null) {
      return '定时关闭：剩余 $_remainingSleepPlayCount 次';
    }
    if (_playbackService is ListeningPlaybackService) {
      final remaining = _playbackSnapshot.sleepTimerRemaining;
      return remaining > Duration.zero
          ? '定时关闭：约 ${(remaining.inMilliseconds / 60000).ceil()} 分钟后'
          : '定时关闭';
    }
    final DateTime? deadline = _sleepTimerDeadline;
    if (deadline != null && deadline.isAfter(DateTime.now())) {
      final int minutes = deadline.difference(DateTime.now()).inMinutes + 1;
      return '定时关闭：约 $minutes 分钟后';
    }
    return '定时关闭';
  }

  /// 显示快捷选项与自定义入口；“关闭”统一表示到点后暂停播放器。
  Future<void> _showSleepTimerDialog() async {
    _SleepTimerChoice? selected = await showDialog<_SleepTimerChoice>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('定时关闭（到时暂停）'),
        children: <Widget>[
          _SleepTimerStatusPanel(
            timeStatus: _sleepTimeStatus,
            countStatus: _sleepCountStatus,
          ),
          SimpleDialogOption(
            key: const Key('sleep-timer-off'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(const _SleepTimerChoice(_SleepTimerChoiceKind.off, 0)),
            child: const Text('关闭定时'),
          ),
          for (final int minutes in <int>[15, 30, 60, 90])
            SimpleDialogOption(
              key: Key('sleep-timer-$minutes-minutes'),
              onPressed: () => Navigator.of(dialogContext).pop(
                _SleepTimerChoice(
                  _SleepTimerChoiceKind.durationMinutes,
                  minutes,
                ),
              ),
              child: Text('$minutes 分钟后暂停'),
            ),
          SimpleDialogOption(
            key: const Key('sleep-timer-custom-duration'),
            onPressed: () => Navigator.of(dialogContext).pop(
              const _SleepTimerChoice(_SleepTimerChoiceKind.durationMinutes),
            ),
            child: const Text('自定义时长…'),
          ),
          for (final int count in <int>[1, 2, 3, 5])
            SimpleDialogOption(
              key: Key('sleep-timer-$count-plays'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_SleepTimerChoice(_SleepTimerChoiceKind.playCount, count)),
              child: Text('播放 $count 次后暂停'),
            ),
          SimpleDialogOption(
            key: const Key('sleep-timer-custom-play-count'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(const _SleepTimerChoice(_SleepTimerChoiceKind.playCount)),
            child: const Text('自定义播放次数…'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected.value == null) {
      final int? customValue = await _showCustomSleepTimerValueDialog(
        selected.kind,
      );
      if (!mounted || customValue == null) {
        return;
      }
      selected = _SleepTimerChoice(selected.kind, customValue);
    }
    await _applySleepTimerChoice(selected);
  }

  /// 请求一个正整数的自定义分钟数或播放次数，并在输入非法或过大时留在对话框提示。
  Future<int?> _showCustomSleepTimerValueDialog(
    _SleepTimerChoiceKind kind,
  ) async {
    return showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _CustomSleepTimerValueDialog(kind: kind),
    );
  }

  /// 将已经校验的选择写入播放器状态，并保证时长与次数两种模式互斥。
  Future<void> _applySleepTimerChoice(_SleepTimerChoice selected) async {
    final int value = selected.value ?? 0;
    final service = _playbackService;
    if (service is ListeningPlaybackService) {
      try {
        await (service as ListeningPlaybackService).setSleepTimer(
          selected.kind == _SleepTimerChoiceKind.durationMinutes
              ? Duration(minutes: value)
              : null,
        );
      } catch (_) {
        if (mounted) _showTransientSnackBar('定时设置未成功，请重试');
        return;
      }
      if (!mounted) return;
    }
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (selected.kind == _SleepTimerChoiceKind.off) {
      setState(() {
        _sleepTimerDeadline = null;
        _pauseAfterPlayCount = null;
        _completedPlayCount = 0;
      });
      _showTransientSnackBar('已关闭定时暂停');
      return;
    }
    if (selected.kind == _SleepTimerChoiceKind.playCount) {
      setState(() {
        _sleepTimerDeadline = null;
        _pauseAfterPlayCount = value;
        _completedPlayCount = 0;
        _playbackLoopEnabled = value > 1;
      });
      _showTransientSnackBar('将在播放 $value 次后暂停');
      return;
    }
    final Duration duration = Duration(minutes: value);
    setState(() {
      _sleepTimerDeadline = DateTime.now().add(duration);
      _pauseAfterPlayCount = null;
      _completedPlayCount = 0;
    });
    // 支持后台的后端是唯一时钟，避免返回前台后延迟的页面计时误报或二次暂停。
    if (service is! ListeningPlaybackService) {
      _sleepTimer = Timer(duration, _pauseForSleepTimer);
    }
    _showTransientSnackBar('将在 $value 分钟后暂停');
  }

  /// 倒计时到期后暂停播放器并清除本次定时状态。
  void _pauseForSleepTimer() {
    if (!mounted) {
      return;
    }
    setState(() {
      _sleepTimerDeadline = null;
      _pauseAfterPlayCount = null;
    });
    if (_playbackService is! ListeningPlaybackService) {
      unawaited(_setPlaybackActive(false));
    }
    _showTransientSnackBar('定时关闭时间已到，视频已暂停');
  }
}
