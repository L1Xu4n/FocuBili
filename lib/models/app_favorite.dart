/// 表示软件内独立收藏夹中的一个收藏夹，不与 B 站账号收藏混用。
///
/// 数据只保存在当前设备，不写入 B 站账号；导入的 B 站收藏内容只会复制到
/// 本机收藏夹，不会修改或删除原账号收藏。
class AppFavoriteFolder {
  /// 创建一份不可变的软件收藏夹资料。
  const AppFavoriteFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 收藏夹唯一标识；由创建时生成的稳定编号构成，不依赖界面顺序。
  final String id;

  /// 收藏夹名称，允许用户随时重命名。
  final String name;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近一次名称或内容变更时间。
  final DateTime updatedAt;

  /// 创建一份名称已去除首尾空白的新收藏夹。
  factory AppFavoriteFolder.create(String name) {
    final DateTime now = DateTime.now();
    return AppFavoriteFolder(
      id: '${now.microsecondsSinceEpoch}',
      name: name.trim(),
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 返回一份修改了名称和时间的新收藏夹，未传入的字段保持不变。
  AppFavoriteFolder copyWith({String? name, DateTime? updatedAt}) {
    return AppFavoriteFolder(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 序列化为可写入本机 JSON 的对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// 从本机 JSON 恢复收藏夹；结构不合法时返回 null 交由上层丢弃。
  static AppFavoriteFolder? tryParse(Map<String, dynamic> json) {
    final String? id = json['id'];
    final String? name = json['name'];
    final DateTime? createdAt = DateTime.tryParse(
      json['createdAt']?.toString() ?? '',
    );
    final DateTime? updatedAt = DateTime.tryParse(
      json['updatedAt']?.toString() ?? '',
    );
    final String normalizedName = name?.trim() ?? '';
    if (id == null ||
        id.isEmpty ||
        normalizedName.isEmpty ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    return AppFavoriteFolder(
      id: id,
      name: normalizedName,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// 表示软件收藏夹中的一条视频，保留进入播放器所需的最小信息。
class AppFavoriteItem {
  /// 创建一条不可变的软件收藏视频。
  const AppFavoriteItem({
    required this.folderId,
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.ownerName,
    required this.durationText,
    required this.addedAt,
    this.sourceLabel,
  });

  /// 所属软件收藏夹标识。
  final String folderId;

  /// 视频 BV 号；播放前通过公开详情接口补齐 cid 和完整分P。
  final String bvid;

  /// 视频标题。
  final String title;

  /// 视频封面 HTTPS 地址；无法确认安全地址时为空字符串。
  final String coverUrl;

  /// 视频作者昵称。
  final String ownerName;

  /// 服务端给出的总时长文本（例如“10:00”），未知时为空字符串。
  final String durationText;

  /// 收藏到本机的时间。
  final DateTime addedAt;

  /// 可选的来源说明（例如“B站收藏夹：知识清单”），仅用于界面展示。
  final String? sourceLabel;

  /// 返回一份修改了文件夹和来源的新条目，其余字段保持不变。
  AppFavoriteItem copyWith({String? folderId, String? sourceLabel}) {
    return AppFavoriteItem(
      folderId: folderId ?? this.folderId,
      bvid: bvid,
      title: title,
      coverUrl: coverUrl,
      ownerName: ownerName,
      durationText: durationText,
      addedAt: addedAt,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }

  /// 序列化为可写入本机 JSON 的对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'folderId': folderId,
      'bvid': bvid,
      'title': title,
      'coverUrl': coverUrl,
      'ownerName': ownerName,
      'durationText': durationText,
      'addedAt': addedAt.toIso8601String(),
      if (sourceLabel != null && sourceLabel!.isNotEmpty)
        'sourceLabel': sourceLabel,
    };
  }

  /// 从本机 JSON 恢复收藏条目；结构不合法时返回 null 交由上层丢弃。
  static AppFavoriteItem? tryParse(Map<String, dynamic> json) {
    final String? folderId = json['folderId'];
    final String? bvid = json['bvid'];
    final String? title = json['title'];
    final String? ownerName = json['ownerName'];
    final DateTime? addedAt = DateTime.tryParse(
      json['addedAt']?.toString() ?? '',
    );
    final String normalizedBvid = bvid?.trim() ?? '';
    if (folderId == null ||
        folderId.isEmpty ||
        normalizedBvid.isEmpty ||
        (title?.trim().isEmpty ?? true) ||
        (ownerName?.trim().isEmpty ?? true) ||
        addedAt == null) {
      return null;
    }
    return AppFavoriteItem(
      folderId: folderId,
      bvid: normalizedBvid,
      title: title!.trim(),
      coverUrl: json['coverUrl']?.toString() ?? '',
      ownerName: ownerName!.trim(),
      durationText: json['durationText']?.toString() ?? '',
      addedAt: addedAt,
      sourceLabel: json['sourceLabel']?.toString(),
    );
  }
}

/// 保存一次导入结果统计，供页面提示用户实际新增了多少内容。
class AppFavoriteImportResult {
  /// 创建一次导入结果。
  const AppFavoriteImportResult({
    required this.folderCount,
    required this.itemCount,
  });

  /// 新增收藏夹数量。
  final int folderCount;

  /// 新增收藏条目数量（已按 BV 去重）。
  final int itemCount;

  /// 是否没有任何新增内容。
  bool get isEmpty => folderCount == 0 && itemCount == 0;
}
