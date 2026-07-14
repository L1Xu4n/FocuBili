import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/account_collection.dart';
import 'bilibili_auth_service.dart';

/// 保存一次账号数据 HTTP 请求的状态码和正文，方便网络层与解析层独立测试。
class BilibiliAccountDataResponse {
  /// 创建不含 Cookie 或请求头的账号数据响应对象。
  const BilibiliAccountDataResponse({
    required this.statusCode,
    required this.body,
  });

  /// HTTP 状态码，仅用于把授权、权限和服务故障区分开。
  final int statusCode;

  /// 服务返回的 JSON 正文，业务层解析后不会把它作为日志输出。
  final String body;
}

/// 抽象账号数据的只读 GET 请求，测试时可替换为不访问网络的假实现。
abstract interface class BilibiliAccountDataApi {
  /// 使用当前会话临时读取一个固定账号数据地址，不执行任何写操作。
  Future<BilibiliAccountDataResponse> get(
    Uri endpoint,
    String cookieHeader,
  );
}

/// 使用 Dart HttpClient 请求 B 站只读账号数据接口的默认网络实现。
class BilibiliHttpAccountDataApi implements BilibiliAccountDataApi {
  /// 创建网络客户端；测试可提供受控的 HttpClient 工厂。
  BilibiliHttpAccountDataApi({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  final HttpClient Function() _clientFactory;

  /// 为固定 B 站 API 附加临时 Cookie、来源页和浏览器标识后发起只读 GET。
  @override
  Future<BilibiliAccountDataResponse> get(
    Uri endpoint,
    String cookieHeader,
  ) async {
    final HttpClient client = _clientFactory();
    try {
      final HttpClientRequest request =
          await client.getUrl(endpoint).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      final HttpClientResponse response = await request.close().timeout(
            const Duration(seconds: 15),
          );
      return BilibiliAccountDataResponse(
        statusCode: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// 抽象当前账号会话的只读能力，使账号数据服务不依赖登录页面或 Cookie 存储细节。
abstract interface class BilibiliAccountSessionProvider {
  /// 验证并返回当前 WebView 会话状态，不会自动清除 Cookie。
  Future<BilibiliSessionState> loadCurrentSession();

  /// 只在账号数据请求进行时读取一次临时 Cookie 请求头。
  Future<String> readCookieHeader();
}

/// 把现有 BilibiliAuthService 适配为账号数据服务的默认安全会话来源。
class AuthBackedAccountSessionProvider
    implements BilibiliAccountSessionProvider {
  /// 创建复用现有官方网页登录会话的适配器，不保存 Cookie 副本。
  AuthBackedAccountSessionProvider({BilibiliAuthService? authService})
      : _authService = authService ?? BilibiliAuthService();

  final BilibiliAuthService _authService;

  /// 复用登录服务对 signedOut、expired 与 networkError 的明确判断。
  @override
  Future<BilibiliSessionState> loadCurrentSession() {
    return _authService.loadCurrentSession();
  }

  /// 按需读取 Android WebView 的 B 站 Cookie，不写入 Flutter 本地存储。
  @override
  Future<String> readCookieHeader() {
    return _authService.readCookieHeader();
  }
}

/// 读取收藏夹、收藏内容和已关注 UP 主的只读服务，不包含任何账号写操作。
class BilibiliAccountDataService {
  /// 创建账号数据服务；默认只接入现有官方网页登录 Cookie 会话。
  BilibiliAccountDataService({
    BilibiliAccountSessionProvider? sessionProvider,
    BilibiliAccountDataApi? api,
  })  : _sessionProvider =
            sessionProvider ?? AuthBackedAccountSessionProvider(),
        _api = api ?? BilibiliHttpAccountDataApi();

  static const String _apiHost = 'api.bilibili.com';
  static const String _favoriteFoldersPath =
      '/x/v3/fav/folder/created/list-all';
  static const String _favoriteResourcesPath = '/x/v3/fav/resource/list';
  static const String _followingsPath = '/x/relation/followings';
  static final RegExp _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');
  static final RegExp _sessionCookiePattern = RegExp(
    r'(^|;\s*)SESSDATA=([^;]+)',
    caseSensitive: false,
  );

  final BilibiliAccountSessionProvider _sessionProvider;
  final BilibiliAccountDataApi _api;

  /// 读取当前已登录账号自己创建的收藏夹，不会读取其他账号或执行收藏操作。
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async {
    final _AccountReadSession session = await _openReadSession();
    final AccountDataPage<FavoriteFolder>? sessionFailure =
        _sessionFailurePage<FavoriteFolder>(session, page: 1);
    if (sessionFailure != null) {
      return sessionFailure;
    }
    final Uri endpoint = Uri.https(
      _apiHost,
      _favoriteFoldersPath,
      <String, String>{'up_mid': session.account!.mid.toString()},
    );
    final _AccountApiResult response = await _request(endpoint, session);
    final AccountDataPage<FavoriteFolder>? responseFailure =
        _responseFailurePage<FavoriteFolder>(response, page: 1);
    if (responseFailure != null) {
      return responseFailure;
    }
    final Map<Object?, Object?>? data = _asObject(response.root!['data']);
    if (data == null) {
      return AccountDataPage<FavoriteFolder>.missingData();
    }
    final Object? rawList = data['list'];
    if (rawList is! List) {
      return AccountDataPage<FavoriteFolder>.malformedData();
    }
    final List<FavoriteFolder> folders = <FavoriteFolder>[];
    for (final Object? item in rawList) {
      final FavoriteFolder? folder = _parseFavoriteFolder(item);
      if (folder != null) {
        folders.add(folder);
      }
    }
    final int? count = _readNonNegativeInt(data['count']);
    return AccountDataPage<FavoriteFolder>.success(
      items: folders,
      page: 1,
      hasMore: false,
      totalCount: count ?? folders.length,
    );
  }

  /// 分页读取一个收藏夹的视频条目；失效条目会保留但明确标记为不可播放。
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) async {
    final int safePage = _safePage(page);
    if (mediaId <= 0) {
      return AccountDataPage<FavoriteVideo>.unavailable(
        page: safePage,
        message: '收藏夹编号不正确，请返回后重试。',
      );
    }
    final _AccountReadSession session = await _openReadSession();
    final AccountDataPage<FavoriteVideo>? sessionFailure =
        _sessionFailurePage<FavoriteVideo>(session, page: safePage);
    if (sessionFailure != null) {
      return sessionFailure;
    }
    final Uri endpoint = Uri.https(
      _apiHost,
      _favoriteResourcesPath,
      <String, String>{
        'media_id': mediaId.toString(),
        'platform': 'web',
        'pn': safePage.toString(),
        'ps': '20',
        'order': 'mtime',
        'type': '0',
        'tid': '0',
      },
    );
    final _AccountApiResult response = await _request(endpoint, session);
    final AccountDataPage<FavoriteVideo>? responseFailure =
        _responseFailurePage<FavoriteVideo>(response, page: safePage);
    if (responseFailure != null) {
      return responseFailure;
    }
    final Map<Object?, Object?>? data = _asObject(response.root!['data']);
    if (data == null) {
      return AccountDataPage<FavoriteVideo>.missingData(page: safePage);
    }
    final Object? rawMedias = data['medias'];
    if (rawMedias != null && rawMedias is! List) {
      return AccountDataPage<FavoriteVideo>.malformedData(page: safePage);
    }
    final List<FavoriteVideo> videos = <FavoriteVideo>[];
    for (final Object? item in rawMedias as List? ?? const <Object?>[]) {
      final FavoriteVideo? video = _parseFavoriteVideo(item);
      if (video != null) {
        videos.add(video);
      }
    }
    return AccountDataPage<FavoriteVideo>.success(
      items: videos,
      page: safePage,
      hasMore: data['has_more'] == true,
      totalCount: _readNonNegativeInt(_asObject(data['info'])?['media_count']),
    );
  }

  /// 分页读取当前账号已关注的 UP 主；本功能不包含关注、取关或分组写操作。
  Future<AccountDataPage<FollowedCreator>> loadFollowedCreators({
    int page = 1,
  }) async {
    final int safePage = _safePage(page);
    final _AccountReadSession session = await _openReadSession();
    final AccountDataPage<FollowedCreator>? sessionFailure =
        _sessionFailurePage<FollowedCreator>(session, page: safePage);
    if (sessionFailure != null) {
      return sessionFailure;
    }
    final Uri endpoint = Uri.https(
      _apiHost,
      _followingsPath,
      <String, String>{
        'vmid': session.account!.mid.toString(),
        'pn': safePage.toString(),
        'ps': '50',
        'order': 'desc',
      },
    );
    final _AccountApiResult response = await _request(endpoint, session);
    final AccountDataPage<FollowedCreator>? responseFailure =
        _responseFailurePage<FollowedCreator>(response, page: safePage);
    if (responseFailure != null) {
      return responseFailure;
    }
    final Map<Object?, Object?>? data = _asObject(response.root!['data']);
    if (data == null) {
      return AccountDataPage<FollowedCreator>.missingData(page: safePage);
    }
    final Object? rawList = data['list'];
    if (rawList != null && rawList is! List) {
      return AccountDataPage<FollowedCreator>.malformedData(page: safePage);
    }
    final List<FollowedCreator> creators = <FollowedCreator>[];
    for (final Object? item in rawList as List? ?? const <Object?>[]) {
      final FollowedCreator? creator = _parseFollowedCreator(item);
      if (creator != null) {
        creators.add(creator);
      }
    }
    final int? totalCount = _readNonNegativeInt(data['total']);
    final bool hasMore =
        totalCount != null ? safePage * 50 < totalCount : creators.length == 50;
    return AccountDataPage<FollowedCreator>.success(
      items: creators,
      page: safePage,
      hasMore: hasMore,
      totalCount: totalCount,
    );
  }

  /// 检查现有会话后才读取临时 Cookie，确保无登录时绝不发起账号数据请求。
  Future<_AccountReadSession> _openReadSession() async {
    try {
      final BilibiliSessionState state =
          await _sessionProvider.loadCurrentSession();
      switch (state.status) {
        case BilibiliSessionStatus.signedOut:
          return const _AccountReadSession.signedOut();
        case BilibiliSessionStatus.expired:
          return const _AccountReadSession.expired();
        case BilibiliSessionStatus.networkError:
          return const _AccountReadSession.networkError();
        case BilibiliSessionStatus.active:
          final BilibiliAccount? account = state.account;
          if (account == null || account.mid <= 0) {
            return const _AccountReadSession.unavailable();
          }
          final String cookieHeader =
              (await _sessionProvider.readCookieHeader()).trim();
          if (!_containsSessionCookie(cookieHeader)) {
            return const _AccountReadSession.expired();
          }
          return _AccountReadSession.ready(
            account: account,
            cookieHeader: cookieHeader,
          );
      }
    } on PlatformException {
      return const _AccountReadSession.networkError();
    } on MissingPluginException {
      return const _AccountReadSession.networkError();
    } catch (_) {
      return const _AccountReadSession.networkError();
    }
  }

  /// 执行固定账号接口请求，并在 JSON 解析前统一映射 HTTP 与业务错误。
  Future<_AccountApiResult> _request(
    Uri endpoint,
    _AccountReadSession session,
  ) async {
    try {
      final BilibiliAccountDataResponse response = await _api.get(
        endpoint,
        session.cookieHeader!,
      );
      if (response.statusCode == HttpStatus.unauthorized) {
        return const _AccountApiResult.expired();
      }
      if (response.statusCode == HttpStatus.forbidden) {
        return const _AccountApiResult.permissionDenied();
      }
      if (response.statusCode != HttpStatus.ok) {
        return const _AccountApiResult.unavailable();
      }
      final Object? decoded = jsonDecode(response.body);
      final Map<Object?, Object?>? root = _asObject(decoded);
      if (root == null) {
        return const _AccountApiResult.malformedData();
      }
      final int? code = _readInteger(root['code']);
      if (code == null) {
        return const _AccountApiResult.malformedData();
      }
      if (code == 0) {
        return _AccountApiResult.success(root);
      }
      if (code == -101) {
        return const _AccountApiResult.expired();
      }
      if (code == -403 || code == 22007 || code == 22115) {
        return const _AccountApiResult.permissionDenied();
      }
      return const _AccountApiResult.unavailable();
    } on SocketException {
      return const _AccountApiResult.networkError();
    } on HttpException {
      return const _AccountApiResult.networkError();
    } on TimeoutException {
      return const _AccountApiResult.networkError();
    } on FormatException {
      return const _AccountApiResult.malformedData();
    } catch (_) {
      return const _AccountApiResult.networkError();
    }
  }

  /// 把会话检查结果转换为调用方可直接展示的泛型页面失败状态。
  AccountDataPage<T>? _sessionFailurePage<T>(
    _AccountReadSession session, {
    required int page,
  }) {
    switch (session.status) {
      case _AccountReadSessionStatus.ready:
        return null;
      case _AccountReadSessionStatus.signedOut:
        return AccountDataPage<T>.signedOut(page: page);
      case _AccountReadSessionStatus.expired:
        return AccountDataPage<T>.expired(page: page);
      case _AccountReadSessionStatus.networkError:
        return AccountDataPage<T>.networkError(page: page);
      case _AccountReadSessionStatus.unavailable:
        return AccountDataPage<T>.unavailable(page: page);
    }
  }

  /// 把 HTTP 或 B 站业务响应状态转换为调用方可直接展示的泛型页面失败状态。
  AccountDataPage<T>? _responseFailurePage<T>(
    _AccountApiResult response, {
    required int page,
  }) {
    switch (response.status) {
      case _AccountApiResultStatus.success:
        return null;
      case _AccountApiResultStatus.expired:
        return AccountDataPage<T>.expired(page: page);
      case _AccountApiResultStatus.networkError:
        return AccountDataPage<T>.networkError(page: page);
      case _AccountApiResultStatus.permissionDenied:
        return AccountDataPage<T>.permissionDenied(page: page);
      case _AccountApiResultStatus.unavailable:
        return AccountDataPage<T>.unavailable(page: page);
      case _AccountApiResultStatus.malformedData:
        return AccountDataPage<T>.malformedData(page: page);
    }
  }

  /// 从收藏夹接口项中提取可安全展示的最小资料，缺少编号的非法项会被忽略。
  FavoriteFolder? _parseFavoriteFolder(Object? value) {
    final Map<Object?, Object?>? item = _asObject(value);
    final int? mediaId = _readPositiveInt(item?['id']);
    if (item == null || mediaId == null) {
      return null;
    }
    return FavoriteFolder(
      mediaId: mediaId,
      title: _readText(item['title'], '未命名收藏夹'),
      coverUrl: _normalizeHttpsUrl(_readText(item['cover'], '')),
      mediaCount: _readNonNegativeInt(item['media_count']) ?? 0,
      isAvailable: (_readInteger(item['attr']) ?? 0) == 0,
    );
  }

  /// 从收藏内容接口项中提取带 BV 号的视频；没有合法 BV 号的条目不能进入播放器。
  FavoriteVideo? _parseFavoriteVideo(Object? value) {
    final Map<Object?, Object?>? item = _asObject(value);
    if (item == null) {
      return null;
    }
    final String bvid = _readText(item['bvid'] ?? item['bv_id'], '');
    if (!_bvidPattern.hasMatch(bvid)) {
      return null;
    }
    final Map<Object?, Object?> upper =
        _asObject(item['upper']) ?? const <Object?, Object?>{};
    final Map<Object?, Object?> counts =
        _asObject(item['cnt_info']) ?? const <Object?, Object?>{};
    final int durationSeconds = _readNonNegativeInt(item['duration']) ?? 0;
    return FavoriteVideo(
      bvid: bvid,
      title: _readText(item['title'], '未命名视频'),
      coverUrl: _normalizeHttpsUrl(_readText(item['cover'], '')),
      ownerName: _readText(upper['name'], '未知 UP 主'),
      duration: Duration(seconds: durationSeconds),
      partCount: (_readPositiveInt(item['page']) ?? 1),
      favoritedAt: _readUnixTime(item['fav_time']),
      playCount: _readNonNegativeInt(counts['play']) ?? 0,
      danmakuCount: _readNonNegativeInt(counts['danmaku']) ?? 0,
      isAvailable: (_readInteger(item['attr']) ?? 0) == 0,
    );
  }

  /// 从关注接口项中提取可展示的 UP 主；没有合法 mid 的非法项会被忽略。
  FollowedCreator? _parseFollowedCreator(Object? value) {
    final Map<Object?, Object?>? item = _asObject(value);
    final int? mid = _readPositiveInt(item?['mid']);
    if (item == null || mid == null) {
      return null;
    }
    final Map<Object?, Object?> officialVerify =
        _asObject(item['official_verify']) ?? const <Object?, Object?>{};
    return FollowedCreator(
      mid: mid,
      name: _readText(item['uname'], '未知 UP 主'),
      avatarUrl: _normalizeHttpsUrl(_readText(item['face'], '')),
      sign: _readText(item['sign'], ''),
      officialDescription: _readText(officialVerify['desc'], ''),
      followedAt: _readUnixTime(item['mtime']),
    );
  }

  /// 只接受 JSON 对象并统一为可安全读取键值的 Map，其他值返回 null。
  Map<Object?, Object?>? _asObject(Object? value) {
    if (value is! Map) {
      return null;
    }
    return Map<Object?, Object?>.from(value);
  }

  /// 把数值或纯数字字符串转换成整数，非整数或空内容返回 null。
  int? _readInteger(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  /// 读取允许为零的整数，负数视为无效数据并返回 null。
  int? _readNonNegativeInt(Object? value) {
    final int? number = _readInteger(value);
    return number == null || number < 0 ? null : number;
  }

  /// 读取必须大于零的整数，收藏夹和 UP 主编号都不能使用零或负数。
  int? _readPositiveInt(Object? value) {
    final int? number = _readInteger(value);
    return number == null || number <= 0 ? null : number;
  }

  /// 把字符串字段裁剪为安全展示文字，空内容时使用调用方提供的默认值。
  String _readText(Object? value, String fallback) {
    final String text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  /// 只接受 HTTPS 或协议相对图片地址，避免界面加载不安全的 HTTP 资源。
  String _normalizeHttpsUrl(String value) {
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    return value.startsWith('https://') ? value : '';
  }

  /// 将 Unix 秒时间戳转换为本地时间；零、负数和异常值统一视为未知。
  DateTime? _readUnixTime(Object? value) {
    final int? seconds = _readPositiveInt(value);
    if (seconds == null) {
      return null;
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        seconds * Duration.millisecondsPerSecond,
        isUtc: true,
      ).toLocal();
    } on ArgumentError {
      return null;
    }
  }

  /// 将调用方页码限制在 1 到 100，防止无意请求极大页码。
  int _safePage(int page) {
    return page.clamp(1, 100).toInt();
  }

  /// 判断临时请求头是否仍有非空 SESSDATA，避免会话切换后误发账号数据请求。
  bool _containsSessionCookie(String cookieHeader) {
    final RegExpMatch? match = _sessionCookiePattern.firstMatch(cookieHeader);
    return match?.group(2)?.trim().isNotEmpty ?? false;
  }
}

/// 标识会话检查后是否可以安全开始一次账号数据网络请求。
enum _AccountReadSessionStatus {
  /// 当前账号和临时 Cookie 已准备好。
  ready,

  /// 本机不存在登录会话。
  signedOut,

  /// B 站已明确拒绝当前登录会话。
  expired,

  /// 暂时无法读取或验证登录会话。
  networkError,

  /// 会话资料不完整，不能安全构造账号数据请求。
  unavailable,
}

/// 仅在单次方法调用栈中携带账号和临时 Cookie 的私有会话上下文。
class _AccountReadSession {
  /// 创建可发起只读请求的临时上下文，离开服务方法后不会被保存。
  const _AccountReadSession.ready({
    required this.account,
    required this.cookieHeader,
  })  : status = _AccountReadSessionStatus.ready,
        assert(account != null),
        assert(cookieHeader != null);

  /// 创建没有登录会话时的私有上下文。
  const _AccountReadSession.signedOut()
      : status = _AccountReadSessionStatus.signedOut,
        account = null,
        cookieHeader = null;

  /// 创建会话已过期时的私有上下文。
  const _AccountReadSession.expired()
      : status = _AccountReadSessionStatus.expired,
        account = null,
        cookieHeader = null;

  /// 创建读取登录状态失败时的私有上下文。
  const _AccountReadSession.networkError()
      : status = _AccountReadSessionStatus.networkError,
        account = null,
        cookieHeader = null;

  /// 创建账号资料不完整时的私有上下文，阻止任何网络请求。
  const _AccountReadSession.unavailable()
      : status = _AccountReadSessionStatus.unavailable,
        account = null,
        cookieHeader = null;

  /// 当前会话是否能够继续发起固定的只读账号数据请求。
  final _AccountReadSessionStatus status;

  /// 已验证账号资料，只在 status 为 ready 时存在。
  final BilibiliAccount? account;

  /// 临时 Cookie 请求头，只在 status 为 ready 时存在，绝不返回给页面模型。
  final String? cookieHeader;
}

/// 标识一次账号数据 HTTP 响应在解析前得到的安全分类。
enum _AccountApiResultStatus {
  /// HTTP 和 B 站业务码都表示成功。
  success,

  /// HTTP 或 B 站业务码明确表示会话失效。
  expired,

  /// 网络、连接或请求超时。
  networkError,

  /// 当前账号无权读取目标数据。
  permissionDenied,

  /// 服务器暂时拒绝或无法提供账号数据。
  unavailable,

  /// 返回正文不是可安全处理的 JSON 对象。
  malformedData,
}

/// 保存已映射的账号接口响应，避免把原始响应或 Cookie 传递到页面层。
class _AccountApiResult {
  /// 创建成功响应并保存待调用方读取的 JSON 根对象。
  const _AccountApiResult.success(this.root)
      : status = _AccountApiResultStatus.success;

  /// 创建 B 站明确拒绝登录时的响应状态。
  const _AccountApiResult.expired()
      : status = _AccountApiResultStatus.expired,
        root = null;

  /// 创建网络暂时不可用时的响应状态。
  const _AccountApiResult.networkError()
      : status = _AccountApiResultStatus.networkError,
        root = null;

  /// 创建访问权限不足时的响应状态。
  const _AccountApiResult.permissionDenied()
      : status = _AccountApiResultStatus.permissionDenied,
        root = null;

  /// 创建服务器业务错误时的响应状态。
  const _AccountApiResult.unavailable()
      : status = _AccountApiResultStatus.unavailable,
        root = null;

  /// 创建数据结构无法安全解析时的响应状态。
  const _AccountApiResult.malformedData()
      : status = _AccountApiResultStatus.malformedData,
        root = null;

  /// 响应分类，供服务方法映射为公开页面状态。
  final _AccountApiResultStatus status;

  /// 成功 JSON 根对象；失败时始终为 null。
  final Map<Object?, Object?>? root;
}
