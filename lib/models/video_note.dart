/// 表示一条仅保存在本机的视频时间点笔记。
class VideoNote {
  /// 创建包含视频来源、自动记录时间、播放位置和可选画面的笔记。
  const VideoNote({
    required this.id,
    required this.bvid,
    required this.videoTitle,
    required this.ownerName,
    required this.partCid,
    required this.partPageNumber,
    required this.partTitle,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.position,
    this.videoCoverUrl = '',
    this.framePath,
  });

  final String id;
  final String bvid;
  final String videoTitle;
  final String ownerName;
  final int partCid;
  final int partPageNumber;
  final String partTitle;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Duration position;
  final String videoCoverUrl;
  final String? framePath;

  /// 复制笔记并替换用户编辑过的字段，更新时间由调用方明确写入。
  VideoNote copyWith({
    String? title,
    String? body,
    DateTime? updatedAt,
    Duration? position,
    String? videoCoverUrl,
    String? framePath,
    bool clearFrame = false,
  }) {
    return VideoNote(
      id: id,
      bvid: bvid,
      videoTitle: videoTitle,
      ownerName: ownerName,
      partCid: partCid,
      partPageNumber: partPageNumber,
      partTitle: partTitle,
      title: title ?? this.title,
      body: body ?? this.body,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      position: position ?? this.position,
      videoCoverUrl: videoCoverUrl ?? this.videoCoverUrl,
      framePath: clearFrame ? null : (framePath ?? this.framePath),
    );
  }

  /// 将笔记转换为 SharedPreferences 可保存的 JSON 字典。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'bvid': bvid,
      'videoTitle': videoTitle,
      'ownerName': ownerName,
      'partCid': partCid,
      'partPageNumber': partPageNumber,
      'partTitle': partTitle,
      'title': title,
      'body': body,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'positionMs': position.inMilliseconds,
      'videoCoverUrl': videoCoverUrl,
      'framePath': framePath,
    };
  }

  /// 从已解码的 JSON 字典安全读取笔记，缺少关键字段时返回空值。
  static VideoNote? tryParse(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? bvid = json['bvid'];
    final Object? videoTitle = json['videoTitle'];
    final Object? ownerName = json['ownerName'];
    final Object? partCid = json['partCid'];
    final Object? partPageNumber = json['partPageNumber'];
    final Object? partTitle = json['partTitle'];
    final Object? title = json['title'];
    final Object? body = json['body'];
    final Object? createdAt = json['createdAt'];
    final Object? updatedAt = json['updatedAt'];
    final Object? positionMs = json['positionMs'];
    final Object? videoCoverUrl = json['videoCoverUrl'];
    final Object? framePath = json['framePath'];
    if (id is! String ||
        bvid is! String ||
        videoTitle is! String ||
        ownerName is! String ||
        partCid is! num ||
        partPageNumber is! num ||
        partTitle is! String ||
        title is! String ||
        body is! String ||
        createdAt is! String ||
        updatedAt is! String ||
        positionMs is! num) {
      return null;
    }
    final DateTime? parsedCreatedAt = DateTime.tryParse(createdAt);
    final DateTime? parsedUpdatedAt = DateTime.tryParse(updatedAt);
    final String normalizedId = id.trim();
    final String normalizedBvid = bvid.trim();
    final String normalizedVideoTitle = videoTitle.trim();
    final String normalizedTitle = title.trim();
    final int normalizedPartCid = partCid.toInt();
    final int normalizedPartPageNumber = partPageNumber.toInt();
    if (normalizedId.isEmpty ||
        normalizedBvid.isEmpty ||
        normalizedVideoTitle.isEmpty ||
        normalizedTitle.isEmpty ||
        normalizedPartCid <= 0 ||
        normalizedPartPageNumber <= 0 ||
        parsedCreatedAt == null ||
        parsedUpdatedAt == null) {
      return null;
    }
    return VideoNote(
      id: normalizedId,
      bvid: normalizedBvid,
      videoTitle: normalizedVideoTitle,
      ownerName: ownerName.trim(),
      partCid: normalizedPartCid,
      partPageNumber: normalizedPartPageNumber,
      partTitle: partTitle.trim(),
      title: normalizedTitle,
      body: body.trim(),
      createdAt: parsedCreatedAt.toLocal(),
      updatedAt: parsedUpdatedAt.toLocal(),
      position: Duration(milliseconds: positionMs.toInt().clamp(0, 604800000)),
      videoCoverUrl: videoCoverUrl is String ? videoCoverUrl.trim() : '',
      framePath: framePath is String && framePath.trim().isNotEmpty
          ? framePath.trim()
          : null,
    );
  }
}
