/// 表示学习清单中一条视频分 P 任务当前所处的学习阶段。
enum LearningListStatus {
  /// 用户已经加入清单，但还没有开始播放。
  notStarted,

  /// 用户已经开始学习该分 P，但还没有明确标记完成。
  learning,

  /// 用户已经明确完成该分 P；页面会把它放在未完成任务之后。
  completed,
}

/// 为学习状态提供稳定、面向普通用户的中文显示文字。
extension LearningListStatusLabel on LearningListStatus {
  /// 返回状态在列表和操作菜单中使用的中文标签。
  String get label => switch (this) {
    LearningListStatus.notStarted => '未开始',
    LearningListStatus.learning => '学习中',
    LearningListStatus.completed => '已完成',
  };
}

/// 表示学习清单内一个可独立排序、独立完成的视频分 P 任务。
class LearningListEntry {
  /// 创建一条学习任务；同一视频的不同 CID 会保存为不同条目。
  const LearningListEntry({
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.thumbnailUrl,
    required this.partCid,
    required this.partPageNumber,
    required this.partTitle,
    required this.position,
    required this.duration,
    required this.status,
    required this.addedAt,
    required this.updatedAt,
    this.sortOrder = 0,
  });

  /// 视频的公开 BV 编号，不保存完整播放地址或登录凭据。
  final String bvid;

  /// 视频标题，仅用于学习清单和首页继续学习卡片展示。
  final String title;

  /// 投稿者名称，仅用于帮助用户在清单中识别视频。
  final String ownerName;

  /// 视频封面缩略图地址，读取失败时界面会显示本地占位图。
  final String thumbnailUrl;

  /// 当前学习任务所对应分 P 的 CID；它与 BV 共同组成唯一标识。
  final int partCid;

  /// 便于阅读的分 P 序号，例如 P1、P2。
  final int partPageNumber;

  /// 分 P 的原始标题，例如“第一节”。
  final String partTitle;

  /// 当前分 P 已保存的播放位置。
  final Duration position;

  /// 当前分 P 的总时长；接口缺失时为零。
  final Duration duration;

  /// 该分 P 学习任务的完成状态。
  final LearningListStatus status;

  /// 用户首次加入该分 P 到学习清单的本机时间。
  final DateTime addedAt;

  /// 最近一次更新进度、状态或排序的本机时间。
  final DateTime updatedAt;

  /// 用户为学习顺序设置的数字；数值越小，未完成任务越靠前。
  final int sortOrder;

  /// 返回以 BV 与 CID 组成的稳定唯一标识，避免同一视频不同 P 相互覆盖。
  String get stableId => '$bvid:$partCid';

  /// 判断候选视频和分 P 是否正好对应这一条学习任务。
  bool matchesPart(String candidateBvid, int candidatePartCid) {
    return bvid == candidateBvid.trim() && partCid == candidatePartCid;
  }

  /// 基于当前任务替换指定字段，未传入的字段保持原值。
  LearningListEntry copyWith({
    String? bvid,
    String? title,
    String? ownerName,
    String? thumbnailUrl,
    int? partCid,
    int? partPageNumber,
    String? partTitle,
    Duration? position,
    Duration? duration,
    LearningListStatus? status,
    DateTime? addedAt,
    DateTime? updatedAt,
    int? sortOrder,
  }) {
    return LearningListEntry(
      bvid: bvid ?? this.bvid,
      title: title ?? this.title,
      ownerName: ownerName ?? this.ownerName,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      partCid: partCid ?? this.partCid,
      partPageNumber: partPageNumber ?? this.partPageNumber,
      partTitle: partTitle ?? this.partTitle,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      status: status ?? this.status,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sortOrder: sortOrder ?? this.sortOrder,
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
      'sortOrder': sortOrder,
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
    final Object? sortOrder = json['sortOrder'];
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
    final int normalizedSortOrder = (sortOrder is num ? sortOrder.toInt() : 0)
        .clamp(0, 1 << 31)
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
      sortOrder: normalizedSortOrder,
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
        updatedAt == other.updatedAt &&
        sortOrder == other.sortOrder;
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
    sortOrder,
  );
}
