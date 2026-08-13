import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/utils/bilibili_id_converter.dart';

/// 定义短链接展开函数，测试可以避免访问真实网络。
typedef BilibiliShortLinkExpander = Future<Uri?> Function(Uri shortLink);

/// 保存跨应用视频链接解析出的播放目标、分P和起始时间。
class BilibiliVideoDeepLinkTarget {
  /// 创建一个已经归一化为 BV 号的外部视频跳转目标。
  const BilibiliVideoDeepLinkTarget({
    required this.bvid,
    this.partCid,
    this.partPageNumber,
    this.initialPosition,
  });

  final String bvid;
  final int? partCid;
  final int? partPageNumber;
  final Duration? initialPosition;
}

/// 只解析焦点哔哩当前真正支持的视频网页和 `bilibili://video` Scheme。
abstract final class BilibiliDeepLinkParser {
  static final RegExp _bvidPattern = RegExp(
    r'BV[0-9A-Za-z]{10}',
    caseSensitive: false,
  );
  static final RegExp _avPattern = RegExp(
    r'(?:^|[^0-9A-Za-z])av(\d+)',
    caseSensitive: false,
  );
  static const Set<String> _videoWebHosts = <String>{
    'bilibili.com',
    'www.bilibili.com',
    'm.bilibili.com',
  };

  /// 把外部 URI 转成播放器目标；非视频、无效编号和其他网站会安全返回空值。
  static BilibiliVideoDeepLinkTarget? parse(String rawLink) {
    final Uri? uri = Uri.tryParse(rawLink.trim());
    if (uri == null) {
      return null;
    }
    final String scheme = uri.scheme.toLowerCase();
    final bool customVideoScheme =
        scheme == 'bilibili' && uri.host.toLowerCase() == 'video';
    final bool supportedVideoWebLink =
        (scheme == 'http' || scheme == 'https') &&
        _videoWebHosts.contains(uri.host.toLowerCase()) &&
        uri.path.toLowerCase().contains('/video/');
    if (!customVideoScheme && !supportedVideoWebLink) {
      return null;
    }

    final String? bvid = _extractBvid(uri);
    if (bvid == null) {
      return null;
    }
    return BilibiliVideoDeepLinkTarget(
      bvid: bvid,
      partCid: _positiveInteger(uri.queryParameters['cid']),
      partPageNumber: _partPageNumber(uri),
      initialPosition: _initialPosition(uri),
    );
  }

  /// 按结构化字段提取 BV；不会再把 QQ 的不透明 Base64 参数误认成随机 BV 号。
  static String? _extractBvid(Uri uri) {
    final RegExpMatch? bvMatch = _bvidPattern.firstMatch(uri.path);
    if (bvMatch != null) {
      return _normalizeBvid(bvMatch.group(0)!);
    }
    final String? explicitBvid = uri.queryParameters['bvid'];
    final RegExpMatch? explicitMatch = explicitBvid == null
        ? null
        : _bvidPattern.firstMatch(explicitBvid);
    if (explicitMatch != null) {
      return _normalizeBvid(explicitMatch.group(0)!);
    }
    final String? firstSegment = uri.pathSegments.isEmpty
        ? null
        : uri.pathSegments.first;
    final RegExpMatch? pathAvMatch = _avPattern.firstMatch(uri.path);
    int? aid;
    for (final String? candidate in <String?>[
      pathAvMatch?.group(1),
      firstSegment,
      uri.queryParameters['aid'],
      uri.queryParameters['avid'],
    ]) {
      aid = int.tryParse(candidate ?? '');
      if (aid != null) {
        break;
      }
    }
    final String? convertedBvid = aid == null
        ? null
        : BilibiliIdConverter.avToBv(aid);
    if (convertedBvid != null) {
      return convertedBvid;
    }
    return _extractH5AwakenBvid(uri.queryParameters['h5awaken']);
  }

  /// 解码 QQ 分享携带的 h5awaken，并只从解码后的官方唤醒内容读取标准 BV 号。
  static String? _extractH5AwakenBvid(String? rawPayload) {
    if (rawPayload == null || rawPayload.trim().isEmpty) {
      return null;
    }
    try {
      final String normalizedPayload = base64.normalize(rawPayload.trim());
      final String decodedPayload = utf8.decode(
        base64.decode(normalizedPayload),
      );
      final RegExpMatch? match = _bvidPattern.firstMatch(decodedPayload);
      return match == null ? null : _normalizeBvid(match.group(0)!);
    } on FormatException {
      return null;
    }
  }

  /// 统一 BV 前缀大小写，同时保留后十位区分大小写的真实编号。
  static String _normalizeBvid(String rawBvid) {
    return 'BV${rawBvid.substring(2)}';
  }

  /// 读取 `cid` 等必须为正数的查询参数，非法值不会传给播放器。
  static int? _positiveInteger(String? rawValue) {
    final int? value = int.tryParse(rawValue ?? '');
    return value != null && value > 0 ? value : null;
  }

  /// 兼容网页的 `p=1` 与官方 Scheme 的零起点 `page=0` 分P参数。
  static int? _partPageNumber(Uri uri) {
    final int? webPage = _positiveInteger(uri.queryParameters['p']);
    if (webPage != null) {
      return webPage;
    }
    final int? schemePage = int.tryParse(uri.queryParameters['page'] ?? '');
    return schemePage != null && schemePage >= 0 ? schemePage + 1 : null;
  }

  /// 兼容官方毫秒进度和网页秒数进度，并过滤零值、负值与非数字。
  static Duration? _initialPosition(Uri uri) {
    final String? millisecondText =
        uri.queryParameters['start_progress'] ??
        uri.queryParameters['dm_progress'];
    final int? milliseconds = int.tryParse(millisecondText ?? '');
    if (milliseconds != null && milliseconds > 0) {
      return Duration(milliseconds: milliseconds);
    }
    final double? seconds = double.tryParse(uri.queryParameters['t'] ?? '');
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }
}

/// 从系统分享文本或剪贴板文字中提取并解析可播放的 B站链接。
class BilibiliIncomingLinkResolver {
  /// 创建外部文本解析器；正式环境默认以受限网络请求展开 `b23.tv`。
  BilibiliIncomingLinkResolver({BilibiliShortLinkExpander? expandShortLink})
    : _expandShortLink = expandShortLink ?? _expandB23Link;

  static final RegExp _webLinkPattern = RegExp(
    r'https?://[^\s<>\u3000]+',
    caseSensitive: false,
  );
  static const String _shortLinkHost = 'b23.tv';
  static const String _trailingPunctuation = '.,!?;:"\'，。！？；：、）)]}》】」』';
  final BilibiliShortLinkExpander _expandShortLink;

  /// 解析完整 URI 或分享正文中的首个受支持链接，短链失败时安全返回空值。
  Future<BilibiliVideoDeepLinkTarget?> resolve(String rawText) async {
    final BilibiliVideoDeepLinkTarget? direct = BilibiliDeepLinkParser.parse(
      rawText,
    );
    if (direct != null) {
      return direct;
    }
    for (final Uri candidate in extractWebLinks(rawText)) {
      final BilibiliVideoDeepLinkTarget? embedded =
          BilibiliDeepLinkParser.parse(candidate.toString());
      if (embedded != null) {
        return embedded;
      }
      if (candidate.host.toLowerCase() != _shortLinkHost) {
        continue;
      }
      try {
        final Uri? expanded = await _expandShortLink(candidate);
        final BilibiliVideoDeepLinkTarget? expandedTarget = expanded == null
            ? null
            : BilibiliDeepLinkParser.parse(expanded.toString());
        if (expandedTarget != null) {
          return expandedTarget;
        }
      } catch (_) {
        // 分享入口不能因为短链网络失败而打断应用启动或剪贴板监听。
      }
    }
    return null;
  }

  /// 提取文本中的 HTTP(S) 链接并去掉常见句末标点，保持原出现顺序。
  static List<Uri> extractWebLinks(String rawText) {
    final List<Uri> links = <Uri>[];
    for (final RegExpMatch match in _webLinkPattern.allMatches(rawText)) {
      String value = match.group(0)!;
      while (value.isNotEmpty &&
          _trailingPunctuation.contains(value[value.length - 1])) {
        value = value.substring(0, value.length - 1);
      }
      final Uri? uri = Uri.tryParse(value);
      if (uri != null && uri.host.isNotEmpty) {
        links.add(uri);
      }
    }
    return List<Uri>.unmodifiable(links);
  }

  /// 仅请求 `b23.tv` 并跟随有限次重定向，最终地址仍由严格视频解析器校验。
  static Future<Uri?> _expandB23Link(Uri shortLink) async {
    if (shortLink.scheme != 'https' ||
        shortLink.host.toLowerCase() != _shortLinkHost) {
      return null;
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final HttpClientRequest request = await client
          .getUrl(shortLink)
          .timeout(const Duration(seconds: 5));
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 FocuBili/1.4',
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      Uri resolved = shortLink;
      for (final RedirectInfo redirect in response.redirects) {
        resolved = resolved.resolveUri(redirect.location);
      }
      await response.drain<void>();
      return resolved;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// 定义应用根组件接收 Android 外部链接所需的最小能力，方便测试替换。
abstract interface class IncomingDeepLinkService {
  /// 注册应用运行期间新链接到达时的回调。
  void setLinkHandler(ValueChanged<String> handler);

  /// 取出冷启动 Activity 携带的一次性初始链接。
  Future<String?> takeInitialLink();

  /// 解除原生通道监听并释放页面回调。
  void dispose();
}

/// 通过 Android MethodChannel 接收冷启动和 `singleTask` 新 Intent。
class BilibiliDeepLinkService implements IncomingDeepLinkService {
  /// 创建深链服务；测试可以注入不会访问 Android 的方法通道。
  BilibiliDeepLinkService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'focubili/deep_links';
  final MethodChannel _channel;
  ValueChanged<String>? _handler;

  /// 注册运行期回调，并让原生侧可以把后续 Intent 主动推送到 Flutter。
  @override
  void setLinkHandler(ValueChanged<String> handler) {
    _handler = handler;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 读取并消费原生 Activity 保存的冷启动链接；非 Android 测试环境安全返回空值。
  @override
  Future<String?> takeInitialLink() async {
    try {
      return await _channel.invokeMethod<String>('getInitialLink');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 接收 Activity 运行期间送来的新链接，并忽略未知方法或空参数。
  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onDeepLink' || call.arguments is! String) {
      return;
    }
    final String link = (call.arguments as String).trim();
    if (link.isNotEmpty) {
      _handler?.call(link);
    }
  }

  /// 清除回调和方法处理器，避免根组件销毁后仍接收外部 Intent。
  @override
  void dispose() {
    _handler = null;
    _channel.setMethodCallHandler(null);
  }
}
