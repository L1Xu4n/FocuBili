/// 集中保存 B 站网页和公开接口请求需要保持一致的来源信息。
abstract final class BilibiliRequestPolicy {
  /// B 站官方 H5 登录入口，直接加载移动版资源并隐藏网页自己的冗余导航栏。
  static final Uri officialMobileLoginUri = Uri.https(
    'passport.bilibili.com',
    '/h5-app/passport/login',
    <String, String>{'navhide': '1'},
  );

  /// 无法读取设备 WebView UA 时使用的移动端安全回退值。
  static const String fallbackMobileWebUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static const String _bilibiliWebHost = 'www.bilibili.com';
  static const String _searchReferer = 'https://search.bilibili.com/';
  static const String _rootReferer = 'https://www.bilibili.com/';
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  /// 保留设备真实 WebView 版本，只在平板默认 UA 缺少 Mobile 标记时补上该标记。
  static String ensureMobileWebUserAgent(String? defaultUserAgent) {
    final String normalized = defaultUserAgent?.trim() ?? '';
    if (normalized.isEmpty) {
      return fallbackMobileWebUserAgent;
    }
    if (RegExp(r'\bMobile\b', caseSensitive: false).hasMatch(normalized)) {
      return normalized;
    }
    final int safariIndex = normalized.toLowerCase().lastIndexOf(' safari/');
    if (safariIndex >= 0) {
      return normalized.replaceRange(safariIndex, safariIndex, ' Mobile');
    }
    return '$normalized Mobile';
  }

  /// 根据公开接口地址生成对应网页来源，详情和标签请求使用精确视频页防止 HTTP 412。
  static String publicJsonReferer(Uri endpoint) {
    if (endpoint.path == '/x/web-interface/wbi/search/type') {
      return _searchReferer;
    }
    if (endpoint.path == '/x/web-interface/view' ||
        endpoint.path == '/x/tag/archive/tags') {
      final String bvid = endpoint.queryParameters['bvid']?.trim() ?? '';
      if (_bvidPattern.hasMatch(bvid)) {
        return Uri.https(_bilibiliWebHost, '/video/$bvid/').toString();
      }
    }
    return _rootReferer;
  }

  /// 生成公开 JSON 请求允许携带的最小请求头，明确不加入 Cookie 或设备指纹。
  static Map<String, String> publicJsonHeaders(
    Uri endpoint, {
    required String userAgent,
  }) {
    return Map<String, String>.unmodifiable(<String, String>{
      'Accept': 'application/json',
      'User-Agent': userAgent,
      'Referer': publicJsonReferer(endpoint),
    });
  }
}
