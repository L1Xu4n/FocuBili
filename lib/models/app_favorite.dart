/// 表示本机软件收藏夹的一个文件夹，与 B 站账号收藏相互独立。
class AppFavoriteFolder {
  /// 创建软件收藏夹文件夹。
  const AppFavoriteFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 文件夹的唯一标识，创建时生成并保持不变。
  final String id;

  /// 文件夹名称，用户创建时可输入，展示时使用。
  final String name;

  /// 文件夹创建时间，用于列表排序。
  final DateTime createdAt;

  /// 最近一次变更时间，便于外部按更新时间刷新。
  final DateTime updatedAt;

  /// 从本地存储的 JSON 还原文件夹对象，字段缺失时返回 null。
  static AppFavoriteFolder? fromJson(Map<String, Object?> json) {
    final String? id = json['id'] as String?;
    final String? name = json['name'] as String?;
    final String? createdAt = json['createdAt'] as String?;
    final String? updatedAt = json['updatedAt'] as String?;
    if (id == null || name == null || createdAt == null || updatedAt == null) {
      return null;
    }
    return AppFavoriteFolder(
      id: id,
      name: name,
      createdAt:
          DateTime.tryParse(createdAt) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(updatedAt) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 序列化为可持久化的 JSON 映射。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 表示软件收藏夹中保存的一支视频。
class AppFavoriteItem {
  /// 创建软件收藏夹收藏项。
  const AppFavoriteItem({
    required this.folderId,
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.ownerName,
    required this.durationText,
    required this.addedAt,
  });

  /// 所属文件夹标识，与 [AppFavoriteFolder.id] 对应。
  final String folderId;

  /// 视频 BV 号，用于在播放器中打开和判断重复收藏。
  final String bvid;

  /// 视频标题，列表与详情页展示使用。
  final String title;

  /// 视频封面地址，可能为空字符串。
  final String coverUrl;

  /// UP 主名称，列表展示使用。
  final String ownerName;

  /// 视频时长文本，收藏时格式化保存。
  final String durationText;

  /// 收藏时间，用于列表倒序排序。
  final DateTime addedAt;

  /// 从本地存储的 JSON 还原收藏项，字段缺失时返回 null。
  static AppFavoriteItem? fromJson(Map<String, Object?> json) {
    final String? folderId = json['folderId'] as String?;
    final String? bvid = json['bvid'] as String?;
    final String? title = json['title'] as String?;
    final String? addedAt = json['addedAt'] as String?;
    if (folderId == null || bvid == null || title == null || addedAt == null) {
      return null;
    }
    return AppFavoriteItem(
      folderId: folderId,
      bvid: bvid,
      title: title,
      coverUrl: json['coverUrl'] as String? ?? '',
      ownerName: json['ownerName'] as String? ?? '',
      durationText: json['durationText'] as String? ?? '',
      addedAt:
          DateTime.tryParse(addedAt) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 序列化为可持久化的 JSON 映射。
  Map<String, Object?> toJson() => <String, Object?>{
    'folderId': folderId,
    'bvid': bvid,
    'title': title,
    'coverUrl': coverUrl,
    'ownerName': ownerName,
    'durationText': durationText,
    'addedAt': addedAt.toIso8601String(),
  };
}
