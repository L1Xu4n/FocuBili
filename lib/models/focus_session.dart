/// 标识一次专注正在计时、暂停、正常完成，还是被用户主动终止。
enum FocusSessionStatus { running, paused, completed, endedEarly }

/// 标识暂停是等待视频、视频暂停、用户手动暂停，还是应用被打断造成的。
enum FocusPauseReason { awaitingVideo, playback, manual, interruption }

/// 标识一次打断来自手动暂停、退出播放器或应用进入后台。
enum FocusInterruptionKind { manualPause, playerExit, appBackground }

/// 保存一次专注打断的原因、时间和可选继续提醒。
class FocusInterruption {
  /// 创建一条不可变的本机打断记录。
  const FocusInterruption({
    required this.id,
    required this.occurredAt,
    required this.kind,
    required this.reason,
    this.reminderAt,
  });

  final String id;
  final DateTime occurredAt;
  final FocusInterruptionKind kind;
  final String reason;
  final DateTime? reminderAt;

  /// 把打断记录转换为可写入专注 JSON 的字典。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      'kind': kind.name,
      'reason': reason,
      'reminderAt': reminderAt?.toUtc().toIso8601String(),
    };
  }

  /// 安全解析一条打断记录，字段损坏时返回空值而不阻止应用启动。
  static FocusInterruption? tryParse(Map<String, dynamic> json) {
    final Object? idValue = json['id'];
    final Object? occurredAtValue = json['occurredAt'];
    final Object? kindValue = json['kind'];
    final Object? reasonValue = json['reason'];
    final Object? reminderAtValue = json['reminderAt'];
    if (idValue is! String ||
        occurredAtValue is! String ||
        kindValue is! String ||
        reasonValue is! String) {
      return null;
    }
    final DateTime? occurredAt = DateTime.tryParse(occurredAtValue);
    final DateTime? reminderAt = reminderAtValue is String
        ? DateTime.tryParse(reminderAtValue)
        : null;
    final FocusInterruptionKind? kind = FocusInterruptionKind.values
        .where((FocusInterruptionKind item) => item.name == kindValue)
        .firstOrNull;
    final String reason = reasonValue.trim();
    if (idValue.trim().isEmpty ||
        occurredAt == null ||
        kind == null ||
        reason.isEmpty) {
      return null;
    }
    return FocusInterruption(
      id: idValue.trim(),
      occurredAt: occurredAt.toLocal(),
      kind: kind,
      reason: reason,
      reminderAt: reminderAt?.toLocal(),
    );
  }
}

/// 保存一次仅存在本机的专注任务、视频关联和打断记录。
class FocusSession {
  /// 创建一条专注记录；运行状态必须提供当前计时片段的开始时间。
  const FocusSession({
    required this.id,
    required this.goal,
    required this.plannedDuration,
    required this.startedAt,
    required this.accumulatedFocusDuration,
    required this.status,
    this.currentRunStartedAt,
    this.finishedAt,
    this.pauseReason,
    this.sourceBvid,
    this.sourceVideoTitle,
    this.sourcePartCid,
    this.sourcePartPageNumber,
    this.sourcePartTitle,
    this.sourceFramePath,
    this.sourcePosition = Duration.zero,
    this.interruptions = const <FocusInterruption>[],
    this.terminationReason,
    this.dailyFocusMilliseconds = const <String, int>{},
  });

  /// 创建一条新专注；未关联视频或视频未播放时从暂停状态开始。
  factory FocusSession.start({
    required String id,
    required String goal,
    required Duration plannedDuration,
    required DateTime now,
    bool startImmediately = true,
    String? sourceBvid,
    String? sourceVideoTitle,
    int? sourcePartCid,
    int? sourcePartPageNumber,
    String? sourcePartTitle,
    String? sourceFramePath,
    Duration sourcePosition = Duration.zero,
  }) {
    return FocusSession(
      id: id,
      goal: goal,
      plannedDuration: plannedDuration,
      startedAt: now,
      accumulatedFocusDuration: Duration.zero,
      currentRunStartedAt: startImmediately ? now : null,
      status: startImmediately
          ? FocusSessionStatus.running
          : FocusSessionStatus.paused,
      pauseReason: startImmediately
          ? null
          : sourceBvid == null
          ? FocusPauseReason.awaitingVideo
          : FocusPauseReason.playback,
      sourceBvid: sourceBvid,
      sourceVideoTitle: sourceVideoTitle,
      sourcePartCid: sourcePartCid,
      sourcePartPageNumber: sourcePartPageNumber,
      sourcePartTitle: sourcePartTitle,
      sourceFramePath: sourceFramePath,
      sourcePosition: sourcePosition,
    );
  }

  final String id;
  final String goal;
  final Duration plannedDuration;
  final DateTime startedAt;
  final Duration accumulatedFocusDuration;
  final DateTime? currentRunStartedAt;
  final FocusSessionStatus status;
  final DateTime? finishedAt;
  final FocusPauseReason? pauseReason;
  final String? sourceBvid;
  final String? sourceVideoTitle;
  final int? sourcePartCid;
  final int? sourcePartPageNumber;
  final String? sourcePartTitle;
  final String? sourceFramePath;
  final Duration sourcePosition;
  final List<FocusInterruption> interruptions;
  final String? terminationReason;

  /// 按设备本地自然日保存已结算的播放专注毫秒数，键格式为 YYYY-MM-DD。
  final Map<String, int> dailyFocusMilliseconds;

  /// 判断这条记录是否仍可继续、暂停、关联视频或主动终止。
  bool get isActive =>
      status == FocusSessionStatus.running ||
      status == FocusSessionStatus.paused;

  /// 判断当前任务是否已经关联到一个具体视频分P。
  bool get hasVideoAssociation =>
      sourceBvid?.isNotEmpty == true && sourcePartCid != null;

  /// 判断记录是否至少保存了 BV 号，可用于兼容缺少旧分P字段的历史记录。
  bool get hasBrowsableVideo => sourceBvid?.isNotEmpty == true;

  /// 返回最近一次打断原因，首页 Pin 没有打断时返回空值。
  String? get latestInterruptionReason =>
      interruptions.isEmpty ? null : interruptions.last.reason;

  /// 使用绝对时间计算真实专注时长，暂停和后台期间不会继续增加。
  Duration elapsedAt(DateTime now) {
    int elapsedMilliseconds = accumulatedFocusDuration.inMilliseconds;
    if (status == FocusSessionStatus.running && currentRunStartedAt != null) {
      elapsedMilliseconds += now
          .difference(currentRunStartedAt!)
          .inMilliseconds
          .clamp(0, plannedDuration.inMilliseconds);
    }
    return Duration(
      milliseconds: elapsedMilliseconds.clamp(
        0,
        plannedDuration.inMilliseconds,
      ),
    );
  }

  /// 返回指定时刻距离计划结束还剩多久，结果永远不会小于零。
  Duration remainingAt(DateTime now) {
    final int remainingMilliseconds =
        plannedDuration.inMilliseconds - elapsedAt(now).inMilliseconds;
    return Duration(milliseconds: remainingMilliseconds.clamp(0, 1 << 31));
  }

  /// 返回 0 到 1 之间的完成比例，供进度条、鼓励提示和统计使用。
  double progressAt(DateTime now) {
    if (plannedDuration <= Duration.zero) {
      return 0;
    }
    return (elapsedAt(now).inMilliseconds / plannedDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  /// 在指定时刻暂停计时，并记录本次暂停的业务原因。
  FocusSession pauseAt(
    DateTime now, {
    FocusPauseReason reason = FocusPauseReason.manual,
  }) {
    if (status != FocusSessionStatus.running) {
      if (status == FocusSessionStatus.paused && pauseReason != reason) {
        return _copy(pauseReason: reason, replacePauseReason: true);
      }
      return this;
    }
    final Duration elapsed = elapsedAt(now);
    return _copy(
      accumulatedFocusDuration: elapsed,
      dailyFocusMilliseconds: _recordCurrentRunUntil(now),
      status: FocusSessionStatus.paused,
      clearRunStartedAt: true,
      pauseReason: reason,
      replacePauseReason: true,
    );
  }

  /// 从暂停状态继续计时，并建立新的绝对时间片段起点。
  FocusSession resumeAt(DateTime now) {
    if (status != FocusSessionStatus.paused) {
      return this;
    }
    return _copy(
      currentRunStartedAt: now,
      status: FocusSessionStatus.running,
      clearPauseReason: true,
    );
  }

  /// 在活动记录的计划时长上增加一段时间，暂停状态也可以续时。
  FocusSession extendBy(Duration extension) {
    if (!isActive || extension <= Duration.zero) {
      return this;
    }
    return _copy(plannedDuration: plannedDuration + extension);
  }

  /// 把任务关联到用户确认的当前视频分P，并保存上次看到的画面与进度。
  FocusSession associateVideo({
    required DateTime now,
    required String bvid,
    required String videoTitle,
    required int partCid,
    required int partPageNumber,
    required String partTitle,
    required bool isPlaying,
    String? framePath,
    Duration position = Duration.zero,
  }) {
    if (!isActive) {
      return this;
    }
    final FocusSession paused = status == FocusSessionStatus.running
        ? pauseAt(now, reason: FocusPauseReason.playback)
        : _copy(
            pauseReason: FocusPauseReason.playback,
            replacePauseReason: true,
          );
    final FocusSession associated = paused._copy(
      sourceBvid: bvid,
      sourceVideoTitle: videoTitle,
      sourcePartCid: partCid,
      sourcePartPageNumber: partPageNumber,
      sourcePartTitle: partTitle,
      sourceFramePath: framePath,
      sourcePosition: position,
    );
    return isPlaying ? associated.resumeAt(now) : associated;
  }

  /// 更新首页 Pin 使用的最后视频画面和播放位置，不改变关联对象。
  FocusSession updateLastSeen({
    required String? framePath,
    required Duration position,
  }) {
    if (!hasVideoAssociation) {
      return this;
    }
    return _copy(
      sourceFramePath: framePath ?? sourceFramePath,
      sourcePosition: position,
    );
  }

  /// 追加一次打断记录，并把活动计时停在当前真实时长。
  FocusSession addInterruption(
    DateTime now, {
    required FocusInterruption interruption,
  }) {
    if (!isActive) {
      return this;
    }
    final FocusSession paused = pauseAt(
      now,
      reason: FocusPauseReason.interruption,
    );
    final List<FocusInterruption> updated = <FocusInterruption>[
      ...interruptions,
      interruption,
    ];
    return paused._copy(
      interruptions: updated.length <= 100
          ? List<FocusInterruption>.unmodifiable(updated)
          : List<FocusInterruption>.unmodifiable(
              updated.sublist(updated.length - 100),
            ),
    );
  }

  /// 在指定时刻结束记录，并保存正常完成或主动终止的最终状态和原因。
  FocusSession finishAt(
    DateTime now, {
    required FocusSessionStatus finalStatus,
    String? terminationReason,
  }) {
    assert(
      finalStatus == FocusSessionStatus.completed ||
          finalStatus == FocusSessionStatus.endedEarly,
    );
    final Duration finalElapsed = finalStatus == FocusSessionStatus.completed
        ? plannedDuration
        : elapsedAt(now);
    return _copy(
      accumulatedFocusDuration: finalElapsed,
      dailyFocusMilliseconds: status == FocusSessionStatus.running
          ? _recordCurrentRunUntil(now)
          : dailyFocusMilliseconds,
      status: finalStatus,
      finishedAt: now,
      clearRunStartedAt: true,
      clearPauseReason: true,
      terminationReason: terminationReason?.trim().isEmpty == true
          ? '未填写原因'
          : terminationReason?.trim(),
    );
  }

  /// 把刚完成的任务重新打开并增加时长，等待关联视频再次播放。
  FocusSession reopenAt(DateTime now, Duration extension) {
    if (status != FocusSessionStatus.completed || extension <= Duration.zero) {
      return this;
    }
    return _copy(
      plannedDuration: plannedDuration + extension,
      accumulatedFocusDuration: plannedDuration,
      status: FocusSessionStatus.paused,
      clearFinishedAt: true,
      pauseReason: hasVideoAssociation
          ? FocusPauseReason.playback
          : FocusPauseReason.awaitingVideo,
      replacePauseReason: true,
      clearTerminationReason: true,
    );
  }

  /// 生成替换指定字段的新记录，集中保证所有扩展字段不会在状态切换时丢失。
  FocusSession _copy({
    Duration? plannedDuration,
    Duration? accumulatedFocusDuration,
    DateTime? currentRunStartedAt,
    FocusSessionStatus? status,
    DateTime? finishedAt,
    FocusPauseReason? pauseReason,
    String? sourceBvid,
    String? sourceVideoTitle,
    int? sourcePartCid,
    int? sourcePartPageNumber,
    String? sourcePartTitle,
    String? sourceFramePath,
    Duration? sourcePosition,
    List<FocusInterruption>? interruptions,
    String? terminationReason,
    Map<String, int>? dailyFocusMilliseconds,
    bool clearRunStartedAt = false,
    bool clearFinishedAt = false,
    bool clearPauseReason = false,
    bool replacePauseReason = false,
    bool clearTerminationReason = false,
  }) {
    return FocusSession(
      id: id,
      goal: goal,
      plannedDuration: plannedDuration ?? this.plannedDuration,
      startedAt: startedAt,
      accumulatedFocusDuration:
          accumulatedFocusDuration ?? this.accumulatedFocusDuration,
      currentRunStartedAt: clearRunStartedAt
          ? null
          : (currentRunStartedAt ?? this.currentRunStartedAt),
      status: status ?? this.status,
      finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
      pauseReason: clearPauseReason
          ? null
          : replacePauseReason
          ? pauseReason
          : (pauseReason ?? this.pauseReason),
      sourceBvid: sourceBvid ?? this.sourceBvid,
      sourceVideoTitle: sourceVideoTitle ?? this.sourceVideoTitle,
      sourcePartCid: sourcePartCid ?? this.sourcePartCid,
      sourcePartPageNumber: sourcePartPageNumber ?? this.sourcePartPageNumber,
      sourcePartTitle: sourcePartTitle ?? this.sourcePartTitle,
      sourceFramePath: sourceFramePath ?? this.sourceFramePath,
      sourcePosition: sourcePosition ?? this.sourcePosition,
      interruptions: interruptions ?? this.interruptions,
      terminationReason: clearTerminationReason
          ? null
          : (terminationReason ?? this.terminationReason),
      dailyFocusMilliseconds:
          dailyFocusMilliseconds ?? this.dailyFocusMilliseconds,
    );
  }

  /// 返回截至指定时刻的逐日投入快照；当前运行片段只计算，不修改原对象。
  Map<String, int> focusedMillisecondsByLocalDayAt(DateTime now) {
    final Map<String, int> values = status == FocusSessionStatus.running
        ? Map<String, int>.from(_recordCurrentRunUntil(now))
        : Map<String, int>.from(dailyFocusMilliseconds);
    final int elapsedMilliseconds = elapsedAt(now).inMilliseconds;
    final int recordedMilliseconds = values.values.fold<int>(
      0,
      (int total, int value) => total + value,
    );
    final int legacyMilliseconds = elapsedMilliseconds - recordedMilliseconds;
    if (legacyMilliseconds > 0) {
      final DateTime legacyEnd = status == FocusSessionStatus.running
          ? (currentRunStartedAt ?? now)
          : (finishedAt ??
                (interruptions.isNotEmpty
                    ? interruptions.last.occurredAt
                    : startedAt.add(accumulatedFocusDuration)));
      _addLocalDaySegment(
        values,
        legacyEnd.subtract(Duration(milliseconds: legacyMilliseconds)),
        legacyEnd,
        legacyMilliseconds,
      );
    }
    return Map<String, int>.unmodifiable(values);
  }

  /// 把当前连续运行片段结算进本地自然日桶，累计值本身仍由调用方统一更新。
  Map<String, int> _recordCurrentRunUntil(DateTime now) {
    final Map<String, int> values = Map<String, int>.from(
      dailyFocusMilliseconds,
    );
    final DateTime? runStart = currentRunStartedAt;
    if (status != FocusSessionStatus.running || runStart == null) {
      return Map<String, int>.unmodifiable(values);
    }
    final int remainingMilliseconds =
        plannedDuration.inMilliseconds -
        accumulatedFocusDuration.inMilliseconds;
    final int runMilliseconds = now
        .difference(runStart)
        .inMilliseconds
        .clamp(0, remainingMilliseconds);
    if (runMilliseconds > 0) {
      _addLocalDaySegment(
        values,
        runStart,
        runStart.add(Duration(milliseconds: runMilliseconds)),
        runMilliseconds,
      );
    }
    return Map<String, int>.unmodifiable(values);
  }

  /// 将一段连续播放时间按本地午夜切开，避免暂停后恢复时丢失真实投入日期。
  static void _addLocalDaySegment(
    Map<String, int> values,
    DateTime start,
    DateTime end,
    int maximumMilliseconds,
  ) {
    DateTime cursor = start.toLocal();
    final DateTime localEnd = end.toLocal();
    int remainingMilliseconds = maximumMilliseconds;
    while (cursor.isBefore(localEnd) && remainingMilliseconds > 0) {
      final DateTime day = DateTime(cursor.year, cursor.month, cursor.day);
      final DateTime nextDay = DateTime(day.year, day.month, day.day + 1);
      final DateTime segmentEnd = nextDay.isBefore(localEnd)
          ? nextDay
          : localEnd;
      final int milliseconds = segmentEnd
          .difference(cursor)
          .inMilliseconds
          .clamp(0, remainingMilliseconds);
      if (milliseconds <= 0) {
        break;
      }
      final String key = _localDayKey(day);
      values[key] = (values[key] ?? 0) + milliseconds;
      remainingMilliseconds -= milliseconds;
      cursor = segmentEnd;
    }
  }

  /// 把本地日期转换为稳定 JSON 键，不受系统区域语言影响。
  static String _localDayKey(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  /// 把专注记录转换为 SharedPreferences 可保存的 JSON 字典。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'goal': goal,
      'plannedMs': plannedDuration.inMilliseconds,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'accumulatedMs': accumulatedFocusDuration.inMilliseconds,
      'currentRunStartedAt': currentRunStartedAt?.toUtc().toIso8601String(),
      'status': status.name,
      'finishedAt': finishedAt?.toUtc().toIso8601String(),
      'pauseReason': pauseReason?.name,
      'sourceBvid': sourceBvid,
      'sourceVideoTitle': sourceVideoTitle,
      'sourcePartCid': sourcePartCid,
      'sourcePartPageNumber': sourcePartPageNumber,
      'sourcePartTitle': sourcePartTitle,
      'sourceFramePath': sourceFramePath,
      'sourcePositionMs': sourcePosition.inMilliseconds,
      'interruptions': interruptions
          .map((FocusInterruption item) => item.toJson())
          .toList(growable: false),
      'terminationReason': terminationReason,
      'dailyFocusMs': dailyFocusMilliseconds,
    };
  }

  /// 从本机 JSON 安全恢复记录；新字段缺失时兼容第一版和第二版数据。
  static FocusSession? tryParse(Map<String, dynamic> json) {
    final Object? idValue = json['id'];
    final Object? goalValue = json['goal'];
    final Object? plannedMsValue = json['plannedMs'];
    final Object? startedAtValue = json['startedAt'];
    final Object? accumulatedMsValue = json['accumulatedMs'];
    final Object? statusValue = json['status'];
    if (idValue is! String ||
        goalValue is! String ||
        plannedMsValue is! num ||
        startedAtValue is! String ||
        accumulatedMsValue is! num ||
        statusValue is! String) {
      return null;
    }
    final String id = idValue.trim();
    final String goal = goalValue.trim();
    final int plannedMs = plannedMsValue.toInt();
    final int accumulatedMs = accumulatedMsValue.toInt();
    final DateTime? startedAt = DateTime.tryParse(startedAtValue);
    final DateTime? currentRunStartedAt = json['currentRunStartedAt'] is String
        ? DateTime.tryParse(json['currentRunStartedAt'] as String)
        : null;
    final DateTime? finishedAt = json['finishedAt'] is String
        ? DateTime.tryParse(json['finishedAt'] as String)
        : null;
    final FocusSessionStatus? status = FocusSessionStatus.values
        .where((FocusSessionStatus item) => item.name == statusValue)
        .firstOrNull;
    FocusPauseReason? pauseReason = json['pauseReason'] is String
        ? FocusPauseReason.values
              .where(
                (FocusPauseReason item) => item.name == json['pauseReason'],
              )
              .firstOrNull
        : null;
    if (status == FocusSessionStatus.paused && pauseReason == null) {
      pauseReason = FocusPauseReason.manual;
    }
    final bool runningStateValid =
        status != FocusSessionStatus.running || currentRunStartedAt != null;
    final bool finishedStateValid =
        status == FocusSessionStatus.running ||
        status == FocusSessionStatus.paused ||
        finishedAt != null;
    if (id.isEmpty ||
        goal.isEmpty ||
        goal.runes.length > 60 ||
        plannedMs < const Duration(minutes: 1).inMilliseconds ||
        plannedMs > const Duration(hours: 3).inMilliseconds ||
        accumulatedMs < 0 ||
        accumulatedMs > plannedMs ||
        startedAt == null ||
        status == null ||
        !runningStateValid ||
        !finishedStateValid) {
      return null;
    }
    final List<FocusInterruption> interruptions = <FocusInterruption>[];
    final Object? interruptionValues = json['interruptions'];
    if (interruptionValues is List<Object?>) {
      for (final Object? value in interruptionValues) {
        if (value is Map<String, dynamic>) {
          final FocusInterruption? parsed = FocusInterruption.tryParse(value);
          if (parsed != null) {
            interruptions.add(parsed);
          }
        }
      }
    }
    final Map<String, int> dailyFocusMilliseconds = <String, int>{};
    final Object? dailyValues = json['dailyFocusMs'];
    if (dailyValues is Map) {
      for (final MapEntry<Object?, Object?> entry in dailyValues.entries) {
        if (entry.key is! String || entry.value is! num) {
          continue;
        }
        final String key = entry.key! as String;
        final int milliseconds = (entry.value! as num).toInt();
        final DateTime? day = DateTime.tryParse(key);
        if (day != null &&
            key.length == 10 &&
            milliseconds > 0 &&
            milliseconds <= plannedMs) {
          dailyFocusMilliseconds[key] = milliseconds;
        }
      }
    }
    final int dailyTotal = dailyFocusMilliseconds.values.fold<int>(
      0,
      (int total, int value) => total + value,
    );
    if (dailyTotal > accumulatedMs) {
      dailyFocusMilliseconds.clear();
    }
    return FocusSession(
      id: id,
      goal: goal,
      plannedDuration: Duration(milliseconds: plannedMs),
      startedAt: startedAt.toLocal(),
      accumulatedFocusDuration: Duration(milliseconds: accumulatedMs),
      currentRunStartedAt: currentRunStartedAt?.toLocal(),
      status: status,
      finishedAt: finishedAt?.toLocal(),
      pauseReason: pauseReason,
      sourceBvid: _optionalString(json['sourceBvid']),
      sourceVideoTitle: _optionalString(json['sourceVideoTitle']),
      sourcePartCid: json['sourcePartCid'] is num
          ? (json['sourcePartCid'] as num).toInt()
          : null,
      sourcePartPageNumber: json['sourcePartPageNumber'] is num
          ? (json['sourcePartPageNumber'] as num).toInt()
          : null,
      sourcePartTitle: _optionalString(json['sourcePartTitle']),
      sourceFramePath: _optionalString(json['sourceFramePath']),
      sourcePosition: Duration(
        milliseconds: json['sourcePositionMs'] is num
            ? (json['sourcePositionMs'] as num).toInt().clamp(0, 1 << 31)
            : 0,
      ),
      interruptions: List<FocusInterruption>.unmodifiable(interruptions),
      terminationReason: _optionalString(json['terminationReason']),
      dailyFocusMilliseconds: Map<String, int>.unmodifiable(
        dailyFocusMilliseconds,
      ),
    );
  }

  /// 将可空 JSON 字段转换为去除首尾空格的非空字符串。
  static String? _optionalString(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}
