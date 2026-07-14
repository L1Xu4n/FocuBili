import 'dart:convert';
import 'dart:io';

import '../models/public_profile.dart';
import '../models/video_preview.dart';
import 'bilibili_service.dart';

/// 定义可注入的公开 JSON 请求函数，测试时无需连接真实网络。
typedef PublicContentJsonRequest = Future<String> Function(Uri endpoint);

/// 定义用户主页及 UGC 合集需要的只读公开内容能力。
abstract interface class BilibiliPublicContentService {
  /// 读取一个 UP 主的公开名片和统计。
  Future<CreatorProfile> loadProfile(int mid);

  /// 分页读取 UP 主的公开投稿。
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
  });

  /// 分页读取 UP 主的公开专栏摘要。
  Future<CreatorContentPage<CreatorArticle>> loadArticles(
    int mid, {
    int page = 1,
  });

  /// 分页读取 UP 主创建的 UGC 合集，不把普通系列混入合集。
  Future<CreatorContentPage<CreatorCollection>> loadCollections(
    int mid, {
    int page = 1,
  });

  /// 分页读取指定 UGC 合集中的独立视频。
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  });
}

/// 通过公开 HTTPS 接口实现用户主页和合集浏览，不读取账号 Cookie。
class BilibiliHttpPublicContentService implements BilibiliPublicContentService {
  /// 创建公开内容服务；测试可注入固定 JSON 请求。
  BilibiliHttpPublicContentService({PublicContentJsonRequest? requestJson})
      : _requestJson = requestJson ?? _requestPublicJson;

  static const String _apiHost = 'api.bilibili.com';
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';
  static final RegExp _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');
  final PublicContentJsonRequest _requestJson;

  /// 请求用户名片接口并解析头像、签名、认证、关注、粉丝和获赞数。
  @override
  Future<CreatorProfile> loadProfile(int mid) async {
    _requirePositiveId(mid, 'UP 主编号');
    final Uri endpoint = Uri.https(
      _apiHost,
      '/x/web-interface/card',
      <String, String>{'mid': mid.toString(), 'photo': 'true'},
    );
    final Map<Object?, Object?> data = await _requestData(endpoint);
    final Map<Object?, Object?> card = _readObject(data['card']);
    final Map<Object?, Object?> official = _readObject(card['Official']);
    return CreatorProfile(
      mid: _readPositiveInt(card['mid']) ?? mid,
      name: _readText(card['name'], '未知 UP 主'),
      avatarUrl: _normalizeImageUrl(_readText(card['face'], '')),
      sign: _readText(card['sign'], ''),
      officialDescription: _readText(official['desc'], ''),
      followingCount: _readNonNegativeInt(card['attention']),
      followerCount: _readNonNegativeInt(data['follower']),
      likeCount: _readNonNegativeInt(data['like_num']),
      videoCount: _readNonNegativeInt(data['archive_count']),
      articleCount: _readNonNegativeInt(data['article_count']),
    );
  }

  /// 请求公开投稿列表并转换为主页可点击的视频卡片。
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
  }) async {
    _requirePositiveId(mid, 'UP 主编号');
    final int safePage = _safePage(page);
    final Uri endpoint = Uri.https(
      _apiHost,
      '/x/space/arc/search',
      <String, String>{
        'mid': mid.toString(),
        'pn': safePage.toString(),
        'ps': '20',
        'order': 'pubdate',
      },
    );
    final Map<Object?, Object?> data = await _requestData(endpoint);
    final Map<Object?, Object?> list = _readObject(data['list']);
    final List<CreatorVideo> videos = _parseVideoList(list['vlist']);
    final int total = _readNonNegativeInt(_readObject(data['page'])['count']);
    return CreatorContentPage<CreatorVideo>(
      items: List<CreatorVideo>.unmodifiable(videos),
      page: safePage,
      hasMore: safePage * 20 < total,
      totalCount: total,
    );
  }

  /// 请求公开专栏列表并保留标题、摘要、首图、时间和阅读量。
  @override
  Future<CreatorContentPage<CreatorArticle>> loadArticles(
    int mid, {
    int page = 1,
  }) async {
    _requirePositiveId(mid, 'UP 主编号');
    final int safePage = _safePage(page);
    final Uri endpoint = Uri.https(
      _apiHost,
      '/x/space/article',
      <String, String>{
        'mid': mid.toString(),
        'pn': safePage.toString(),
        'ps': '20',
        'sort': 'publish_time',
      },
    );
    final Map<Object?, Object?> data = await _requestData(endpoint);
    final List<CreatorArticle> articles = <CreatorArticle>[];
    final Object? rawArticles = data['articles'];
    if (rawArticles is List) {
      for (final Object? rawArticle in rawArticles) {
        final CreatorArticle? article = _parseArticle(rawArticle);
        if (article != null) {
          articles.add(article);
        }
      }
    }
    final int total = _readNonNegativeInt(
      _readObject(data['page'])['count'] ?? data['count'],
    );
    return CreatorContentPage<CreatorArticle>(
      items: List<CreatorArticle>.unmodifiable(articles),
      page: safePage,
      hasMore: total > 0 ? safePage * 20 < total : articles.length == 20,
      totalCount: total > 0 ? total : null,
    );
  }

  /// 请求空间合集列表，只解析 seasons_list 中真正的 UGC 合集。
  @override
  Future<CreatorContentPage<CreatorCollection>> loadCollections(
    int mid, {
    int page = 1,
  }) async {
    _requirePositiveId(mid, 'UP 主编号');
    final int safePage = _safePage(page);
    final Uri endpoint = Uri.https(
      _apiHost,
      '/x/polymer/web-space/seasons_series_list',
      <String, String>{
        'mid': mid.toString(),
        'page_num': safePage.toString(),
        'page_size': '20',
      },
    );
    final Map<Object?, Object?> data = await _requestData(endpoint);
    final Map<Object?, Object?> lists = _readObject(data['items_lists']);
    final List<CreatorCollection> collections = <CreatorCollection>[];
    final Object? rawCollections = lists['seasons_list'];
    if (rawCollections is List) {
      for (final Object? rawCollection in rawCollections) {
        final CreatorCollection? collection =
            _parseCollection(rawCollection, mid);
        if (collection != null) {
          collections.add(collection);
        }
      }
    }
    final bool hasMore = collections.length == 20 || data['has_more'] == true;
    return CreatorContentPage<CreatorCollection>(
      items: List<CreatorCollection>.unmodifiable(collections),
      page: safePage,
      hasMore: hasMore,
    );
  }

  /// 请求指定合集的全部视频分页，并按服务端顺序转换成统一视频卡片。
  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  }) async {
    _requirePositiveId(ownerMid, 'UP 主编号');
    _requirePositiveId(collectionId, '合集编号');
    final int safePage = _safePage(page);
    final Uri endpoint = Uri.https(
      _apiHost,
      '/x/polymer/web-space/seasons_archives_list',
      <String, String>{
        'mid': ownerMid.toString(),
        'season_id': collectionId.toString(),
        'page_num': safePage.toString(),
        'page_size': '20',
        'sort_reverse': 'false',
      },
    );
    final Map<Object?, Object?> data = await _requestData(endpoint);
    final List<CreatorVideo> videos = _parseVideoList(data['archives']);
    final Map<Object?, Object?> meta = _readObject(data['meta']);
    final int total = _readNonNegativeInt(meta['total'] ?? data['total']);
    return CreatorContentPage<CreatorVideo>(
      items: List<CreatorVideo>.unmodifiable(videos),
      page: safePage,
      hasMore: total > 0 ? safePage * 20 < total : videos.length == 20,
      totalCount: total > 0 ? total : null,
    );
  }

  /// 发送请求并统一检查 B 站业务错误码与 data 对象。
  Future<Map<Object?, Object?>> _requestData(Uri endpoint) async {
    final String responseText = await _requestJson(endpoint);
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw const BilibiliLookupException('公开内容接口返回的数据格式不正确。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = _readInteger(root['code']) ?? -1;
    if (code != 0) {
      final String message = _readText(root['message'], '请求失败');
      throw BilibiliLookupException('$message（错误码：$code）');
    }
    final Object? rawData = root['data'];
    if (rawData is! Map) {
      throw const BilibiliLookupException('公开内容接口没有返回可用数据。');
    }
    return Map<Object?, Object?>.from(rawData);
  }

  /// 从投稿或合集 archives 数组中解析合法 BV 视频，并忽略损坏条目。
  List<CreatorVideo> _parseVideoList(Object? value) {
    final List<CreatorVideo> videos = <CreatorVideo>[];
    if (value is! List) {
      return videos;
    }
    for (final Object? rawVideo in value) {
      final Map<Object?, Object?> item = _readObject(rawVideo);
      final String bvid = _readText(item['bvid'], '');
      if (!_bvidPattern.hasMatch(bvid)) {
        continue;
      }
      final Map<Object?, Object?> stats = _readObject(item['stat']);
      videos.add(
        CreatorVideo(
          bvid: bvid,
          title: _readText(item['title'], '未命名视频'),
          coverUrl: _normalizeThumbnailUrl(
            _readText(item['pic'] ?? item['cover'], ''),
          ),
          duration: Duration(seconds: _readNonNegativeInt(item['duration'])),
          publishedAt: _readUnixTime(item['pubdate'] ?? item['created']),
          stats: VideoStats(
            viewCount: _readNonNegativeInt(stats['view'] ?? item['play']),
            danmakuCount:
                _readNonNegativeInt(stats['danmaku'] ?? item['video_review']),
          ),
        ),
      );
    }
    return videos;
  }

  /// 从专栏接口项中解析文章摘要，编号无效时忽略该项。
  CreatorArticle? _parseArticle(Object? value) {
    final Map<Object?, Object?> item = _readObject(value);
    final int? id = _readPositiveInt(item['id']);
    if (id == null) {
      return null;
    }
    String coverUrl = '';
    final Object? rawImages = item['image_urls'];
    if (rawImages is List && rawImages.isNotEmpty) {
      coverUrl = _normalizeThumbnailUrl(_readText(rawImages.first, ''));
    }
    return CreatorArticle(
      id: id,
      title: _readText(item['title'], '未命名专栏'),
      summary: _readText(item['summary'], ''),
      coverUrl: coverUrl,
      publishedAt: _readUnixTime(item['publish_time']),
      viewCount: _readNonNegativeInt(item['view']),
    );
  }

  /// 从空间 seasons_list 项中解析 UGC 合集和最多六支预览视频。
  CreatorCollection? _parseCollection(Object? value, int fallbackOwnerMid) {
    final Map<Object?, Object?> item = _readObject(value);
    final Map<Object?, Object?> meta = _readObject(item['meta']);
    final int? id = _readPositiveInt(meta['season_id'] ?? meta['id']);
    if (id == null) {
      return null;
    }
    return CreatorCollection(
      id: id,
      ownerMid: _readPositiveInt(meta['mid']) ?? fallbackOwnerMid,
      title: _readText(meta['title'] ?? meta['name'], '未命名合集'),
      coverUrl: _normalizeThumbnailUrl(_readText(meta['cover'], '')),
      description: _readText(meta['description'], ''),
      totalCount: _readNonNegativeInt(meta['total']),
      previewVideos: List<CreatorVideo>.unmodifiable(
        _parseVideoList(item['archives']).take(6),
      ),
    );
  }

  /// 检查编号必须为正数，避免向公开接口发送无意义请求。
  void _requirePositiveId(int value, String label) {
    if (value <= 0) {
      throw BilibiliLookupException('$label不正确，请返回后重试。');
    }
  }

  /// 把页码限制在公开接口的合理范围内。
  int _safePage(int page) => page.clamp(1, 50).toInt();

  /// 将未知 JSON 对象转换为可安全读取的 Map。
  Map<Object?, Object?> _readObject(Object? value) {
    return value is Map
        ? Map<Object?, Object?>.from(value)
        : const <Object?, Object?>{};
  }

  /// 把数字或数字字符串转换为整数，无效内容返回 null。
  int? _readInteger(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  /// 读取大于零的编号，无效或非正数返回 null。
  int? _readPositiveInt(Object? value) {
    final int? number = _readInteger(value);
    return number == null || number <= 0 ? null : number;
  }

  /// 读取非负统计，接口异常值统一回退为零。
  int _readNonNegativeInt(Object? value) {
    final int? number = _readInteger(value);
    return number == null || number < 0 ? 0 : number;
  }

  /// 读取非空文本，并在字段缺失时使用指定默认值。
  String _readText(Object? value, String fallback) {
    final String text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  /// 将秒级 Unix 时间戳转换为本地时间，无效时间返回 null。
  DateTime? _readUnixTime(Object? value) {
    final int? seconds = _readPositiveInt(value);
    return seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
            .toLocal();
  }

  /// 把可信 B 站图片地址统一为 HTTPS，不允许加载任意第三方图片域名。
  String _normalizeImageUrl(String value) {
    final String normalized = value.startsWith('//') ? 'https:$value' : value;
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme != 'https' ||
        (!uri.host.endsWith('.hdslb.com') &&
            !uri.host.endsWith('.biliimg.com'))) {
      return '';
    }
    return normalized;
  }

  /// 为封面地址追加服务端缩略图参数，降低主页列表流量。
  String _normalizeThumbnailUrl(String value) {
    final String normalized = _normalizeImageUrl(value);
    if (normalized.isEmpty || normalized.contains('@')) {
      return normalized;
    }
    return '$normalized@480w_270h_1c.webp';
  }

  /// 发出不带 Cookie 的公开 HTTPS 请求，并把常见网络错误转换为可读提示。
  static Future<String> _requestPublicJson(Uri endpoint) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://space.bilibili.com/',
      );
      final HttpClientResponse response = await request.close();
      final String responseText = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw BilibiliLookupException(
          '公开内容接口暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      return responseText;
    } on SocketException {
      throw const BilibiliLookupException('无法连接到公开内容接口，请检查网络后重试。');
    } on HttpException {
      throw const BilibiliLookupException('公开内容接口响应异常，请稍后重试。');
    } finally {
      client.close(force: true);
    }
  }
}
