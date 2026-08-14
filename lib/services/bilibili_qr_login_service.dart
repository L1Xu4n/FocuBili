import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bilibili_auth_service.dart';

/// 保存 B 站官方扫码登录二维码内容和后续轮询使用的一次性键。
class BilibiliQrLoginSession {
  /// 创建已经通过 HTTPS 与字段校验的扫码登录会话。
  const BilibiliQrLoginSession({required this.url, required this.key});

  final String url;
  final String key;
}

/// 列出扫码登录轮询可能返回的稳定状态。
enum BilibiliQrLoginStatus {
  /// 二维码尚未被手机扫描。
  waiting,

  /// 手机已经扫描，等待用户在 B 站 App 确认。
  scanned,

  /// 用户确认成功，响应已带回可验证 Cookie。
  confirmed,

  /// 二维码过期，需要生成新会话。
  expired,
}

/// 保存一次轮询结果；只有 confirmed 状态才允许携带临时 Cookie 请求头。
class BilibiliQrLoginPollResult {
  /// 创建扫码登录状态与用户可读说明。
  const BilibiliQrLoginPollResult({
    required this.status,
    required this.message,
    this.cookieHeader = '',
  });

  final BilibiliQrLoginStatus status;
  final String message;
  final String cookieHeader;
}

/// 保存扫码登录 HTTP 状态、正文和 Set-Cookie 解析结果，便于无网络测试。
class BilibiliQrHttpResponse {
  /// 创建一条未经过业务解释的扫码登录响应。
  const BilibiliQrHttpResponse({
    required this.statusCode,
    required this.body,
    this.cookies = const <String>[],
  });

  final int statusCode;
  final String body;
  final List<String> cookies;
}

/// 定义扫码登录 HTTP 请求函数，测试可注入固定响应。
typedef BilibiliQrHttpRequest =
    Future<BilibiliQrHttpResponse> Function(Uri endpoint);

/// 表示扫码登录暂时无法继续，并确保错误文字不包含 Cookie 或二维码密钥。
class BilibiliQrLoginException implements Exception {
  /// 创建可直接展示的扫码登录错误。
  const BilibiliQrLoginException(this.message);

  final String message;

  /// 返回用户可读错误说明。
  @override
  String toString() => message;
}

/// 调用 B 站官方网页扫码接口生成二维码并轮询确认结果。
class BilibiliQrLoginService {
  /// 创建扫码登录服务；正式环境只访问固定 HTTPS 主机，测试可注入响应函数。
  BilibiliQrLoginService({BilibiliQrHttpRequest? request})
    : _request = request ?? _requestOfficialEndpoint;

  final BilibiliQrHttpRequest _request;

  /// 生成新的官方扫码会话，并拒绝空地址、非 HTTPS 地址或缺失轮询键。
  Future<BilibiliQrLoginSession> generate() async {
    final BilibiliQrHttpResponse response = await _request(
      Uri.https(
        'passport.bilibili.com',
        '/x/passport-login/web/qrcode/generate',
      ),
    );
    final Map<Object?, Object?> data = _readSuccessfulData(response);
    final String url = _readText(data['url']);
    final String key = _readText(data['qrcode_key']);
    final Uri? parsedUrl = Uri.tryParse(url);
    if (parsedUrl == null || parsedUrl.scheme != 'https' || key.isEmpty) {
      throw const BilibiliQrLoginException('扫码登录服务返回了无效二维码，请重试。');
    }
    return BilibiliQrLoginSession(url: url, key: key);
  }

  /// 使用一次性键查询扫码状态，确认成功时把响应 Cookie 合并成只存在内存中的请求头。
  Future<BilibiliQrLoginPollResult> poll(String key) async {
    final String normalizedKey = key.trim();
    if (normalizedKey.isEmpty || normalizedKey.length > 256) {
      throw const BilibiliQrLoginException('扫码登录会话无效，请刷新二维码。');
    }
    final BilibiliQrHttpResponse response = await _request(
      Uri.https(
        'passport.bilibili.com',
        '/x/passport-login/web/qrcode/poll',
        <String, String>{'qrcode_key': normalizedKey},
      ),
    );
    final Map<Object?, Object?> data = _readSuccessfulData(response);
    final int statusCode = (data['code'] as num?)?.toInt() ?? -1;
    switch (statusCode) {
      case 0:
        final String cookieHeader = response.cookies
            .map((String cookie) => cookie.trim())
            .where((String cookie) => cookie.isNotEmpty)
            .join('; ');
        if (!_containsSessionCookie(cookieHeader)) {
          throw const BilibiliQrLoginException('扫码已确认，但登录会话不完整，请刷新后重试。');
        }
        return BilibiliQrLoginPollResult(
          status: BilibiliQrLoginStatus.confirmed,
          message: '登录成功，正在读取账号资料…',
          cookieHeader: cookieHeader,
        );
      case 86090:
        return const BilibiliQrLoginPollResult(
          status: BilibiliQrLoginStatus.scanned,
          message: '已扫码，请在手机 B 站 App 中确认登录。',
        );
      case 86038:
        return const BilibiliQrLoginPollResult(
          status: BilibiliQrLoginStatus.expired,
          message: '二维码已过期，请刷新。',
        );
      case 86101:
        return const BilibiliQrLoginPollResult(
          status: BilibiliQrLoginStatus.waiting,
          message: '请使用手机 B 站 App 扫描二维码。',
        );
      default:
        return const BilibiliQrLoginPollResult(
          status: BilibiliQrLoginStatus.waiting,
          message: '正在等待扫码确认…',
        );
    }
  }

  /// 校验 HTTP、业务错误码和 data 对象，统一返回可安全解析的字典。
  Map<Object?, Object?> _readSuccessfulData(BilibiliQrHttpResponse response) {
    if (response.statusCode != HttpStatus.ok) {
      throw BilibiliQrLoginException(
        '扫码登录服务暂时不可用（HTTP ${response.statusCode}）。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const BilibiliQrLoginException('扫码登录数据无法解析，请稍后重试。');
    }
    if (decoded is! Map) {
      throw const BilibiliQrLoginException('扫码登录数据无法解析，请稍后重试。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    final Object? rawData = root['data'];
    if (code != 0 || rawData is! Map) {
      throw const BilibiliQrLoginException('扫码登录服务拒绝了本次请求，请稍后重试。');
    }
    return Map<Object?, Object?>.from(rawData);
  }

  /// 检查成功响应是否确实包含非空 SESSDATA，不读取或输出它的具体内容。
  bool _containsSessionCookie(String cookieHeader) {
    return RegExp(
      r'(^|;\s*)SESSDATA=([^;]+)',
      caseSensitive: false,
    ).hasMatch(cookieHeader);
  }

  /// 把未知 JSON 字段安全转换为去除首尾空白的文字。
  String _readText(Object? value) => value is String ? value.trim() : '';

  /// 使用桌面 UA 请求固定 B 站扫码接口，并仅提取 Cookie 名值对供后续官方验证。
  static Future<BilibiliQrHttpResponse> _requestOfficialEndpoint(
    Uri endpoint,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        BilibiliHttpAuthApi.desktopUserAgent,
      );
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://passport.bilibili.com/',
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final String body = await response.transform(utf8.decoder).join();
      final List<String> cookies = response.cookies
          .map((Cookie cookie) => '${cookie.name}=${cookie.value}')
          .toList(growable: false);
      return BilibiliQrHttpResponse(
        statusCode: response.statusCode,
        body: body,
        cookies: cookies,
      );
    } on TimeoutException {
      throw const BilibiliQrLoginException('扫码登录请求超时，请检查网络。');
    } on SocketException {
      throw const BilibiliQrLoginException('无法连接扫码登录服务，请检查网络。');
    } finally {
      client.close(force: true);
    }
  }
}
