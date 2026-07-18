import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/focus_session.dart';
import '../../models/focus_statistics.dart';
import '../../services/focus_session_service.dart';
import '../../services/focus_notification_service.dart';

/// 定义可替换的当前时间读取函数，测试可以手动推进时间而无需真实等待。
typedef FocusClock = DateTime Function();

/// 管理全应用唯一的专注任务、视频播放联动、打断记录和本机持久化。
class FocusTimerController extends ChangeNotifier with WidgetsBindingObserver {
  /// 创建计时控制器；界面每秒刷新，但真实时长只累计视频实际播放区间。
  FocusTimerController({
    FocusSessionService? service,
    FocusClock? clock,
    Duration tickInterval = const Duration(seconds: 1),
    FocusNotificationService? notificationService,
  }) : _service = service ?? FocusSessionService(),
       _notificationService =
           notificationService ?? const FocusNotificationService(),
       _clock = clock ?? DateTime.now,
       _tickInterval = tickInterval;

  static const int maximumGoalCharacters = 60;
  static const Duration minimumDuration = Duration(minutes: 1);
  static const Duration maximumDuration = Duration(hours: 3);

  final FocusSessionService _service;
  final FocusNotificationService _notificationService;
  final FocusClock _clock;
  final Duration _tickInterval;
  FocusSession? _activeSession;
  FocusSession? _lastFinishedSession;
  List<FocusSession> _history = const <FocusSession>[];
  Timer? _ticker;
  Future<void>? _initialization;
  bool _ready = false;
  bool _finishingExpiredSession = false;
  bool _observingLifecycle = false;
  bool _backgroundInterruptionRecorded = false;
  String? _playingBvid;
  int? _playingPartCid;
  bool _videoPlaying = false;

  /// 表示本机状态是否已经读取完成。
  bool get isReady => _ready;

  /// 返回当前仍可继续、关联或终止的专注任务。
  FocusSession? get activeSession => _activeSession;

  /// 返回当前进程最近结束的记录，供全局完成弹窗和首页反馈使用。
  FocusSession? get lastFinishedSession => _lastFinishedSession;

  /// 返回不可修改的历史记录列表，最新记录排在最前。
  List<FocusSession> get history => List<FocusSession>.unmodifiable(_history);

  /// 判断当前是否存在活动专注任务。
  bool get hasActiveSession => _activeSession?.isActive == true;

  /// 使用当前绝对时间计算活动记录的剩余时长。
  Duration get remainingDuration =>
      _activeSession?.remainingAt(_clock()) ?? Duration.zero;

  /// 使用当前绝对时间计算活动记录已经真实专注的时长。
  Duration get elapsedDuration =>
      _activeSession?.elapsedAt(_clock()) ?? Duration.zero;

  /// 返回当前活动记录的完成比例，没有活动记录时为零。
  double get progress => _activeSession?.progressAt(_clock()) ?? 0;

  /// 读取本机专注状态并恢复计时；重复调用会复用同一个任务。
  Future<void> initialize() {
    return _initialization ??= _loadInitialState();
  }

  /// 加载本机记录，并确保没有正在播放的视频时计时保持暂停。
  Future<void> _loadInitialState() async {
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    final FocusStoredState storedState = await _service.loadState();
    _activeSession = storedState.activeSession;
    _history = storedState.history;
    _ready = true;
    final FocusSession? active = _activeSession;
    if (active?.status == FocusSessionStatus.running) {
      final DateTime now = _clock();
      final FocusSession safelyPaused = active!.pauseAt(
        active.currentRunStartedAt ?? now,
        reason: FocusPauseReason.interruption,
      );
      _activeSession = safelyPaused.addInterruption(
        now,
        interruption: FocusInterruption(
          id: '${active.id}-${now.microsecondsSinceEpoch}',
          occurredAt: now,
          kind: FocusInterruptionKind.appBackground,
          reason: '专注被打断',
        ),
      );
      await _persist();
    }
    _syncTicker();
    notifyListeners();
  }

  /// 创建新专注；首页任务默认等待视频，播放器任务只有画面正在播放时才立即计时。
  Future<bool> startFocus({
    required String goal,
    required Duration duration,
    bool startImmediately = true,
    String? sourceBvid,
    String? sourceVideoTitle,
    int? sourcePartCid,
    int? sourcePartPageNumber,
    String? sourcePartTitle,
    String? sourceFramePath,
    Duration sourcePosition = Duration.zero,
  }) async {
    if (!_ready || hasActiveSession) {
      return false;
    }
    final String normalizedGoal = _limitGoal(goal.trim());
    if (normalizedGoal.isEmpty ||
        duration < minimumDuration ||
        duration > maximumDuration) {
      return false;
    }
    final DateTime now = _clock();
    final bool hasSource =
        sourceBvid?.trim().isNotEmpty == true && sourcePartCid != null;
    _activeSession = FocusSession.start(
      id: '${now.microsecondsSinceEpoch}',
      goal: normalizedGoal,
      plannedDuration: duration,
      now: now,
      startImmediately: startImmediately && hasSource,
      sourceBvid: sourceBvid,
      sourceVideoTitle: sourceVideoTitle,
      sourcePartCid: sourcePartCid,
      sourcePartPageNumber: sourcePartPageNumber,
      sourcePartTitle: sourcePartTitle,
      sourceFramePath: sourceFramePath,
      sourcePosition: sourcePosition,
    );
    _lastFinishedSession = null;
    _syncTicker();
    notifyListeners();
    await _persist();
    return true;
  }

  /// 手动暂停专注并按默认原因记为一次打断；界面可使用 interruptFocus 提供详细原因。
  Future<void> pauseFocus() {
    return interruptFocus(
      kind: FocusInterruptionKind.manualPause,
      reason: '未填写原因',
    );
  }

  /// 记录一次用户或系统打断，任务保持活动状态且不会计入提前结束次数。
  Future<void> interruptFocus({
    required FocusInterruptionKind kind,
    required String reason,
    DateTime? reminderAt,
  }) async {
    final FocusSession? session = _activeSession;
    if (session == null || !session.isActive) {
      return;
    }
    final DateTime now = _clock();
    final String normalizedReason = reason.trim().isEmpty
        ? '未填写原因'
        : reason.trim();
    _activeSession = session.addInterruption(
      now,
      interruption: FocusInterruption(
        id: '${session.id}-${now.microsecondsSinceEpoch}',
        occurredAt: now,
        kind: kind,
        reason: normalizedReason,
        reminderAt: reminderAt,
      ),
    );
    _syncTicker();
    notifyListeners();
    await _persist();
  }

  /// 用户选择继续后，仅在关联视频分P正在播放时恢复计时。
  Future<void> resumeFocus() async {
    final FocusSession? session = _activeSession;
    if (session == null || session.status != FocusSessionStatus.paused) {
      return;
    }
    if (!_matchesCurrentPlayingVideo(session)) {
      _activeSession = session.pauseAt(
        _clock(),
        reason: session.hasVideoAssociation
            ? FocusPauseReason.playback
            : FocusPauseReason.awaitingVideo,
      );
      notifyListeners();
      await _persist();
      return;
    }
    _activeSession = session.resumeAt(_clock());
    _syncTicker();
    notifyListeners();
    await _persist();
    if (_activeSession?.status == FocusSessionStatus.running) {
      unawaited(_notificationService.cancelReminder(session.id));
    }
  }

  /// 接收播放器真实状态；匹配分P播放时恢复，暂停或切走时停止累计。
  Future<void> updatePlaybackState({
    required String bvid,
    required int partCid,
    required bool isPlaying,
  }) async {
    _playingBvid = bvid;
    _playingPartCid = partCid;
    _videoPlaying = isPlaying;
    final FocusSession? session = _activeSession;
    if (session == null || !session.hasVideoAssociation) {
      return;
    }
    final bool matches =
        session.sourceBvid == bvid && session.sourcePartCid == partCid;
    if (session.status == FocusSessionStatus.running &&
        (!matches || !isPlaying)) {
      _activeSession = session.pauseAt(
        _clock(),
        reason: FocusPauseReason.playback,
      );
    } else if (session.status == FocusSessionStatus.paused &&
        session.pauseReason == FocusPauseReason.playback &&
        matches &&
        isPlaying) {
      _activeSession = session.resumeAt(_clock());
    } else {
      return;
    }
    _syncTicker();
    notifyListeners();
    await _persist();
    if (_activeSession?.status == FocusSessionStatus.running) {
      unawaited(_notificationService.cancelReminder(session.id));
    }
  }

  /// 把活动任务关联到用户刚确认的视频分P，并按真实播放状态决定是否计时。
  Future<void> associateVideo({
    required String bvid,
    required String videoTitle,
    required int partCid,
    required int partPageNumber,
    required String partTitle,
    required bool isPlaying,
    String? framePath,
    Duration position = Duration.zero,
  }) async {
    final FocusSession? session = _activeSession;
    if (session == null || !session.isActive) {
      return;
    }
    _playingBvid = bvid;
    _playingPartCid = partCid;
    _videoPlaying = isPlaying;
    _activeSession = session.associateVideo(
      now: _clock(),
      bvid: bvid,
      videoTitle: videoTitle,
      partCid: partCid,
      partPageNumber: partPageNumber,
      partTitle: partTitle,
      isPlaying: isPlaying,
      framePath: framePath,
      position: position,
    );
    _syncTicker();
    notifyListeners();
    await _persist();
    if (_activeSession?.status == FocusSessionStatus.running) {
      unawaited(_notificationService.cancelReminder(session.id));
    }
  }

  /// 更新活动任务 Pin 中的最后视频画面和播放位置。
  Future<void> updateLastSeen({
    required String? framePath,
    required Duration position,
  }) async {
    final FocusSession? session = _activeSession;
    if (session == null || !session.hasVideoAssociation) {
      return;
    }
    _activeSession = session.updateLastSeen(
      framePath: framePath,
      position: position,
    );
    notifyListeners();
    await _persist();
  }

  /// 更新刚结束记录的最后画面和时间点，确保完成记录仍能从真实进度继续播放。
  Future<void> updateFinishedLastSeen({
    required String sessionId,
    required String? framePath,
    required Duration position,
  }) async {
    final int index = _history.indexWhere(
      (FocusSession session) => session.id == sessionId,
    );
    if (index < 0) {
      return;
    }
    final FocusSession updated = _history[index].updateLastSeen(
      framePath: framePath,
      position: position,
    );
    if (identical(updated, _history[index])) {
      return;
    }
    final List<FocusSession> nextHistory = List<FocusSession>.of(_history);
    nextHistory[index] = updated;
    _history = List<FocusSession>.unmodifiable(nextHistory);
    if (_lastFinishedSession?.id == sessionId) {
      _lastFinishedSession = updated;
    }
    notifyListeners();
    await _persist();
  }

  /// 给当前活动专注增加时长；总计划超过三小时或没有活动记录时返回 false。
  Future<bool> extendFocus(Duration extension) async {
    final FocusSession? session = _activeSession;
    if (session == null ||
        !session.isActive ||
        extension <= Duration.zero ||
        session.plannedDuration + extension > maximumDuration) {
      return false;
    }
    _activeSession = session.extendBy(extension);
    _syncTicker();
    notifyListeners();
    await _persist();
    return true;
  }

  /// 将刚正常完成的任务重新打开并增加时长，历史中的完成记录会被移回活动状态。
  Future<bool> extendCompletedFocus(Duration extension) async {
    final FocusSession? finished = _lastFinishedSession;
    if (finished == null ||
        finished.status != FocusSessionStatus.completed ||
        extension <= Duration.zero ||
        finished.plannedDuration + extension > maximumDuration) {
      return false;
    }
    _history = _history
        .where((FocusSession item) => item.id != finished.id)
        .toList(growable: false);
    _activeSession = finished.reopenAt(_clock(), extension);
    _lastFinishedSession = null;
    _syncTicker();
    notifyListeners();
    await _persist();
    return true;
  }

  /// 主动终止当前任务并保存终止原因；只有此操作计入提前结束次数。
  Future<void> endFocusEarly({String? reason}) async {
    final FocusSession? session = _activeSession;
    if (session == null || !session.isActive) {
      return;
    }
    _finalizeSession(
      session.finishAt(
        _clock(),
        finalStatus: FocusSessionStatus.endedEarly,
        terminationReason: reason ?? '未填写原因',
      ),
    );
    await _persist();
    unawaited(_notificationService.cancelReminder(session.id));
  }

  /// 清除首页最近完成提示，不删除历史记录。
  void dismissLastFinishedSession() {
    if (_lastFinishedSession == null) {
      return;
    }
    _lastFinishedSession = null;
    notifyListeners();
  }

  /// 删除指定编号的单条历史记录，不影响活动任务。
  Future<void> deleteHistoryEntry(String id) async {
    final List<FocusSession> nextHistory = _history
        .where((FocusSession session) => session.id != id)
        .toList(growable: false);
    if (nextHistory.length == _history.length) {
      return;
    }
    _history = nextHistory;
    if (_lastFinishedSession?.id == id) {
      _lastFinishedSession = null;
    }
    notifyListeners();
    await _persist();
    unawaited(_notificationService.cancelReminder(id));
  }

  /// 清空所有已结束历史记录，但保留当前活动任务。
  Future<void> clearHistory() async {
    if (_history.isEmpty && _lastFinishedSession == null) {
      return;
    }
    final List<String> removedIds = _history
        .map((FocusSession session) => session.id)
        .toList(growable: false);
    _history = const <FocusSession>[];
    _lastFinishedSession = null;
    notifyListeners();
    await _persist();
    for (final String id in removedIds) {
      unawaited(_notificationService.cancelReminder(id));
    }
  }

  /// 统计今天已经真实投入的专注时长，并包含当前活动任务。
  Duration todayFocusedDuration() {
    final DateTime now = _clock();
    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: _history,
      range: FocusStatisticsRange.sevenDays,
      now: now,
      activeSession: _activeSession,
    );
    return snapshot.dailyTrend.isEmpty
        ? Duration.zero
        : snapshot.dailyTrend.last.focusedDuration;
  }

  /// 统计今天按计划正常完成的专注次数。
  int todayCompletedCount() {
    final DateTime now = _clock();
    return _history
        .where(
          (FocusSession session) =>
              session.status == FocusSessionStatus.completed &&
              _isSameLocalDay(session.finishedAt, now),
        )
        .length;
  }

  /// 应用退到后台时记录一次意外打断，回前台后等待用户主动继续。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ready) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _backgroundInterruptionRecorded = false;
      _tick();
      return;
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) &&
        !_backgroundInterruptionRecorded &&
        _activeSession?.status == FocusSessionStatus.running) {
      _backgroundInterruptionRecorded = true;
      unawaited(
        interruptFocus(
          kind: FocusInterruptionKind.appBackground,
          reason: '专注被打断',
        ),
      );
      return;
    }
    if (state == AppLifecycleState.inactive) {
      unawaited(_persist());
    }
  }

  /// 每次刷新都从绝对时间重新计算；到时后只触发一次完成归档。
  void _tick() {
    final FocusSession? session = _activeSession;
    if (session == null || session.status != FocusSessionStatus.running) {
      _syncTicker();
      return;
    }
    if (session.remainingAt(_clock()) <= Duration.zero) {
      unawaited(_completeExpiredSession());
      return;
    }
    notifyListeners();
  }

  /// 把到时任务标记为正常完成，并防止相邻计时回调重复归档。
  Future<void> _completeExpiredSession() async {
    if (_finishingExpiredSession) {
      return;
    }
    final FocusSession? session = _activeSession;
    if (session == null || session.status != FocusSessionStatus.running) {
      return;
    }
    _finishingExpiredSession = true;
    _finalizeSession(
      session.finishAt(_clock(), finalStatus: FocusSessionStatus.completed),
    );
    await _persist();
    unawaited(_notificationService.cancelReminder(session.id));
    _finishingExpiredSession = false;
  }

  /// 统一把结束记录放入历史首位、停止计时器并通知所有页面刷新。
  void _finalizeSession(FocusSession finishedSession) {
    _activeSession = null;
    _lastFinishedSession = finishedSession;
    _history = <FocusSession>[
      finishedSession,
      ..._history.where((FocusSession item) => item.id != finishedSession.id),
    ].take(FocusSessionService.maximumHistoryEntries).toList(growable: false);
    _syncTicker();
    notifyListeners();
  }

  /// 判断活动任务是否正对应当前正在播放的视频分P。
  bool _matchesCurrentPlayingVideo(FocusSession session) {
    return _videoPlaying &&
        session.sourceBvid == _playingBvid &&
        session.sourcePartCid == _playingPartCid;
  }

  /// 只在任务真实运行时保留一个周期刷新器。
  void _syncTicker() {
    final bool shouldRun =
        _ready && _activeSession?.status == FocusSessionStatus.running;
    if (!shouldRun) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(_tickInterval, (_) => _tick());
  }

  /// 把当前活动任务和历史列表保存到设备。
  Future<void> _persist() {
    return _service.saveState(activeSession: _activeSession, history: _history);
  }

  /// 截取目标的前 60 个 Unicode 码点，避免切断代理对。
  String _limitGoal(String goal) {
    return String.fromCharCodes(goal.runes.take(maximumGoalCharacters));
  }

  /// 判断可空时间是否与参照时间处于同一个本地自然日。
  bool _isSameLocalDay(DateTime? value, DateTime reference) {
    if (value == null) {
      return false;
    }
    final DateTime localValue = value.toLocal();
    final DateTime localReference = reference.toLocal();
    return localValue.year == localReference.year &&
        localValue.month == localReference.month &&
        localValue.day == localReference.day;
  }

  /// 取消计时器和生命周期监听，应用销毁后不再触发刷新。
  @override
  void dispose() {
    _ticker?.cancel();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    super.dispose();
  }
}
