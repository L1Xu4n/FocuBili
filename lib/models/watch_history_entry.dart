/// 表示一条仅保存在本机的观看记录，不包含登录、播放地址或账号数据。
class WatchHistoryEntry {
  /// 创建一条观看记录，调用方应传入当前播放到的分P和记录时间。
  const WatchHistoryEntry({
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.lastPartTitle,
    required this.lastPartPageNumber,
    required this.watchedAt,
  });

  /// 视频的 BV 号，用于合并同一支视频的多次观看记录。
  final String bvid;

  /// 视频标题，仅用于在本机历史列表中显示。
  final String title;

  /// 视频作者名称，仅用于在本机历史列表中显示。
  final String ownerName;

  /// 最近观看的分P标题。
  final String lastPartTitle;

  /// 最近观看的分P序号，从 1 开始。
  final int lastPartPageNumber;

  /// 最近一次记录观看状态的本机时间。
  final DateTime watchedAt;

  /// 将这条记录转换为可写入 SharedPreferences 的最小 JSON 对象。
  Map<String, Object> toJson() {
    return <String, Object>{
      'bvid': bvid,
      'title': title,
      'ownerName': ownerName,
      'lastPartTitle': lastPartTitle,
      'lastPartPageNumber': lastPartPageNumber,
      'watchedAt': watchedAt.toUtc().toIso8601String(),
    };
  }

  /// 从已解码的 JSON 对象读取观看记录；字段缺失或类型错误时返回 null。
  static WatchHistoryEntry? tryParse(Map<String, dynamic> json) {
    final Object? bvid = json['bvid'];
    final Object? title = json['title'];
    final Object? ownerName = json['ownerName'];
    final Object? lastPartTitle = json['lastPartTitle'];
    final Object? lastPartPageNumber = json['lastPartPageNumber'];
    final Object? watchedAt = json['watchedAt'];
    if (bvid is! String ||
        title is! String ||
        ownerName is! String ||
        lastPartTitle is! String ||
        lastPartPageNumber is! int ||
        watchedAt is! String) {
      return null;
    }

    final String normalizedBvid = bvid.trim();
    final String normalizedTitle = title.trim();
    final String normalizedOwnerName = ownerName.trim();
    final String normalizedPartTitle = lastPartTitle.trim();
    final DateTime? parsedWatchedAt = DateTime.tryParse(watchedAt);
    if (normalizedBvid.isEmpty ||
        normalizedTitle.isEmpty ||
        normalizedOwnerName.isEmpty ||
        normalizedPartTitle.isEmpty ||
        lastPartPageNumber < 1 ||
        parsedWatchedAt == null) {
      return null;
    }

    return WatchHistoryEntry(
      bvid: normalizedBvid,
      title: normalizedTitle,
      ownerName: normalizedOwnerName,
      lastPartTitle: normalizedPartTitle,
      lastPartPageNumber: lastPartPageNumber,
      watchedAt: parsedWatchedAt.toLocal(),
    );
  }

  /// 判断两条记录的全部本地展示字段是否相同，便于测试和状态比较。
  @override
  bool operator ==(Object other) {
    return other is WatchHistoryEntry &&
        bvid == other.bvid &&
        title == other.title &&
        ownerName == other.ownerName &&
        lastPartTitle == other.lastPartTitle &&
        lastPartPageNumber == other.lastPartPageNumber &&
        watchedAt == other.watchedAt;
  }

  /// 返回与全部字段对应的哈希值，需与相等判断保持一致。
  @override
  int get hashCode => Object.hash(
        bvid,
        title,
        ownerName,
        lastPartTitle,
        lastPartPageNumber,
        watchedAt,
      );
}
