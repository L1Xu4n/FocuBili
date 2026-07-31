/// 表示学习清单中一条视频任务当前所处的学习阶段。
enum LearningListStatus {
  /// 用户已经加入清单，但还没有从该任务开始播放。
  notStarted,

  /// 用户正在学习这条视频，分P和播放位置会随播放器更新。
  learning,

  /// 用户主动确认已经完成这条学习任务。
  completed;

  /// 返回用于界面展示的中文状态名称。
  String get label => switch (this) {
    LearningListStatus.notStarted => '未开始',
    LearningListStatus.learning => '学习中',
    LearningListStatus.completed => '已完成',
  };
}

/// 表示一条仅保存在当前设备上的学习任务及其最近学习进度。
class LearningListEntry {
  /// 创建包含视频资料、当前分P、时间点和学习状态的本机任务。
  const LearningListEntry({
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.partCid,
    required this.partPageNumber,
    required this.partTitle,
    required this.position,
    required this.duration,
    required this.status,
    required this.addedAt,
    required this.updatedAt,
    this.thumbnailUrl = '',
  });

  /// 视频的 BV 号，用于合并同一视频的重复加入操作。
  final String bvid;

  /// 视频标题，仅用于学习清单和首页继续学习卡片展示。
  final String title;

  /// 视频作者名称，仅用于帮助用户识别学习任务。
  final String ownerName;

  /// 视频封面地址，仅用于低流量缩略图展示。
  final String thumbnailUrl;

  /// 当前要继续学习的分P CID，播放器用它恢复到正确分P。
  final int partCid;

  /// 当前要继续学习的分P序号，从 1 开始。
  final int partPageNumber;

  /// 当前分P的标题，接口临时不可用时仍可显示任务上下文。
  final String partTitle;

  /// 当前分P最近保存的播放位置。
  final Duration position;

  /// 当前分P的总时长，用于界面显示已学进度。
  final Duration duration;

  /// 这条任务的用户可控学习状态。
  final LearningListStatus status;

  /// 任务首次加入学习清单的本机时间。
  final DateTime addedAt;

  /// 任务、状态或观看进度最后一次更新的本机时间。
  final DateTime updatedAt;

  /// 复制任务并替换指定字段，未传入的资料保持不变。
  LearningListEntry copyWith({
    String? title,
    String? ownerName,
    String? thumbnailUrl,
    int? partCid,
    int? partPageNumber,
    String? partTitle,
    Duration? position,
    Duration? duration,
    LearningListStatus? status,
    DateTime? updatedAt,
  }) {
    return LearningListEntry(
      bvid: bvid,
      title: title ?? this.title,
      ownerName: ownerName ?? this.ownerName,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      partCid: partCid ?? this.partCid,
      partPageNumber: partPageNumber ?? this.partPageNumber,
      partTitle: partTitle ?? this.partTitle,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      status: status ?? this.status,
      addedAt: addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 将任务转换为 SharedPreferences 可保存的最小 JSON 字典。
  Map<String, Object> toJson() {
    return <String, Object>{
      'bvid': bvid,
      'title': title,
      'ownerName': ownerName,
      'thumbnailUrl': thumbnailUrl,
      'partCid': partCid,
      'partPageNumber': partPageNumber,
      'partTitle': partTitle,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'status': status.name,
      'addedAt': addedAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// 从已解码 JSON 安全读取任务；缺失关键字段或值非法时返回 null。
  static LearningListEntry? tryParse(Map<String, dynamic> json) {
    final Object? bvid = json['bvid'];
    final Object? title = json['title'];
    final Object? ownerName = json['ownerName'];
    final Object? thumbnailUrl = json['thumbnailUrl'];
    final Object? partCid = json['partCid'];
    final Object? partPageNumber = json['partPageNumber'];
    final Object? partTitle = json['partTitle'];
    final Object? positionMs = json['positionMs'];
    final Object? durationMs = json['durationMs'];
    final Object? status = json['status'];
    final Object? addedAt = json['addedAt'];
    final Object? updatedAt = json['updatedAt'];
    if (bvid is! String ||
        title is! String ||
        ownerName is! String ||
        partCid is! num ||
        partPageNumber is! num ||
        partTitle is! String ||
        positionMs is! num ||
        durationMs is! num ||
        addedAt is! String ||
        updatedAt is! String) {
      return null;
    }
    final String normalizedBvid = bvid.trim();
    final String normalizedTitle = title.trim();
    final int normalizedCid = partCid.toInt();
    final int normalizedPageNumber = partPageNumber.toInt();
    final int normalizedDurationMs = durationMs
        .toInt()
        .clamp(0, 24 * 60 * 60 * 1000)
        .toInt();
    final int normalizedPositionMs = positionMs
        .toInt()
        .clamp(
          0,
          normalizedDurationMs == 0
              ? 24 * 60 * 60 * 1000
              : normalizedDurationMs,
        )
        .toInt();
    final DateTime? parsedAddedAt = DateTime.tryParse(addedAt);
    final DateTime? parsedUpdatedAt = DateTime.tryParse(updatedAt);
    final LearningListStatus parsedStatus = LearningListStatus.values
        .firstWhere(
          (LearningListStatus value) => value.name == status,
          // 旧版或损坏状态字段统一回退为未开始，避免整条本机任务丢失。
          orElse: () => LearningListStatus.notStarted,
        );
    if (normalizedBvid.isEmpty ||
        normalizedTitle.isEmpty ||
        normalizedCid <= 0 ||
        normalizedPageNumber <= 0 ||
        parsedAddedAt == null ||
        parsedUpdatedAt == null) {
      return null;
    }
    return LearningListEntry(
      bvid: normalizedBvid,
      title: normalizedTitle,
      ownerName: ownerName.trim(),
      thumbnailUrl: thumbnailUrl is String ? thumbnailUrl.trim() : '',
      partCid: normalizedCid,
      partPageNumber: normalizedPageNumber,
      partTitle: partTitle.trim(),
      position: Duration(milliseconds: normalizedPositionMs),
      duration: Duration(milliseconds: normalizedDurationMs),
      status: parsedStatus,
      addedAt: parsedAddedAt.toLocal(),
      updatedAt: parsedUpdatedAt.toLocal(),
    );
  }

  /// 判断两条任务全部字段是否一致，便于测试和页面状态比较。
  @override
  bool operator ==(Object other) {
    return other is LearningListEntry &&
        bvid == other.bvid &&
        title == other.title &&
        ownerName == other.ownerName &&
        thumbnailUrl == other.thumbnailUrl &&
        partCid == other.partCid &&
        partPageNumber == other.partPageNumber &&
        partTitle == other.partTitle &&
        position == other.position &&
        duration == other.duration &&
        status == other.status &&
        addedAt == other.addedAt &&
        updatedAt == other.updatedAt;
  }

  /// 返回与全部字段对应的哈希值，需与相等判断保持一致。
  @override
  int get hashCode => Object.hash(
    bvid,
    title,
    ownerName,
    thumbnailUrl,
    partCid,
    partPageNumber,
    partTitle,
    position,
    duration,
    status,
    addedAt,
    updatedAt,
  );
}
