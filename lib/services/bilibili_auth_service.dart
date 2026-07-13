import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 保存 B 站登录成功后“我的”页面需要展示的最小账号信息。
class BilibiliAccount {
  /// 创建包含用户编号、昵称和头像地址的账号状态。
  const BilibiliAccount({
    required this.mid,
    required this.name,
    required this.avatarUrl,
  });

  final int mid;
  final String name;
  final String avatarUrl;
}

/// 表示登录状态读取或 Cookie 验证失败，并携带可直接展示的中文说明。
class BilibiliAuthException implements Exception {
  /// 创建一条不会暴露 Cookie 内容的登录错误说明。
  const BilibiliAuthException(this.message);

  final String message;

  /// 把异常转换成页面和调试器都容易阅读的文字。
  @override
  String toString() => message;
}

/// 通过 Android WebView Cookie 容器保存会话，并用 B 站账号状态接口验证登录。
class BilibiliAuthService {
  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/auth',
  );
  static final Uri _accountEndpoint = Uri.https(
    'api.bilibili.com',
    '/x/web-interface/nav',
  );
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  /// 读取当前 B 站会话并向账号状态接口验证，未登录时返回 null。
  Future<BilibiliAccount?> loadCurrentAccount() async {
    final String cookieHeader = await readCookieHeader();
    if (!_containsSessionCookie(cookieHeader)) {
      return null;
    }
    return _requestCurrentAccount(cookieHeader);
  }

  /// 把用户主动粘贴的 Cookie 写入应用专用容器，并验证是否真的登录成功。
  Future<BilibiliAccount> loginWithCookie(String rawCookie) async {
    final String cookie = rawCookie.trim();
    if (!_containsSessionCookie(cookie)) {
      throw const BilibiliAuthException(
        'Cookie 中没有找到 SESSDATA，无法建立登录状态。',
      );
    }
    await _channel.invokeMethod<void>(
      'setCookies',
      <String, Object?>{'cookie': cookie},
    );
    final BilibiliAccount? account = await loadCurrentAccount();
    if (account == null) {
      throw const BilibiliAuthException('Cookie 已失效，B 站没有确认登录状态。');
    }
    return account;
  }

  /// 从 Android WebView 的 B 站域名读取 Cookie 请求头，不在 Dart 中持久化副本。
  Future<String> readCookieHeader() async {
    final String? cookie = await _channel.invokeMethod<String>('readCookies');
    return cookie?.trim() ?? '';
  }

  /// 清除本应用 WebView 保存的全部 B 站会话，完成退出登录。
  Future<void> logout() async {
    await _channel.invokeMethod<void>('clearCookies');
  }

  /// 判断 Cookie 请求头中是否包含登录会话标识，匹配时不读取或输出具体值。
  bool _containsSessionCookie(String cookie) {
    return RegExp(r'(^|;\s*)SESSDATA=', caseSensitive: false).hasMatch(cookie);
  }

  /// 携带当前 Cookie 请求账号状态接口，并解析登录用户的最小资料。
  Future<BilibiliAccount?> _requestCurrentAccount(String cookieHeader) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(_accountEndpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      final HttpClientResponse response = await request.close();
      final String responseText = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw BilibiliAuthException(
          '登录状态服务暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      final Object? decoded = jsonDecode(responseText);
      if (decoded is! Map) {
        throw const BilibiliAuthException('登录状态服务返回的数据格式不正确。');
      }
      final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
      final int code = (root['code'] as num?)?.toInt() ?? -1;
      final Object? rawData = root['data'];
      if (code != 0 || rawData is! Map) {
        return null;
      }
      final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
      if (data['isLogin'] != true) {
        return null;
      }
      return BilibiliAccount(
        mid: (data['mid'] as num?)?.toInt() ?? 0,
        name: _readText(data['uname'], '已登录用户'),
        avatarUrl: _normalizeHttpsUrl(_readText(data['face'], '')),
      );
    } on SocketException {
      throw const BilibiliAuthException('无法连接到登录状态服务，请检查网络。');
    } on HttpException {
      throw const BilibiliAuthException('登录状态网络响应异常，请稍后重试。');
    } on FormatException {
      throw const BilibiliAuthException('登录状态数据无法解析，请稍后重试。');
    } finally {
      client.close(force: true);
    }
  }

  /// 把未知字段安全转换为非空文字，空内容使用指定默认值。
  String _readText(Object? value, String fallback) {
    final String text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  /// 只接受 HTTPS 头像地址，并补全 B 站常见的省略协议写法。
  String _normalizeHttpsUrl(String value) {
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    return value.startsWith('https://') ? value : '';
  }
}
