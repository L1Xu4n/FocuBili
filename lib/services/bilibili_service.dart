import 'dart:convert';
import 'dart:io';

import '../models/video_preview.dart';

/// 定义可替换的 JSON 请求函数，方便测试时不用真的访问网络。
typedef JsonRequest = Future<String> Function(Uri uri);

/// 表示公开视频信息查询失败，并向页面提供适合直接展示给用户的说明。
class BilibiliLookupException implements Exception {
  /// 创建一条用户能理解的查询失败说明。
  const BilibiliLookupException(this.message);

  final String message;

  /// 把异常转换为简短文字，便于调试日志和页面统一展示。
  @override
  String toString() => message;
}

/// 定义 FocuBili 目前需要的视频查询能力：由 BV 号或视频链接取得一支视频的信息。
abstract interface class BilibiliService {
  /// 查询输入内容对应的公开视频，并返回播放页需要的最小信息。
  Future<VideoPreview> lookupVideo(String input);

  /// 按用户主动输入的关键词搜索公开视频，不加载推荐流。
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  });

  /// 根据正在输入的文字获取搜索候选词，输入为空时返回空列表。
  Future<List<String>> suggestKeywords(String input);
}

/// 使用公开视频详情接口查询标题、UP 主和时长，不读取或保存用户 Cookie。
class BilibiliVideoInfoService implements BilibiliService {
  /// 创建服务；测试可传入自定义请求函数，正式 App 默认使用 HTTPS 请求。
  BilibiliVideoInfoService({JsonRequest? requestJson})
      : _requestJson = requestJson ?? _requestPublicJson;

  static const String _apiHost = 'api.bilibili.com';
  static const String _suggestHost = 's.search.bilibili.com';
  static const String _videoInfoPath = '/x/web-interface/view';
  static const String _videoSearchPath = '/x/web-interface/wbi/search/type';
  static const String _searchSuggestPath = '/main/suggest';
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';
  static final RegExp _bvidPattern = RegExp(
    r'BV[0-9A-Za-z]{10}',
    caseSensitive: false,
  );

  final JsonRequest _requestJson;

  /// 从 BV 号或包含 BV 号的视频链接中提取编号，查询后返回可直接进入播放页的数据。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    final String? bvid = _extractBvid(input);
    if (bvid == null) {
      throw const BilibiliLookupException(
        '没有找到有效的 BV 号。请粘贴类似 BV1GJ411x7h7 的编号或 B 站视频链接。',
      );
    }
    final Uri endpoint = Uri.https(
      _apiHost,
      _videoInfoPath,
      <String, String>{'bvid': bvid},
    );
    final String responseText = await _requestJson(endpoint);
    return _parseVideoInfo(responseText, bvid);
  }

  /// 请求关键词视频搜索接口，并把 HTML 标记和接口字段转换为轻量结果列表。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    final String normalizedKeyword = keyword.trim();
    if (normalizedKeyword.isEmpty) {
      throw const BilibiliLookupException('请输入要搜索的视频关键词。');
    }
    final int safePage = page.clamp(1, 50).toInt();
    final Map<String, String> query = <String, String>{
      'search_type': 'video',
      'keyword': normalizedKeyword,
      'page': safePage.toString(),
      'order': _searchOrderValue(filter.order),
      'duration': _durationRangeValue(filter.durationRange).toString(),
    };
    if (filter.categoryId != null) {
      query['tids'] = filter.categoryId.toString();
    }
    _appendPublishedRange(query, filter.publishedRange);
    final Uri endpoint = Uri.https(
      _apiHost,
      _videoSearchPath,
      query,
    );
    final String responseText = await _requestJson(endpoint);
    return _parseVideoSearchPage(responseText, safePage);
  }

  /// 请求 B 站搜索建议接口，并返回去重后的候选词列表。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    final String normalizedInput = input.trim();
    if (normalizedInput.isEmpty) {
      return const <String>[];
    }
    final Uri endpoint = Uri.https(
      _suggestHost,
      _searchSuggestPath,
      <String, String>{'term': normalizedInput, 'main_ver': 'v1'},
    );
    final String responseText = await _requestJson(endpoint);
    return _parseSearchSuggestions(responseText);
  }

  /// 从输入文字或链接中取出 BV 号，并统一前缀大小写以减少粘贴时的常见错误。
  String? _extractBvid(String input) {
    final RegExpMatch? match = _bvidPattern.firstMatch(input.trim());
    if (match == null) {
      return null;
    }
    final String rawBvid = match.group(0)!;
    return 'BV${rawBvid.substring(2)}';
  }

  /// 解析详情接口 JSON，检查接口错误码后转换成界面使用的 VideoPreview。
  VideoPreview _parseVideoInfo(String responseText, String requestedBvid) {
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw const BilibiliLookupException('视频详情接口返回的数据格式不正确。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      final String serverMessage = root['message'] as String? ?? '';
      throw BilibiliLookupException(
        serverMessage.isEmpty || serverMessage == '0'
            ? '无法查询这支公开视频（错误码：$code）。'
            : '无法查询这支公开视频：$serverMessage（错误码：$code）。',
      );
    }
    final Object? rawData = root['data'];
    if (rawData is! Map) {
      throw const BilibiliLookupException('接口没有返回视频详情。');
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    final Map<Object?, Object?> owner = _readObject(data['owner']);
    final int durationSeconds = (data['duration'] as num?)?.toInt() ?? 0;
    final int cid = (data['cid'] as num?)?.toInt() ?? 0;
    if (cid <= 0) {
      throw const BilibiliLookupException('接口没有返回可播放的分P编号。');
    }
    final List<VideoPart> parts = _parseVideoParts(
      data['pages'],
      fallbackCid: cid,
      fallbackTitle: _readText(data['title'], '未命名视频'),
      fallbackDurationSeconds: durationSeconds,
    );
    final VideoPart initialPart = parts.firstWhere(
      (VideoPart part) => part.cid == cid,
      // 默认 cid 不在列表中时使用第一P，避免接口局部字段不一致导致页面崩溃。
      orElse: () => parts.first,
    );
    return VideoPreview(
      bvid: data['bvid'] as String? ?? requestedBvid,
      cid: initialPart.cid,
      title: _readText(data['title'], '未命名视频'),
      ownerName: _readText(owner['name'], '未知 UP 主'),
      duration: initialPart.duration,
      thumbnailUrl: _normalizeThumbnailUrl(_readText(data['pic'], '')),
      parts: parts,
    );
  }

  /// 解析关键词搜索 JSON，过滤无 BV 号条目并保留服务端分页信息。
  VideoSearchPage _parseVideoSearchPage(
      String responseText, int requestedPage) {
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw const BilibiliLookupException('视频搜索接口返回的数据格式不正确。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      final String serverMessage = root['message'] as String? ?? '';
      throw BilibiliLookupException(
        serverMessage.isEmpty || serverMessage == '0'
            ? '视频搜索失败（错误码：$code）。'
            : '视频搜索失败：$serverMessage（错误码：$code）。',
      );
    }
    final Map<Object?, Object?> data = _readObject(root['data']);
    final Object? rawResults = data['result'];
    if (rawResults is! List) {
      return VideoSearchPage(
        results: const <VideoSearchResult>[],
        page: requestedPage,
        totalPages: requestedPage,
      );
    }
    final List<VideoSearchResult> results = <VideoSearchResult>[];
    for (final Object? rawResult in rawResults) {
      if (rawResult is! Map) {
        continue;
      }
      final Map<Object?, Object?> item = Map<Object?, Object?>.from(rawResult);
      final String bvid = _readText(item['bvid'], '');
      if (!_bvidPattern.hasMatch(bvid)) {
        continue;
      }
      results.add(
        VideoSearchResult(
          bvid: bvid,
          title: _stripHtml(_readText(item['title'], '未命名视频')),
          ownerName: _stripHtml(_readText(item['author'], '未知 UP 主')),
          duration: _parseSearchDuration(_readText(item['duration'], '0:00')),
          thumbnailUrl: _normalizeThumbnailUrl(_readText(item['pic'], '')),
          publishedAt: _parseUnixTime(item['pubdate']),
          playCount: _readInteger(item['play']),
          danmakuCount: _readInteger(item['danmaku'] ?? item['video_review']),
          episodeCountText: _stripHtml(
            _readText(item['episode_count_text'], ''),
          ),
        ),
      );
    }
    final int page = _readInteger(data['page']).clamp(1, 50).toInt();
    final int totalPages =
        _readInteger(data['numPages']).clamp(page, 50).toInt();
    return VideoSearchPage(
      results: List<VideoSearchResult>.unmodifiable(results),
      page: page == 1 && requestedPage > 1 ? requestedPage : page,
      totalPages: totalPages,
    );
  }

  /// 解析候选词接口的 result.tag 数组，并按原顺序去重。
  List<String> _parseSearchSuggestions(String responseText) {
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      return const <String>[];
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final Map<Object?, Object?> result = _readObject(root['result']);
    final Object? rawTags = result['tag'];
    if (rawTags is! List) {
      return const <String>[];
    }
    final Set<String> suggestions = <String>{};
    for (final Object? rawTag in rawTags) {
      if (rawTag is! Map) {
        continue;
      }
      final Map<Object?, Object?> tag = Map<Object?, Object?>.from(rawTag);
      final String value =
          _stripHtml(_readText(tag['value'] ?? tag['term'], ''));
      if (value.isNotEmpty) {
        suggestions.add(value);
      }
    }
    return List<String>.unmodifiable(suggestions.take(10));
  }

  /// 将界面排序枚举转换成搜索接口使用的 order 参数。
  String _searchOrderValue(VideoSearchOrder order) {
    switch (order) {
      case VideoSearchOrder.relevance:
        return 'totalrank';
      case VideoSearchOrder.mostPlayed:
        return 'click';
      case VideoSearchOrder.newest:
        return 'pubdate';
      case VideoSearchOrder.mostDanmaku:
        return 'dm';
      case VideoSearchOrder.mostFavorited:
        return 'stow';
    }
  }

  /// 将界面时长枚举转换成搜索接口使用的 duration 编号。
  int _durationRangeValue(VideoDurationRange range) {
    switch (range) {
      case VideoDurationRange.any:
        return 0;
      case VideoDurationRange.underTenMinutes:
        return 1;
      case VideoDurationRange.tenToThirtyMinutes:
        return 2;
      case VideoDurationRange.thirtyToSixtyMinutes:
        return 3;
      case VideoDurationRange.overSixtyMinutes:
        return 4;
    }
  }

  /// 按发布日期范围向查询参数加入开始与结束时间戳。
  void _appendPublishedRange(
    Map<String, String> query,
    VideoPublishedRange range,
  ) {
    if (range == VideoPublishedRange.any) {
      return;
    }
    final int nowSeconds =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final int rangeSeconds;
    switch (range) {
      case VideoPublishedRange.lastDay:
        rangeSeconds = const Duration(days: 1).inSeconds;
        break;
      case VideoPublishedRange.lastWeek:
        rangeSeconds = const Duration(days: 7).inSeconds;
        break;
      case VideoPublishedRange.lastHalfYear:
        rangeSeconds = const Duration(days: 183).inSeconds;
        break;
      case VideoPublishedRange.any:
        return;
    }
    query['pubtime_begin_s'] = (nowSeconds - rangeSeconds).toString();
    query['pubtime_end_s'] = nowSeconds.toString();
  }

  /// 将接口中的整数、浮点数或数字字符串安全转换为非负整数。
  int _readInteger(Object? value) {
    if (value is num) {
      return value.toInt().clamp(0, 1 << 31).toInt();
    }
    return int.tryParse(value?.toString() ?? '')?.clamp(0, 1 << 31).toInt() ??
        0;
  }

  /// 将 Unix 秒级时间戳转换为本地时间，无效内容返回 null。
  DateTime? _parseUnixTime(Object? value) {
    final int seconds = _readInteger(value);
    if (seconds <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
        .toLocal();
  }

  /// 删除搜索标题中的高亮 HTML，并还原常见实体字符。
  String _stripHtml(String text) {
    return text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
  }

  /// 将搜索接口的“分:秒”或“时:分:秒”文字转换为 Duration。
  Duration _parseSearchDuration(String text) {
    final List<int> parts = text
        .split(':')
        .map((String value) => int.tryParse(value.trim()) ?? 0)
        .toList(growable: false);
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    if (parts.length == 2) {
      return Duration(minutes: parts[0], seconds: parts[1]);
    }
    return Duration(seconds: parts.isEmpty ? 0 : parts.last);
  }

  /// 把封面地址转换为 HTTPS，并让 B 站图片 CDN 直接返回低流量 WebP 缩略图。
  String _normalizeThumbnailUrl(String value) {
    final String normalized = value.startsWith('//') ? 'https:$value' : value;
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.host.endsWith('.hdslb.com')) {
      return '';
    }
    if (normalized.contains('@')) {
      return normalized;
    }
    return '$normalized@320w_200h_1c.webp';
  }

  /// 把详情接口的 pages 数组转换为稳定的分P列表，并在缺失时补一条默认分P。
  List<VideoPart> _parseVideoParts(
    Object? rawPages, {
    required int fallbackCid,
    required String fallbackTitle,
    required int fallbackDurationSeconds,
  }) {
    final List<VideoPart> parts = <VideoPart>[];
    if (rawPages is List) {
      for (final Object? rawPart in rawPages) {
        if (rawPart is! Map) {
          continue;
        }
        final Map<Object?, Object?> part = Map<Object?, Object?>.from(rawPart);
        final int cid = (part['cid'] as num?)?.toInt() ?? 0;
        if (cid <= 0) {
          continue;
        }
        final int pageNumber =
            (part['page'] as num?)?.toInt() ?? parts.length + 1;
        final int durationSeconds = (part['duration'] as num?)?.toInt() ?? 0;
        parts.add(
          VideoPart(
            pageNumber: pageNumber <= 0 ? parts.length + 1 : pageNumber,
            cid: cid,
            title: _readText(part['part'], 'P${parts.length + 1}'),
            duration: Duration(
              seconds: durationSeconds < 0 ? 0 : durationSeconds,
            ),
          ),
        );
      }
    }
    if (parts.isEmpty) {
      parts.add(
        VideoPart(
          pageNumber: 1,
          cid: fallbackCid,
          title: fallbackTitle,
          duration: Duration(
            seconds: fallbackDurationSeconds < 0 ? 0 : fallbackDurationSeconds,
          ),
        ),
      );
    }
    return List<VideoPart>.unmodifiable(parts);
  }

  /// 将未知 JSON 值安全转换为空对象或键值对象，避免单个缺失字段导致页面崩溃。
  Map<Object?, Object?> _readObject(Object? value) {
    return value is Map
        ? Map<Object?, Object?>.from(value)
        : const <Object?, Object?>{};
  }

  /// 将未知 JSON 字段转换为文本，并在内容为空时使用界面可读的默认值。
  String _readText(Object? value, String fallback) {
    final String text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  /// 发出不带 Cookie 的 HTTPS GET 请求，并返回详情接口的 JSON 文本。
  static Future<String> _requestPublicJson(Uri uri) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        uri.path == _videoSearchPath
            ? 'https://search.bilibili.com/'
            : 'https://www.bilibili.com/',
      );
      final HttpClientResponse response = await request.close();
      final String responseText = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw BilibiliLookupException(
          '视频详情接口暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      return responseText;
    } on SocketException {
      throw const BilibiliLookupException('无法连接到视频详情接口，请检查网络后重试。');
    } on HttpException {
      throw const BilibiliLookupException('视频详情接口的网络响应异常，请稍后重试。');
    } finally {
      client.close(force: true);
    }
  }
}
