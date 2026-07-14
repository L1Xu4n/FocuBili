import 'video_preview.dart';

/// 表示 UP 主投稿列表的服务端排序方式。
enum CreatorVideoOrder { latest, mostPlayed, mostFavorited }

/// 保存公开 UP 主主页头部需要的资料和只读统计。
class CreatorProfile {
  /// 创建公开主页资料；未返回的统计保持为零。
  const CreatorProfile({
    required this.mid,
    required this.name,
    required this.avatarUrl,
    required this.sign,
    required this.officialDescription,
    this.followingCount = 0,
    this.followerCount = 0,
    this.likeCount = 0,
    this.videoCount = 0,
    this.articleCount = 0,
  });

  final int mid;
  final String name;
  final String avatarUrl;
  final String sign;
  final String officialDescription;
  final int followingCount;
  final int followerCount;
  final int likeCount;
  final int videoCount;
  final int articleCount;
}

/// 表示 UP 主公开投稿列表中的一支视频。
class CreatorVideo {
  /// 创建投稿卡片需要的 BV 号、封面、时长、日期和统计。
  const CreatorVideo({
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.duration,
    this.publishedAt,
    this.stats = const VideoStats(),
  });

  final String bvid;
  final String title;
  final String coverUrl;
  final Duration duration;
  final DateTime? publishedAt;
  final VideoStats stats;
}

/// 表示 UP 主公开专栏中的一篇文章摘要。
class CreatorArticle {
  /// 创建文章卡片需要的编号、标题、摘要、封面和发布时间。
  const CreatorArticle({
    required this.id,
    required this.title,
    required this.summary,
    required this.coverUrl,
    this.publishedAt,
    this.viewCount = 0,
  });

  final int id;
  final String title;
  final String summary;
  final String coverUrl;
  final DateTime? publishedAt;
  final int viewCount;
}

/// 表示 UP 主公开创建的 UGC 合集及其少量预览视频。
class CreatorCollection {
  /// 创建合集卡片与详情页需要的元数据。
  const CreatorCollection({
    required this.id,
    required this.ownerMid,
    required this.title,
    required this.coverUrl,
    required this.description,
    required this.totalCount,
    required this.previewVideos,
    this.ownerName = '',
    this.ownerAvatarUrl = '',
  });

  final int id;
  final int ownerMid;
  final String ownerName;
  final String ownerAvatarUrl;
  final String title;
  final String coverUrl;
  final String description;
  final int totalCount;
  final List<CreatorVideo> previewVideos;
}

/// 保存公开内容的一页结果以及是否仍有下一页。
class CreatorContentPage<T> {
  /// 创建一页不可变内容，供主页和合集详情安全分页。
  const CreatorContentPage({
    required this.items,
    required this.page,
    required this.hasMore,
    this.totalCount,
  });

  final List<T> items;
  final int page;
  final bool hasMore;
  final int? totalCount;
}
