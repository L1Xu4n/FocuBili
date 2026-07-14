/// 表示一支视频中的单个分P，保存切换播放所需的编号、标题和时长。
class VideoPart {
  /// 创建一条包含分P序号、播放编号、标题和时长的信息。
  const VideoPart({
    required this.pageNumber,
    required this.cid,
    required this.title,
    required this.duration,
  });

  final int pageNumber;
  final int cid;
  final String title;
  final Duration duration;
}

/// 保存视频或合集条目的公开互动统计，只用于只读展示。
class VideoStats {
  /// 创建一组公开统计；接口缺失字段时对应数值保持为零。
  const VideoStats({
    this.viewCount = 0,
    this.danmakuCount = 0,
    this.replyCount = 0,
    this.favoriteCount = 0,
    this.coinCount = 0,
    this.shareCount = 0,
    this.likeCount = 0,
  });

  final int viewCount;
  final int danmakuCount;
  final int replyCount;
  final int favoriteCount;
  final int coinCount;
  final int shareCount;
  final int likeCount;
}

/// 表示 UGC 合集中的一支独立视频，不与单支视频内部的分P混用。
class VideoCollectionEntry {
  /// 创建合集视频卡片所需的编号、封面、时长和公开统计。
  const VideoCollectionEntry({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.thumbnailUrl,
    required this.duration,
    this.aid = 0,
    this.publishedAt,
    this.stats = const VideoStats(),
  });

  final int aid;
  final String bvid;
  final int cid;
  final String title;
  final String thumbnailUrl;
  final Duration duration;
  final DateTime? publishedAt;
  final VideoStats stats;
}

/// 表示由多支不同视频组成的 UGC 合集，与 VideoPart 的单视频分P概念分离。
class VideoCollection {
  /// 创建合集资料以及按服务端顺序排列的视频条目。
  const VideoCollection({
    required this.id,
    required this.title,
    required this.entries,
    this.description = '',
    this.coverUrl = '',
    this.ownerMid = 0,
    this.totalCount = 0,
    this.stats = const VideoStats(),
  });

  final int id;
  final String title;
  final String description;
  final String coverUrl;
  final int ownerMid;
  final int totalCount;
  final VideoStats stats;
  final List<VideoCollectionEntry> entries;

  /// 返回当前 BV 号在合集中的零起始位置，找不到时返回 -1。
  int indexOfBvid(String bvid) {
    return entries.indexWhere(
      (VideoCollectionEntry entry) => entry.bvid == bvid,
    );
  }
}

/// 表示关键词搜索返回的一条轻量结果，点击后再查询完整分P信息。
class VideoSearchResult {
  /// 创建包含 BV 号、标题、作者、时长和封面地址的搜索结果。
  const VideoSearchResult({
    required this.bvid,
    required this.title,
    required this.ownerName,
    required this.duration,
    required this.thumbnailUrl,
    required this.publishedAt,
    required this.playCount,
    required this.danmakuCount,
    required this.episodeCountText,
  });

  final String bvid;
  final String title;
  final String ownerName;
  final Duration duration;
  final String thumbnailUrl;
  final DateTime? publishedAt;
  final int playCount;
  final int danmakuCount;
  final String episodeCountText;
}

/// 定义关键词视频搜索的排序方式。
enum VideoSearchOrder {
  relevance,
  mostPlayed,
  newest,
  mostDanmaku,
  mostFavorited
}

/// 定义关键词视频搜索的发布日期范围。
enum VideoPublishedRange { any, lastDay, lastWeek, lastHalfYear }

/// 定义关键词视频搜索的内容时长范围。
enum VideoDurationRange {
  any,
  underTenMinutes,
  tenToThirtyMinutes,
  thirtyToSixtyMinutes,
  overSixtyMinutes
}

/// 保存搜索筛选条件，默认不限制日期、时长和内容分区。
class VideoSearchFilter {
  /// 创建一组可以直接转换为搜索接口参数的筛选条件。
  const VideoSearchFilter({
    this.order = VideoSearchOrder.relevance,
    this.publishedRange = VideoPublishedRange.any,
    this.durationRange = VideoDurationRange.any,
    this.categoryId,
    this.categoryLabel = '全部',
  });

  final VideoSearchOrder order;
  final VideoPublishedRange publishedRange;
  final VideoDurationRange durationRange;
  final int? categoryId;
  final String categoryLabel;

  /// 返回替换指定字段后的新筛选对象，并支持显式清除内容分区。
  VideoSearchFilter copyWith({
    VideoSearchOrder? order,
    VideoPublishedRange? publishedRange,
    VideoDurationRange? durationRange,
    int? categoryId,
    String? categoryLabel,
    bool clearCategory = false,
  }) {
    return VideoSearchFilter(
      order: order ?? this.order,
      publishedRange: publishedRange ?? this.publishedRange,
      durationRange: durationRange ?? this.durationRange,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      categoryLabel: categoryLabel ?? this.categoryLabel,
    );
  }
}

/// 保存一页关键词搜索结果以及继续加载所需的页码信息。
class VideoSearchPage {
  /// 创建包含当前页、总页数和结果列表的搜索分页对象。
  const VideoSearchPage({
    required this.results,
    required this.page,
    required this.totalPages,
  });

  final List<VideoSearchResult> results;
  final int page;
  final int totalPages;

  /// 判断服务端是否仍有下一页结果可以加载。
  bool get hasMore => page < totalPages;
}

/// 页面之间传递的视频信息，包含 BV 号、默认分P以及完整分P列表。
class VideoPreview {
  /// 创建一支可由原生播放器打开并切换分P的视频详情。
  const VideoPreview({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.ownerName,
    required this.parts,
    this.duration = const Duration(minutes: 3, seconds: 32),
    this.thumbnailUrl = '',
    this.aid = 0,
    this.ownerMid = 0,
    this.ownerAvatarUrl = '',
    this.description = '',
    this.publishedAt,
    this.stats = const VideoStats(),
    this.collection,
  });

  final int aid;
  final String bvid;

  /// 标识当前视频分P的编号，原生层用它请求对应的播放数据。
  final int cid;
  final String title;
  final String ownerName;
  final int ownerMid;
  final String ownerAvatarUrl;
  final String description;
  final DateTime? publishedAt;
  final VideoStats stats;
  final VideoCollection? collection;
  final Duration duration;

  /// 视频封面地址，仅用于低流量缩略图展示；为空时页面显示本地占位图。
  final String thumbnailUrl;
  final List<VideoPart> parts;

  /// 返回与默认 cid 对应的分P；接口数据不完整时回退到列表第一项。
  VideoPart get initialPart {
    for (final VideoPart part in parts) {
      if (part.cid == cid) {
        return part;
      }
    }
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return VideoPart(
      pageNumber: 1,
      cid: cid,
      title: title,
      duration: duration,
    );
  }

  /// 返回用于框架演示的默认视频，不执行任何网络请求。
  factory VideoPreview.placeholder() {
    return const VideoPreview(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      title: '原生播放器框架预览',
      ownerName: '焦点哔哩',
      parts: <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 137649199,
          title: 'Never Gonna Give You Up - Rick Astley',
          duration: Duration(minutes: 3, seconds: 32),
        ),
      ],
    );
  }
}
