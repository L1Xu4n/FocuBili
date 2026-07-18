/// 定义用户搜索的排序方式，对应界面中的默认、粉丝数和等级排序。
enum UserSearchOrder {
  defaultOrder,
  fansDescending,
  fansAscending,
  levelDescending,
  levelAscending,
}

/// 定义用户搜索的账号类型筛选。
enum UserSearchType { all, uploader, normal, certified }

/// 保存用户搜索排序和账号类型筛选条件。
class UserSearchFilter {
  /// 创建用户筛选；默认按平台综合排序并显示全部用户。
  const UserSearchFilter({
    this.order = UserSearchOrder.defaultOrder,
    this.type = UserSearchType.all,
  });

  final UserSearchOrder order;
  final UserSearchType type;

  /// 返回替换指定字段后的新筛选对象。
  UserSearchFilter copyWith({UserSearchOrder? order, UserSearchType? type}) {
    return UserSearchFilter(
      order: order ?? this.order,
      type: type ?? this.type,
    );
  }
}

/// 表示用户搜索返回的一张公开用户卡片。
class UserSearchResult {
  /// 创建用户卡片所需的公开资料和统计。
  const UserSearchResult({
    required this.mid,
    required this.name,
    required this.avatarUrl,
    required this.signature,
    required this.followerCount,
    required this.videoCount,
    required this.level,
    required this.isUploader,
    required this.certification,
  });

  final int mid;
  final String name;
  final String avatarUrl;
  final String signature;
  final int followerCount;
  final int videoCount;
  final int level;
  final bool isUploader;
  final String certification;

  /// 判断该用户是否带有平台认证说明。
  bool get isCertified => certification.isNotEmpty;
}

/// 保存一页用户搜索结果和分页位置。
class UserSearchPage {
  /// 创建用户搜索分页对象。
  const UserSearchPage({
    required this.results,
    required this.page,
    required this.totalPages,
  });

  final List<UserSearchResult> results;
  final int page;
  final int totalPages;

  /// 判断是否还能继续加载下一页。
  bool get hasMore => page < totalPages;
}
