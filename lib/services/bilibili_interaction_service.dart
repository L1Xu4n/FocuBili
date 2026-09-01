import 'dart:convert';
import 'dart:io';

import 'bilibili_auth_service.dart';

/// 保存一次 B 站互动接口的 HTTP 状态和 JSON 正文，测试时可替换真实网络。
class BilibiliInteractionResponse {
  /// 创建一条不携带 Cookie 的可测试响应对象。
  const BilibiliInteractionResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

/// 定义互动服务使用的 GET/POST 请求函数，避免单元测试访问真实账号接口。
typedef BilibiliInteractionRequest =
    Future<BilibiliInteractionResponse> Function(
      Uri endpoint, {
      required String cookieHeader,
      String? body,
    });

/// 生成与 B站网页写操作一致的请求头，供正式请求和单元测试共用同一套约束。
Map<String, String> buildBilibiliInteractionRequestHeaders({
  required String cookieHeader,
  required bool hasBody,
}) {
  return <String, String>{
    HttpHeaders.acceptHeader: 'application/json',
    HttpHeaders.cookieHeader: cookieHeader,
    HttpHeaders.userAgentHeader:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Safari/537.36',
    HttpHeaders.refererHeader: 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
    if (hasBody)
      HttpHeaders.contentTypeHeader:
          'application/x-www-form-urlencoded; charset=utf-8',
  };
}

/// 保存视频和作者的当前互动状态，页面据此显示可重复点击的操作按钮。
class BilibiliInteractionState {
  /// 创建关注、点赞、投币和收藏状态快照。
  const BilibiliInteractionState({
    this.isFollowing = false,
    this.isLiked = false,
    this.coinCount = 0,
    this.isFavorited = false,
    this.favoriteMediaId,
    this.favoriteMediaIds = const <int>{},
  });

  final bool isFollowing;
  final bool isLiked;
  final int coinCount;
  final bool isFavorited;
  final int? favoriteMediaId;
  final Set<int> favoriteMediaIds;

  /// 判断当前账号是否已经给这支视频投过至少一枚硬币。
  bool get isCoined => coinCount > 0;

  /// 返回只替换指定互动状态的新快照，避免页面更新时丢失收藏夹编号。
  BilibiliInteractionState copyWith({
    bool? isFollowing,
    bool? isLiked,
    int? coinCount,
    bool? isFavorited,
    int? favoriteMediaId,
    Set<int>? favoriteMediaIds,
    bool clearFavoriteMediaId = false,
    bool clearFavoriteMediaIds = false,
  }) {
    return BilibiliInteractionState(
      isFollowing: isFollowing ?? this.isFollowing,
      isLiked: isLiked ?? this.isLiked,
      coinCount: coinCount ?? this.coinCount,
      isFavorited: isFavorited ?? this.isFavorited,
      favoriteMediaId: clearFavoriteMediaId
          ? null
          : favoriteMediaId ?? this.favoriteMediaId,
      favoriteMediaIds: clearFavoriteMediaIds
          ? const <int>{}
          : favoriteMediaIds ?? this.favoriteMediaIds,
    );
  }
}

/// 保存收藏夹选择面板需要的编号、名称、数量和当前视频收藏状态。
class BilibiliFavoriteFolder {
  /// 创建一条来自当前登录账号的收藏夹摘要。
  const BilibiliFavoriteFolder({
    required this.mediaId,
    required this.title,
    this.mediaCount = 0,
    this.containsVideo = false,
  });

  final int mediaId;
  final String title;
  final int mediaCount;
  final bool containsVideo;
}

/// 表示互动请求失败；消息不包含 Cookie、账号或请求正文。
class BilibiliInteractionException implements Exception {
  /// 创建一条可以直接显示给普通用户的互动错误。
  const BilibiliInteractionException(this.message);

  final String message;

  /// 返回稳定错误文字，避免把底层响应正文泄露到界面。
  @override
  String toString() => message;
}

/// 接入 B 站关注、点赞、投币和收藏接口，并严格复用已验证登录会话。
class BilibiliInteractionService {
  /// 创建互动服务；测试可以注入会话服务和固定请求函数。
  BilibiliInteractionService({
    BilibiliAuthService? authService,
    BilibiliInteractionRequest? request,
  }) : _authService = authService ?? BilibiliAuthService(),
       _request = request ?? _requestDefault;

  static const String _apiHost = 'api.bilibili.com';
  static final RegExp _csrfPattern = RegExp(
    r'(^|;\s*)bili_jct=([^;]+)',
    caseSensitive: false,
  );

  final BilibiliAuthService _authService;
  final BilibiliInteractionRequest _request;

  /// 读取视频和作者当前状态，单个可选状态接口失败时保留其他已成功状态。
  Future<BilibiliInteractionState> loadVideoState({
    required String bvid,
    required int aid,
    required int ownerMid,
  }) async {
    final _InteractionSession session = await _openSession();
    bool isFollowing = false;
    bool isLiked = false;
    int coinCount = 0;
    bool isFavorited = false;
    int? favoriteMediaId;
    final Set<int> favoriteMediaIds = <int>{};
    if (ownerMid > 0) {
      final Map<Object?, Object?>? data = await _tryGetData(
        Uri.https(_apiHost, '/x/relation', <String, String>{
          'fid': ownerMid.toString(),
        }),
        session,
      );
      if (data != null) {
        isFollowing = _isFollowingAttribute(data['attribute']);
      }
    }
    if (bvid.trim().isNotEmpty) {
      final Object? likeData = await _tryGetRawData(
        Uri.https(
          _apiHost,
          '/x/web-interface/archive/has/like',
          <String, String>{'bvid': bvid.trim()},
        ),
        session,
      );
      if (likeData != null) {
        isLiked = likeData is Map
            ? _readBool(likeData['data'] ?? likeData['like'])
            : _readBool(likeData);
      }
      final Map<Object?, Object?>? coinData = await _tryGetData(
        Uri.https(_apiHost, '/x/web-interface/archive/coins', <String, String>{
          'bvid': bvid.trim(),
        }),
        session,
      );
      if (coinData != null) {
        coinCount = _readInteger(
          coinData['multiply'] ?? coinData['number'],
        ).clamp(0, 2);
      }
    }
    if (aid > 0) {
      final Map<Object?, Object?>? favoriteData = await _tryGetData(
        Uri.https(_apiHost, '/x/v3/fav/resource/has', <String, String>{
          'rid': aid.toString(),
          'type': '2',
        }),
        session,
      );
      if (favoriteData != null) {
        isFavorited = _readFavoriteState(favoriteData);
        final int responseMediaId = _readPositiveInteger(
          favoriteData['media_id'] ?? favoriteData['mediaId'],
        );
        if (responseMediaId > 0) {
          favoriteMediaId = responseMediaId;
          favoriteMediaIds.add(responseMediaId);
        }
      }
      final Map<Object?, Object?>? folderData = await _tryGetData(
        _favoriteFolderEndpoint(session: session, aid: aid),
        session,
      );
      if (folderData != null) {
        favoriteMediaIds.addAll(_findFavoriteMediaIds(folderData['list']));
        favoriteMediaId ??= _findFavoriteMediaId(
          folderData['list'],
          requireContainingVideo: true,
        );
        isFavorited = isFavorited || favoriteMediaIds.isNotEmpty;
      }
    }
    return BilibiliInteractionState(
      isFollowing: isFollowing,
      isLiked: isLiked,
      coinCount: coinCount,
      isFavorited: isFavorited,
      favoriteMediaId: favoriteMediaId,
      favoriteMediaIds: Set<int>.unmodifiable(favoriteMediaIds),
    );
  }

  /// 读取指定 UP 主的关注状态，未登录或接口失败时抛出可展示的互动异常。
  Future<bool> loadFollowingState(int mid) async {
    if (mid <= 0) {
      return false;
    }
    final _InteractionSession session = await _openSession();
    final Map<Object?, Object?> data = await _getData(
      Uri.https(_apiHost, '/x/relation', <String, String>{
        'fid': mid.toString(),
      }),
      session,
    );
    return _isFollowingAttribute(data['attribute']);
  }

  /// 关注或取消关注指定 UP 主，并在官方接口成功后返回。
  Future<void> setFollowing({required int mid, required bool following}) async {
    if (mid <= 0) {
      throw const BilibiliInteractionException('UP 主编号无效，无法修改关注状态。');
    }
    final _InteractionSession session = await _openSession();
    await _postData(
      Uri.https(_apiHost, '/x/relation/modify'),
      session,
      <String, String>{
        'fid': mid.toString(),
        'act': following ? '1' : '2',
        're_src': '11',
      },
    );
  }

  /// 点赞或取消点赞指定视频，并在官方接口成功后返回。
  Future<void> setLiked({required int aid, required bool liked}) async {
    if (aid <= 0) {
      throw const BilibiliInteractionException('视频编号无效，无法修改点赞状态。');
    }
    final _InteractionSession session = await _openSession();
    await _postData(
      Uri.https(_apiHost, '/x/web-interface/archive/like'),
      session,
      <String, String>{'aid': aid.toString(), 'like': liked ? '1' : '2'},
    );
  }

  /// 为指定视频投一枚或两枚硬币，数量以用户在弹窗中的选择为准。
  Future<void> addCoin({required int aid, int multiply = 1}) async {
    if (aid <= 0) {
      throw const BilibiliInteractionException('视频编号无效，无法投币。');
    }
    if (multiply != 1 && multiply != 2) {
      throw const BilibiliInteractionException('每次只能投 1 枚或 2 枚硬币。');
    }
    final _InteractionSession session = await _openSession();
    await _postData(
      Uri.https(_apiHost, '/x/web-interface/coin/add'),
      session,
      <String, String>{
        'aid': aid.toString(),
        'multiply': multiply.toString(),
        'select_like': '0',
      },
    );
  }

  /// 读取当前账号的收藏夹，并标记哪些收藏夹已经包含这支视频。
  Future<List<BilibiliFavoriteFolder>> loadFavoriteFolders({
    required int aid,
  }) async {
    if (aid <= 0) {
      throw const BilibiliInteractionException('视频编号无效，无法读取收藏夹。');
    }
    final _InteractionSession session = await _openSession();
    final Map<Object?, Object?> data = await _getData(
      _favoriteFolderEndpoint(session: session, aid: aid),
      session,
    );
    return _parseFavoriteFolders(data['list']);
  }

  /// 创建一个公开收藏夹，并返回可立即用于收藏当前视频的目录摘要。
  Future<BilibiliFavoriteFolder> createFavoriteFolder({
    required String title,
  }) async {
    final String normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw const BilibiliInteractionException('收藏夹名称不能为空。');
    }
    final _InteractionSession session = await _openSession();
    final Map<Object?, Object?> data = await _postData(
      Uri.https(_apiHost, '/x/v3/fav/folder/add'),
      session,
      <String, String>{
        'title': normalizedTitle,
        'intro': '',
        'privacy': '0',
        'cover': '',
      },
    );
    final int mediaId = _readPositiveInteger(data['id'] ?? data['fid']);
    if (mediaId <= 0) {
      throw const BilibiliInteractionException('收藏夹已创建，但没有返回可用编号，请重新打开列表。');
    }
    return BilibiliFavoriteFolder(mediaId: mediaId, title: normalizedTitle);
  }

  /// 把视频加入或移出用户明确选择的单个收藏夹。
  Future<void> setFavoriteFolder({
    required int aid,
    required int mediaId,
    required bool favorited,
  }) async {
    if (aid <= 0 || mediaId <= 0) {
      throw const BilibiliInteractionException('视频或收藏夹编号无效，无法修改收藏状态。');
    }
    await setFavoriteFolders(
      aid: aid,
      addMediaIds: favorited ? <int>[mediaId] : const <int>[],
      deleteMediaIds: favorited ? const <int>[] : <int>[mediaId],
    );
  }

  /// 在一次官方请求中把视频加入多个收藏夹并从多个收藏夹移除。
  Future<void> setFavoriteFolders({
    required int aid,
    Iterable<int> addMediaIds = const <int>[],
    Iterable<int> deleteMediaIds = const <int>[],
  }) async {
    if (aid <= 0) {
      throw const BilibiliInteractionException('视频编号无效，无法修改收藏状态。');
    }
    final Set<int> additions = addMediaIds.where((int id) => id > 0).toSet();
    final Set<int> deletions = deleteMediaIds.where((int id) => id > 0).toSet()
      ..removeAll(additions);
    if (additions.isEmpty && deletions.isEmpty) {
      return;
    }
    final _InteractionSession session = await _openSession();
    await _setFavoriteFolders(
      session,
      aid: aid,
      addMediaIds: additions,
      deleteMediaIds: deletions,
    );
  }

  /// 把视频加入或移出当前账号的第一个可用收藏夹。
  Future<void> setFavorited({
    required int aid,
    required bool favorited,
    int? mediaId,
  }) async {
    if (aid <= 0) {
      throw const BilibiliInteractionException('视频编号无效，无法修改收藏状态。');
    }
    final _InteractionSession session = await _openSession();
    final int folderId =
        mediaId ??
        await _loadFavoriteMediaId(
          session,
          aid: aid,
          requireContainingVideo: !favorited,
        );
    await _setFavoriteFolders(
      session,
      aid: aid,
      addMediaIds: favorited ? <int>[folderId] : const <int>[],
      deleteMediaIds: favorited ? const <int>[] : <int>[folderId],
    );
  }

  /// 使用已打开会话提交多个收藏夹变更，避免兼容入口重复读取账号状态。
  Future<void> _setFavoriteFolders(
    _InteractionSession session, {
    required int aid,
    required Iterable<int> addMediaIds,
    required Iterable<int> deleteMediaIds,
  }) async {
    await _postData(
      Uri.https(_apiHost, '/x/v3/fav/resource/deal'),
      session,
      <String, String>{
        'rid': aid.toString(),
        'type': '2',
        'add_media_ids': addMediaIds.join(','),
        'del_media_ids': deleteMediaIds.join(','),
        'platform': 'web',
      },
    );
  }

  /// 打开已验证会话并提取 CSRF；未登录或 Cookie 不完整时不发起写请求。
  Future<_InteractionSession> _openSession() async {
    final BilibiliSessionState state = await _authService.loadCurrentSession();
    if (!state.isActive) {
      throw const BilibiliInteractionException('请先登录 B 站后再执行此操作。');
    }
    final String cookieHeader = (await _authService.readCookieHeader()).trim();
    final RegExpMatch? csrfMatch = _csrfPattern.firstMatch(cookieHeader);
    final String csrf = csrfMatch == null
        ? ''
        : Uri.decodeComponent(csrfMatch.group(2)!.trim());
    if (csrf.isEmpty) {
      throw const BilibiliInteractionException('当前登录会话缺少安全校验信息，请重新登录。');
    }
    return _InteractionSession(
      cookieHeader: cookieHeader,
      csrf: csrf,
      accountMid: state.account!.mid,
    );
  }

  /// 读取可用收藏夹编号；取消收藏时优先选择当前确实包含该视频的目录。
  Future<int> _loadFavoriteMediaId(
    _InteractionSession session, {
    required int aid,
    required bool requireContainingVideo,
  }) async {
    final Map<Object?, Object?> data = await _getData(
      _favoriteFolderEndpoint(session: session, aid: aid),
      session,
    );
    final int? mediaId = _findFavoriteMediaId(
      data['list'],
      requireContainingVideo: requireContainingVideo,
    );
    if (mediaId != null) {
      return mediaId;
    }
    throw BilibiliInteractionException(
      requireContainingVideo ? '没有找到包含该视频的收藏夹，无法取消收藏。' : '当前账号没有可用收藏夹，无法收藏视频。',
    );
  }

  /// 生成收藏夹查询地址，并携带当前账号、视频和资源类型以返回准确的收藏状态。
  Uri _favoriteFolderEndpoint({
    required _InteractionSession session,
    required int aid,
  }) {
    return Uri.https(
      _apiHost,
      '/x/v3/fav/folder/created/list-all',
      <String, String>{
        'up_mid': session.accountMid.toString(),
        'type': '2',
        'rid': aid.toString(),
      },
    );
  }

  /// 从收藏夹列表中选择目录；需要取消收藏时只接受 `fav_state` 为真的目录。
  int? _findFavoriteMediaId(
    Object? rawList, {
    required bool requireContainingVideo,
  }) {
    if (rawList is! List) {
      return null;
    }
    int? firstAvailable;
    for (final Object? rawItem in rawList) {
      if (rawItem is! Map) {
        continue;
      }
      final int mediaId = _readPositiveInteger(rawItem['id']);
      if (mediaId <= 0) {
        continue;
      }
      firstAvailable ??= mediaId;
      if (_readBool(rawItem['fav_state'] ?? rawItem['favState'])) {
        return mediaId;
      }
    }
    return requireContainingVideo ? null : firstAvailable;
  }

  /// 收集所有实际包含当前视频的收藏夹编号，供多选面板预先勾选。
  Set<int> _findFavoriteMediaIds(Object? rawList) {
    if (rawList is! List) {
      return const <int>{};
    }
    final Set<int> mediaIds = <int>{};
    for (final Object? rawItem in rawList) {
      if (rawItem is! Map ||
          !_readBool(rawItem['fav_state'] ?? rawItem['favState'])) {
        continue;
      }
      final int mediaId = _readPositiveInteger(rawItem['id']);
      if (mediaId > 0) {
        mediaIds.add(mediaId);
      }
    }
    return Set<int>.unmodifiable(mediaIds);
  }

  /// 把收藏夹接口数组转换为可展示列表，并过滤缺少有效编号的异常条目。
  List<BilibiliFavoriteFolder> _parseFavoriteFolders(Object? rawList) {
    if (rawList is! List) {
      return const <BilibiliFavoriteFolder>[];
    }
    final List<BilibiliFavoriteFolder> folders = <BilibiliFavoriteFolder>[];
    for (final Object? rawItem in rawList) {
      if (rawItem is! Map) {
        continue;
      }
      final int mediaId = _readPositiveInteger(rawItem['id']);
      if (mediaId <= 0) {
        continue;
      }
      final String title = rawItem['title']?.toString().trim() ?? '';
      folders.add(
        BilibiliFavoriteFolder(
          mediaId: mediaId,
          title: title.isEmpty ? '未命名收藏夹' : title,
          mediaCount: _readInteger(
            rawItem['media_count'] ?? rawItem['mediaCount'],
          ).clamp(0, 1 << 31),
          containsVideo: _readBool(rawItem['fav_state'] ?? rawItem['favState']),
        ),
      );
    }
    return List<BilibiliFavoriteFolder>.unmodifiable(folders);
  }

  /// 请求 GET 接口并返回成功 data 对象，统一处理 B 站业务错误码。
  Future<Map<Object?, Object?>> _getData(
    Uri endpoint,
    _InteractionSession session,
  ) async {
    final Object? rawData = await _getRawData(endpoint, session);
    return rawData is Map
        ? Map<Object?, Object?>.from(rawData)
        : const <Object?, Object?>{};
  }

  /// 请求 GET 接口并保留 data 的原始类型，兼容布尔型状态响应。
  Future<Object?> _getRawData(Uri endpoint, _InteractionSession session) async {
    final BilibiliInteractionResponse response = await _request(
      endpoint,
      cookieHeader: session.cookieHeader,
    );
    return _parseData(response);
  }

  /// 尝试读取可选 GET 状态；单个接口失败时返回空值，让其他状态继续加载。
  Future<Object?> _tryGetRawData(
    Uri endpoint,
    _InteractionSession session,
  ) async {
    try {
      return await _getRawData(endpoint, session);
    } on BilibiliInteractionException {
      return null;
    }
  }

  /// 尝试读取可选 GET 对象；响应缺失或失败时返回空值而不是中断整个状态快照。
  Future<Map<Object?, Object?>?> _tryGetData(
    Uri endpoint,
    _InteractionSession session,
  ) async {
    final Object? rawData = await _tryGetRawData(endpoint, session);
    return rawData is Map ? Map<Object?, Object?>.from(rawData) : null;
  }

  /// 请求 POST 接口并自动附加 csrf 与 csrf_token 字段。
  Future<Map<Object?, Object?>> _postData(
    Uri endpoint,
    _InteractionSession session,
    Map<String, String> fields,
  ) async {
    final Map<String, String> payload = <String, String>{
      ...fields,
      'csrf': session.csrf,
      'csrf_token': session.csrf,
    };
    final BilibiliInteractionResponse response = await _request(
      endpoint,
      cookieHeader: session.cookieHeader,
      body: Uri(queryParameters: payload).query,
    );
    final Object? rawData = _parseData(response);
    return rawData is Map
        ? Map<Object?, Object?>.from(rawData)
        : const <Object?, Object?>{};
  }

  /// 校验 HTTP 和业务响应，只把稳定错误文字交给界面。
  Object? _parseData(BilibiliInteractionResponse response) {
    if (response.statusCode != HttpStatus.ok) {
      throw BilibiliInteractionException(
        'B 站互动服务暂时不可用（HTTP ${response.statusCode}）。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const BilibiliInteractionException('B 站互动响应无法解析，请稍后重试。');
    }
    if (decoded is! Map) {
      throw const BilibiliInteractionException('B 站互动响应格式不正确，请稍后重试。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = _readInteger(root['code']);
    if (code != 0) {
      if (code == -101) {
        throw const BilibiliInteractionException('登录已过期，请重新登录后再试。');
      }
      final String message = root['message'] is String
          ? (root['message'] as String).trim()
          : '';
      throw BilibiliInteractionException(
        message.isEmpty ? 'B 站拒绝了这次操作（错误码：$code）。' : message,
      );
    }
    return root['data'];
  }

  /// 把 B 站的布尔、数字和字符串状态统一解析为布尔值。
  bool _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    return value?.toString().trim().toLowerCase() == 'true' ||
        value?.toString().trim() == '1';
  }

  /// 读取关系接口的 attribute；2 表示已关注，6 表示双方互相关注。
  bool _isFollowingAttribute(Object? value) {
    final int attribute = _readInteger(value);
    return attribute == 2 || attribute == 6;
  }

  /// 兼容收藏状态接口的 count、favoured 和 favorited 三种返回字段。
  bool _readFavoriteState(Map<Object?, Object?> data) {
    if (_readInteger(data['count']) > 0) {
      return true;
    }
    return _readBool(data['favoured'] ?? data['favorited']);
  }

  /// 把接口中的数字或数字字符串解析为整数，异常值回退为零。
  int _readInteger(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString().trim() ?? '') ?? 0;
  }

  /// 读取必须大于零的收藏夹编号，避免向写接口发送默认零值。
  int _readPositiveInteger(Object? value) {
    final int number = _readInteger(value);
    return number > 0 ? number : 0;
  }

  /// 使用 HttpClient 发送带 Cookie 的 JSON GET 或表单 POST 请求。
  static Future<BilibiliInteractionResponse> _requestDefault(
    Uri endpoint, {
    required String cookieHeader,
    String? body,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = body == null
          ? await client.getUrl(endpoint)
          : await client.postUrl(endpoint);
      final Map<String, String> headers =
          buildBilibiliInteractionRequestHeaders(
            cookieHeader: cookieHeader,
            hasBody: body != null,
          );
      for (final MapEntry<String, String> header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        request.write(body);
      }
      final HttpClientResponse response = await request.close();
      return BilibiliInteractionResponse(
        statusCode: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
      );
    } on SocketException {
      throw const BilibiliInteractionException('无法连接 B 站互动服务，请检查网络后重试。');
    } on HttpException {
      throw const BilibiliInteractionException('B 站互动网络响应异常，请稍后重试。');
    } finally {
      client.close(force: true);
    }
  }
}

/// 保存互动请求期间临时使用的 Cookie 和 CSRF，不向页面模型暴露具体值。
class _InteractionSession {
  /// 创建一次仅存在于当前异步调用链中的会话上下文。
  const _InteractionSession({
    required this.cookieHeader,
    required this.csrf,
    required this.accountMid,
  });

  final String cookieHeader;
  final String csrf;
  final int accountMid;
}
