import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/windows_official_login_service.dart';

/// 创建一条简短 Cookie 测试数据，减少每个用例的重复字段。
WindowsOfficialLoginCookie cookie(
  String name,
  String value, {
  String domain = '.bilibili.com',
  DateTime? expires,
}) {
  return WindowsOfficialLoginCookie(
    name: name,
    value: value,
    domain: domain,
    expires: expires,
  );
}

/// 验证 Windows 官方登录的域名限制与 Cookie 筛选不会泄露外站会话。
void main() {
  /// 验证 Windows 会按与 Android 相同顺序探测网页、API 和 passport 三个 Cookie 范围。
  test('Windows 登录探测三个 B站会话范围', () {
    final List<Uri> uris = buildBilibiliLoginCookieProbeUris();

    expect(uris.first.toString(), 'https://www.bilibili.com/');
    expect(uris.map((Uri uri) => uri.host), <String>[
      'www.bilibili.com',
      'api.bilibili.com',
      'passport.bilibili.com',
    ]);
    expect(uris.last.path, '/h5-app/passport/login');
  });

  /// 验证 Windows 登录明确提供 B站回跳页，让官方 data.url 可以完成会话落地。
  test('Windows H5 登录包含安全的 B站落地地址', () {
    final Uri loginUri = buildWindowsOfficialLoginUri();

    expect(loginUri.host, 'passport.bilibili.com');
    expect(loginUri.path, '/h5-app/passport/login');
    expect(loginUri.queryParameters['navhide'], '1');
    expect(loginUri.queryParameters['gourl'], 'https://www.bilibili.com/');
  });

  /// 验证只允许 B 站与 QQ 官方 HTTPS 主机作为登录窗口的顶层导航目标。
  test('官方登录只允许 B站与 QQ 登录 HTTPS 域名', () {
    expect(
      isAllowedBilibiliLoginUri(
        Uri.parse('https://passport.bilibili.com/h5-app/passport/login'),
      ),
      isTrue,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('https://www.bilibili.com/')),
      isTrue,
    );
    expect(
      isAllowedBilibiliLoginUri(
        Uri.parse('https://graph.qq.com/oauth2.0/show?which=Login'),
      ),
      isTrue,
    );
    expect(
      isAllowedBilibiliLoginUri(
        Uri.parse('https://xui.ptlogin2.qq.com/cgi-bin/xlogin'),
      ),
      isTrue,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('http://passport.bilibili.com/')),
      isFalse,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('https://bilibili.com.evil.test/')),
      isFalse,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('https://graph.qq.com.evil.test/')),
      isFalse,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('https://ptlogin2.qq.com/')),
      isFalse,
    );
    expect(
      isAllowedBilibiliLoginUri(Uri.parse('https://example.com/')),
      isFalse,
    );
  });

  /// 验证构造请求头时仅保留未过期的 B站 Cookie，并剔除外站和非法值。
  test('仅提取有效 B站会话 Cookie', () {
    final DateTime now = DateTime.utc(2026, 8, 12);
    final String header =
        buildBilibiliLoginCookieHeader(<WindowsOfficialLoginCookie>[
          cookie('SESSDATA', 'session-value'),
          cookie('SESSDATA', 'path-specific-session'),
          cookie('bili_jct', 'csrf-value', domain: 'www.bilibili.com'),
          cookie('outside', 'secret', domain: '.example.com'),
          cookie(
            'expired',
            'old',
            expires: now.subtract(const Duration(seconds: 1)),
          ),
          cookie('invalid', 'bad;value'),
        ], now: now);

    expect(header, contains('SESSDATA=session-value'));
    expect(header, contains('SESSDATA=path-specific-session'));
    expect(header, contains('bili_jct=csrf-value'));
    expect(header, isNot(contains('outside')));
    expect(header, isNot(contains('expired')));
    expect(header, isNot(contains('bad;value')));
  });

  /// 验证同名 Cookie 保持 WebView2 返回顺序，不能在 Dart 层按名称互相覆盖。
  test('保留 WebView2 已筛选的同名 Cookie', () {
    final String header = buildBilibiliLoginCookieHeader(
      <WindowsOfficialLoginCookie>[
        cookie('SESSDATA', 'root-session'),
        cookie('SESSDATA', 'specific-session'),
      ],
    );

    expect(header, 'SESSDATA=root-session; SESSDATA=specific-session');
  });

  /// 验证 Windows 像 Android 一样跨三个子域合并 Cookie，后读子域覆盖同名值。
  test('按 Android 顺序合并不同 B站子域 Cookie', () {
    final String header = buildMergedBilibiliLoginCookieHeader(
      <List<WindowsOfficialLoginCookie>>[
        <WindowsOfficialLoginCookie>[
          cookie('DedeUserID', '42', domain: 'www.bilibili.com'),
          cookie('SESSDATA', 'www-session'),
        ],
        <WindowsOfficialLoginCookie>[
          cookie('bili_jct', 'csrf-value', domain: 'api.bilibili.com'),
        ],
        <WindowsOfficialLoginCookie>[
          cookie(
            'SESSDATA',
            'passport-session',
            domain: 'passport.bilibili.com',
          ),
        ],
      ],
    );

    expect(header, contains('DedeUserID=42'));
    expect(header, contains('bili_jct=csrf-value'));
    expect(header, contains('SESSDATA=passport-session'));
    expect(header, isNot(contains('SESSDATA=www-session')));
  });

  /// 验证原生层给会话 Cookie 返回零时间时，Dart 不会把它误判成 1970 年已过期。
  test('WebView 会话 Cookie 不使用零时间作为过期时间', () {
    final WebviewCookie sessionCookie =
        WebviewCookie.fromJson(<String, dynamic>{
          'name': 'SESSDATA',
          'value': 'fresh-session',
          'domain': '.bilibili.com',
          'path': '/',
          'expires': 0,
          'secure': true,
          'httpOnly': true,
          'sessionOnly': true,
        });

    expect(sessionCookie.expires, isNull);
    expect(sessionCookie.toJson()['expires'], isNull);
  });
}
