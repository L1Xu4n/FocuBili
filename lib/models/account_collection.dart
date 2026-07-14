/// 标识一次只读账号数据请求的最终状态，页面可据此区分空列表和失败。
enum AccountDataLoadStatus {
  /// 请求成功，items 可能为空但数据本身完整。
  success,

  /// 当前设备没有可用的 B 站登录会话。
  signedOut,

  /// 本机仍有 Cookie，但 B 站明确拒绝当前会话。
  expired,

  /// 网络、请求桥接或服务连接暂时不可用。
  networkError,

  /// 当前账号没有访问目标数据的权限。
  permissionDenied,

  /// 服务返回成功码但没有 data，不能误判为真正的空列表。
  missingData,

  /// 服务返回了非成功业务码，暂时无法读取账号数据。
  unavailable,

  /// 服务返回了无法安全解析的数据结构。
  malformedData,
}

/// 保存一页只读账号数据及其可展示的状态说明。
class AccountDataPage<T> {
  /// 创建一页不可变账号数据，供各个命名构造方法统一复用。
  AccountDataPage._({
    required this.status,
    required List<T> items,
    required this.page,
    required this.hasMore,
    this.totalCount,
    this.message,
  }) : items = List<T>.unmodifiable(items);

  /// 创建一次成功请求结果；空 items 仍代表“确实没有数据”。
  factory AccountDataPage.success({
    required List<T> items,
    required int page,
    required bool hasMore,
    int? totalCount,
  }) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.success,
      items: items,
      page: page,
      hasMore: hasMore,
      totalCount: totalCount,
    );
  }

  /// 创建没有登录会话时的结果，避免调用方把它展示成空列表。
  factory AccountDataPage.signedOut({int page = 1}) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.signedOut,
      items: <T>[],
      page: page,
      hasMore: false,
      message: '请先登录后查看。',
    );
  }

  /// 创建 B 站明确判定会话失效时的结果，不会主动清理 Cookie。
  factory AccountDataPage.expired({int page = 1}) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.expired,
      items: <T>[],
      page: page,
      hasMore: false,
      message: '登录已过期，请重新登录。',
    );
  }

  /// 创建网络暂时不可用时的结果，页面应保留此前已显示的数据。
  factory AccountDataPage.networkError({
    int page = 1,
    String message = '网络暂时不可用，请检查网络后重试。',
  }) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.networkError,
      items: <T>[],
      page: page,
      hasMore: false,
      message: message,
    );
  }

  /// 创建服务拒绝当前账号访问时的结果，不把权限问题误判为会话过期。
  factory AccountDataPage.permissionDenied({int page = 1}) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.permissionDenied,
      items: <T>[],
      page: page,
      hasMore: false,
      message: 'B站拒绝访问此数据。',
    );
  }

  /// 创建成功码却缺少 data 时的结果，避免错误显示“暂无内容”。
  factory AccountDataPage.missingData({int page = 1}) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.missingData,
      items: <T>[],
      page: page,
      hasMore: false,
      message: 'B站没有返回可用数据，请稍后重试。',
    );
  }

  /// 创建服务器业务错误时的结果，不向界面透传可能不稳定的原始响应。
  factory AccountDataPage.unavailable({
    int page = 1,
    String message = '账号数据服务暂时不可用，请稍后重试。',
  }) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.unavailable,
      items: <T>[],
      page: page,
      hasMore: false,
      message: message,
    );
  }

  /// 创建 JSON 结构无法安全解析时的结果，不把异常数据填入用户页面。
  factory AccountDataPage.malformedData({int page = 1}) {
    return AccountDataPage<T>._(
      status: AccountDataLoadStatus.malformedData,
      items: <T>[],
      page: page,
      hasMore: false,
      message: '返回的数据格式不正确，请稍后重试。',
    );
  }

  /// 本次请求状态，用于驱动登录、权限、重试或正常列表界面。
  final AccountDataLoadStatus status;

  /// 已安全解析的不可变列表，失败时固定为空。
  final List<T> items;

  /// 这批数据对应的服务端页码；收藏夹总列表固定为第 1 页。
  final int page;

  /// 是否仍可继续请求下一页；只有成功结果才可能为 true。
  final bool hasMore;

  /// 服务端给出的总数；未知时为 null，不能用作下一页判断的唯一依据。
  final int? totalCount;

  /// 可直接展示的安全说明，不包含 Cookie、请求头或原始响应正文。
  final String? message;

  /// 判断本次请求是否已获得可用数据，即使 items 为空也返回 true。
  bool get isSuccess => status == AccountDataLoadStatus.success;

  /// 判断服务明确返回了一个真正的空列表，而不是登录或网络失败。
  bool get isEmpty => isSuccess && items.isEmpty;
}

/// 表示用户创建的一个 B 站收藏夹，保留进入内容页所需的最小信息。
class FavoriteFolder {
  /// 创建包含收藏夹编号、名称、封面和内容数的只读收藏夹资料。
  const FavoriteFolder({
    required this.mediaId,
    required this.title,
    required this.coverUrl,
    required this.mediaCount,
    required this.isAvailable,
  });

  /// 收藏夹的完整 media_id，读取内容时必须使用此字段。
  final int mediaId;

  /// 收藏夹标题，仅用于当前页面展示。
  final String title;

  /// 收藏夹封面 HTTPS 地址；服务未给出安全地址时为空字符串。
  final String coverUrl;

  /// 服务端提供的内容数量，可能与当前能播放的项目数量不同。
  final int mediaCount;

  /// 标记收藏夹是否处于正常可读取状态，失效夹仍可由页面说明原因。
  final bool isAvailable;
}

/// 表示收藏夹中的一个视频条目，不包含播放地址或任何登录资料。
class FavoriteVideo {
  /// 创建包含进入公开视频详情所需 BV 号的收藏视频资料。
  const FavoriteVideo({
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.ownerName,
    required this.duration,
    required this.partCount,
    required this.favoritedAt,
    required this.playCount,
    required this.danmakuCount,
    required this.isAvailable,
  });

  /// 视频 BV 号；页面点击后应通过公开详情接口补齐 cid 和完整分P。
  final String bvid;

  /// 视频标题，仅用于列表展示。
  final String title;

  /// 视频封面 HTTPS 地址；无法确认安全地址时为空字符串。
  final String coverUrl;

  /// 视频作者昵称。
  final String ownerName;

  /// 服务端给出的总时长，未知时为零时长。
  final Duration duration;

  /// 视频分P数量，最小为 1。
  final int partCount;

  /// 最近一次被收藏的时间；服务未给出时为 null。
  final DateTime? favoritedAt;

  /// 服务端给出的播放数，无法识别时为 0。
  final int playCount;

  /// 服务端给出的弹幕数，无法识别时为 0。
  final int danmakuCount;

  /// 视频是否仍可播放；失效项保留给页面显示但不应直接进入播放器。
  final bool isAvailable;
}

/// 表示当前账号已关注的一位 UP 主，不包含会话 Cookie 或可写关系状态。
class FollowedCreator {
  /// 创建包含 UP 主编号、昵称、头像和简介的只读关注资料。
  const FollowedCreator({
    required this.mid,
    required this.name,
    required this.avatarUrl,
    required this.sign,
    required this.officialDescription,
    required this.followedAt,
  });

  /// UP 主 mid，可用于后续打开官方空间页，但本模型不执行网络请求。
  final int mid;

  /// UP 主昵称。
  final String name;

  /// UP 主头像 HTTPS 地址；无安全地址时为空字符串。
  final String avatarUrl;

  /// UP 主个性签名，可能为空。
  final String sign;

  /// B 站官方认证说明，未认证时为空。
  final String officialDescription;

  /// 关注时间，服务未给出或无法解析时为 null。
  final DateTime? followedAt;
}

/// 表示当前账号订阅的一项 UGC 合集，不与关注的 UP 主混在同一列表。
class SubscribedCollection {
  /// 创建订阅合集卡片需要的编号、封面、作者和视频数量。
  const SubscribedCollection({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.description,
    required this.ownerMid,
    required this.ownerName,
    required this.ownerAvatarUrl,
    required this.videoCount,
    required this.viewCount,
  });

  final int id;
  final String title;
  final String coverUrl;
  final String description;
  final int ownerMid;
  final String ownerName;
  final String ownerAvatarUrl;
  final int videoCount;
  final int viewCount;
}
