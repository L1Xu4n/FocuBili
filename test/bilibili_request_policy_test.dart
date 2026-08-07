import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/bilibili_request_policy.dart';

/// 验证网页登录 UA 与公开接口来源页在手机和平板上保持一致。
void main() {
  /// 登录入口直接选择官方 H5 页面，确保平板横屏也不会加载桌面 bundle。
  test('官方网页登录使用 H5 移动入口', () {
    expect(
      BilibiliRequestPolicy.officialMobileLoginUri.host,
      'passport.bilibili.com',
    );
    expect(
      BilibiliRequestPolicy.officialMobileLoginUri.path,
      '/h5-app/passport/login',
    );
    expect(
      BilibiliRequestPolicy.officialMobileLoginUri.queryParameters['navhide'],
      '1',
    );
  });

  /// 平板 UA 只补 Mobile 标记并保留真实内核版本，手机 UA 不会重复修改。
  test('官方网页登录为平板 UA 补充 Mobile 标记', () {
    const String tabletUserAgent =
        'Mozilla/5.0 (Linux; Android 15; Tablet) AppleWebKit/537.36 '
        'Chrome/140.0.0.0 Safari/537.36';
    const String phoneUserAgent =
        'Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 '
        'Chrome/140.0.0.0 Mobile Safari/537.36';

    final String normalizedTablet =
        BilibiliRequestPolicy.ensureMobileWebUserAgent(tabletUserAgent);
    expect(normalizedTablet, contains('Chrome/140.0.0.0'));
    expect(normalizedTablet, contains('Mobile Safari/537.36'));
    expect(
      BilibiliRequestPolicy.ensureMobileWebUserAgent(phoneUserAgent),
      phoneUserAgent,
    );
    expect(
      BilibiliRequestPolicy.ensureMobileWebUserAgent(null),
      BilibiliRequestPolicy.fallbackMobileWebUserAgent,
    );
  });

  /// 视频详情与标签来源必须指向同一 BV 的网页，避免根域来源触发平台 412。
  test('视频详情和标签使用精确视频页来源', () {
    const String bvid = 'BV1GJ411x7h7';
    final Uri detailEndpoint = Uri.https(
      'api.bilibili.com',
      '/x/web-interface/view',
      <String, String>{'bvid': bvid},
    );
    final Uri tagsEndpoint = Uri.https(
      'api.bilibili.com',
      '/x/tag/archive/tags',
      <String, String>{'bvid': bvid},
    );

    expect(
      BilibiliRequestPolicy.publicJsonReferer(detailEndpoint),
      'https://www.bilibili.com/video/$bvid/',
    );
    expect(
      BilibiliRequestPolicy.publicJsonReferer(tagsEndpoint),
      'https://www.bilibili.com/video/$bvid/',
    );
    final Map<String, String> requestHeaders =
        BilibiliRequestPolicy.publicJsonHeaders(
          detailEndpoint,
          userAgent: 'FocuBili test UA',
        );
    expect(requestHeaders['Accept'], 'application/json');
    expect(requestHeaders['User-Agent'], 'FocuBili test UA');
    expect(requestHeaders['Referer'], 'https://www.bilibili.com/video/$bvid/');
    expect(
      requestHeaders.keys.map((String key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
  });

  /// 搜索仍使用搜索首页，异常 BV 参数则安全回退到 B 站根页面。
  test('搜索和异常接口使用安全固定来源', () {
    final Uri searchEndpoint = Uri.https(
      'api.bilibili.com',
      '/x/web-interface/wbi/search/type',
    );
    final Uri invalidDetailEndpoint = Uri.https(
      'api.bilibili.com',
      '/x/web-interface/view',
      <String, String>{'bvid': 'not-a-bvid'},
    );

    expect(
      BilibiliRequestPolicy.publicJsonReferer(searchEndpoint),
      'https://search.bilibili.com/',
    );
    expect(
      BilibiliRequestPolicy.publicJsonReferer(invalidDetailEndpoint),
      'https://www.bilibili.com/',
    );
  });
}
