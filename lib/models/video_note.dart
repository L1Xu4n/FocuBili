/// 一张笔记画面及其真实视频位置；列表顺序就是用户的展示顺序。
class VideoNoteFrame {
  const VideoNoteFrame({required this.path, required this.position});

  final String path;
  final Duration position;

  @override
  bool operator ==(Object other) =>
      other is VideoNoteFrame &&
      other.path == path &&
      other.position == position;
  @override
  int get hashCode => Object.hash(path, position);

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'positionMs': position.inMilliseconds,
  };

  static VideoNoteFrame? tryParse(Map<Object?, Object?> json) {
    final path = json['path'];
    final position = json['positionMs'];
    if (path is! String || path.trim().isEmpty || position is! num) return null;
    return VideoNoteFrame(
      path: path.trim(),
      position: Duration(milliseconds: position.toInt().clamp(0, 604800000)),
    );
  }
}

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
    String? framePath,
    this.frames = const <VideoNoteFrame>[],
  }) : _legacyFramePath = framePath;

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
  final String? _legacyFramePath;
  final List<VideoNoteFrame> frames;

  /// 旧单图调用方仍可读取第一张画面；旧记录按笔记时间点迁移。
  String? get framePath =>
      frames.isNotEmpty ? frames.first.path : _legacyFramePath;
  List<VideoNoteFrame> get allFrames => List<VideoNoteFrame>.unmodifiable(
    frames.isNotEmpty
        ? frames
        : _legacyFramePath == null || _legacyFramePath.trim().isEmpty
        ? const <VideoNoteFrame>[]
        : <VideoNoteFrame>[
            VideoNoteFrame(path: _legacyFramePath, position: position),
          ],
  );

  /// 复制笔记并替换用户编辑过的字段，更新时间由调用方明确写入。
  VideoNote copyWith({
    String? title,
    String? body,
    DateTime? updatedAt,
    Duration? position,
    String? videoCoverUrl,
    String? framePath,
    List<VideoNoteFrame>? frames,
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
      frames: clearFrame
          ? const <VideoNoteFrame>[]
          : frames ??
                (framePath == null
                    ? allFrames
                    : <VideoNoteFrame>[
                        VideoNoteFrame(
                          path: framePath,
                          position: position ?? this.position,
                        ),
                      ]),
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
      'frames': allFrames
          .map((frame) => frame.toJson())
          .toList(growable: false),
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
    final Object? rawFrames = json['frames'];
    final List<VideoNoteFrame> frames = <VideoNoteFrame>[];
    if (rawFrames is List) {
      for (final rawFrame in rawFrames) {
        if (rawFrame is! Map) continue;
        final frame = VideoNoteFrame.tryParse(
          Map<Object?, Object?>.from(rawFrame),
        );
        if (frame != null) frames.add(frame);
      }
    }
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
      frames: List<VideoNoteFrame>.unmodifiable(frames),
    );
  }
}
