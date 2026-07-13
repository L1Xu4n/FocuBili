import 'dart:async';
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

/// 列出“我的”页面可区分的 B 站会话状态。
enum BilibiliSessionStatus {
  /// 本机没有可用的登录 Cookie。
  signedOut,

  /// Cookie 已被官方接口确认，账号可以正常使用。
  active,

  /// 本机仍有会话 Cookie，但官方接口明确表示未登录。
  expired,

  /// 网络、服务器或本机桥接暂时无法确认会话，绝不能据此清除 Cookie。
  networkError,
}

/// 保存一次会话检查的结果，避免页面把“未登录”和“暂时不可用”混为一谈。
class BilibiliSessionState {
  /// 创建携带状态、可选账号资料和可展示说明的会话检查结果。
  const BilibiliSessionState({
    required this.status,
    this.account,
    this.message,
  });

  /// 创建本机没有登录 Cookie 时使用的未登录结果。
  const BilibiliSessionState.signedOut()
      : status = BilibiliSessionStatus.signedOut,
        account = null,
        message = null;

  /// 创建官方接口已经确认登录成功时使用的结果。
  const BilibiliSessionState.active(this.account)
      : status = BilibiliSessionStatus.active,
        message = null;

  /// 创建 Cookie 存在但官方接口明确拒绝登录时使用的过期结果。
  const BilibiliSessionState.expired({
    this.message = '登录已过期，请重新登录。',
  })  : status = BilibiliSessionStatus.expired,
        account = null;

  /// 创建暂时无法验证会话时使用的结果，保留 Cookie 供稍后重试。
  const BilibiliSessionState.networkError({
    this.message = '暂时无法读取登录状态，请检查网络后重试。',
  })  : status = BilibiliSessionStatus.networkError,
        account = null;

  final BilibiliSessionStatus status;
  final BilibiliAccount? account;
  final String? message;

  /// 判断该结果是否包含已被官方确认的账号资料。
  bool get isActive =>
      status == BilibiliSessionStatus.active && account != null;
}

/// 表示登录操作无法继续，并携带不包含 Cookie 内容的中文说明。
class BilibiliAuthException implements Exception {
  /// 创建一条不会暴露 Cookie 内容的登录错误说明。
  const BilibiliAuthException(this.message);

  final String message;

  /// 把异常转换成页面和调试器都容易阅读的文字。
  @override
  String toString() => message;
}

/// 表示账号状态接口的一次 HTTP 响应，便于服务层解析和单元测试替换网络。
class BilibiliNavResponse {
  /// 创建包含状态码和 JSON 正文的账号状态接口响应。
  const BilibiliNavResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

/// 抽象出请求 B 站账号状态接口的能力，测试时可用固定响应代替真实网络。
abstract interface class BilibiliAuthApi {
  /// 使用传入的 Cookie 请求官方账号状态接口，且不得记录 Cookie 内容。
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader);
}

/// 抽象出 Android WebView Cookie 容器，防止业务层保存 Cookie 原文或账号列表。
abstract interface class BilibiliCookieStore {
  /// 读取 B 站域可用于请求的 Cookie 请求头。
  Future<String> readCookies();

  /// 清理旧 B 站 Cookie 后写入已验证的新 Cookie，完成单账号替换。
  Future<void> replaceCookies(String cookieHeader);

  /// 仅清理 B 站域 Cookie，不影响同一 WebView 中其他网站的数据。
  Future<void> clearBilibiliCookies();
}

/// 通过 Android 方法通道访问应用 WebView Cookie 容器的默认实现。
class PlatformBilibiliCookieStore implements BilibiliCookieStore {
  /// 创建使用 FocuBili Android 登录通道的 Cookie 存储实现。
  const PlatformBilibiliCookieStore();

  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/auth',
  );

  /// 从 Android WebView 的 B 站域读取 Cookie，不在 Dart 中持久化副本。
  @override
  Future<String> readCookies() async {
    final String? cookie = await _channel.invokeMethod<String>('readCookies');
    return cookie?.trim() ?? '';
  }

  /// 调用原生原子替换操作，只在新 Cookie 已被官方验证后保存。
  @override
  Future<void> replaceCookies(String cookieHeader) {
    return _channel.invokeMethod<void>(
      'replaceCookies',
      <String, Object?>{'cookie': cookieHeader},
    );
  }

  /// 调用原生仅清理 B 站域 Cookie 的操作，用于退出和切换账号。
  @override
  Future<void> clearBilibiliCookies() {
    return _channel.invokeMethod<void>('clearBilibiliCookies');
  }
}

/// 使用 Dart HttpClient 请求官方账号状态接口的默认网络实现。
class BilibiliHttpAuthApi implements BilibiliAuthApi {
  /// 创建使用官方账号状态地址的网络客户端。
  BilibiliHttpAuthApi({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  static final Uri _accountEndpoint = Uri.https(
    'api.bilibili.com',
    '/x/web-interface/nav',
  );
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  final HttpClient Function() _clientFactory;

  /// 携带指定 Cookie 请求官方账号状态接口，并返回未经业务解释的响应。
  @override
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader) async {
    final HttpClient client = _clientFactory();
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
      return BilibiliNavResponse(
        statusCode: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// 验证 B 站会话、导入已验证 Cookie，并且永不保存多账号或密码资料。
class BilibiliAuthService {
  /// 创建可替换网络和 Cookie 容器的登录服务，默认使用 Android 与真实官方接口。
  BilibiliAuthService({
    BilibiliCookieStore? cookieStore,
    BilibiliAuthApi? api,
  })  : _cookieStore = cookieStore ?? const PlatformBilibiliCookieStore(),
        _api = api ?? BilibiliHttpAuthApi();

  final BilibiliCookieStore _cookieStore;
  final BilibiliAuthApi _api;

  /// 读取当前 WebView 会话，并明确返回未登录、已过期、可用或暂时不可用。
  Future<BilibiliSessionState> loadCurrentSession() async {
    try {
      final String cookieHeader = await readCookieHeader();
      if (!_containsSessionCookie(cookieHeader)) {
        return const BilibiliSessionState.signedOut();
      }
      return _requestCurrentSession(cookieHeader);
    } on PlatformException {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取本机登录状态，请稍后重试。',
      );
    } on MissingPluginException {
      return const BilibiliSessionState.networkError(
        message: '当前设备暂不支持读取登录状态，请稍后重试。',
      );
    } catch (_) {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取本机登录状态，请稍后重试。',
      );
    }
  }

  /// 兼容旧调用方：只在会话确认为有效时返回账号，其余状态返回 null。
  Future<BilibiliAccount?> loadCurrentAccount() async {
    return (await loadCurrentSession()).account;
  }

  /// 先用官方接口验证用户粘贴的 Cookie，成功后才替换本机 B 站 Cookie。
  Future<BilibiliAccount> loginWithCookie(String rawCookie) async {
    final String cookie = rawCookie.trim();
    if (!_containsSessionCookie(cookie)) {
      throw const BilibiliAuthException(
        'Cookie 中没有找到有效的 SESSDATA，无法建立登录状态。',
      );
    }
    final BilibiliSessionState verifiedSession =
        await _requestCurrentSession(cookie);
    if (verifiedSession.status == BilibiliSessionStatus.networkError) {
      throw BilibiliAuthException(
        verifiedSession.message ?? '暂时无法验证 Cookie，请检查网络后重试。',
      );
    }
    if (!verifiedSession.isActive) {
      throw const BilibiliAuthException('Cookie 已失效，B 站没有确认登录状态。');
    }
    try {
      await _cookieStore.replaceCookies(cookie);
    } on PlatformException {
      throw const BilibiliAuthException('Cookie 已验证，但暂时无法保存到本机，请重试。');
    } on MissingPluginException {
      throw const BilibiliAuthException('当前设备暂不支持保存 Cookie，请稍后重试。');
    } catch (_) {
      throw const BilibiliAuthException('Cookie 已验证，但暂时无法保存到本机，请重试。');
    }
    return verifiedSession.account!;
  }

  /// 从 Android WebView 的 B 站域读取 Cookie 请求头，不在 Dart 中持久化副本。
  Future<String> readCookieHeader() => _cookieStore.readCookies();

  /// 仅清理 B 站域 Cookie，用于退出或切换账号，不会自动响应网络错误。
  Future<void> clearBilibiliSession() => _cookieStore.clearBilibiliCookies();

  /// 保留退出登录名称，实际执行仅清理 B 站域 Cookie 的安全操作。
  Future<void> logout() => clearBilibiliSession();

  /// 判断 Cookie 请求头中是否包含非空的登录会话标识，不读取或输出具体值。
  bool _containsSessionCookie(String cookie) {
    final RegExpMatch? match = RegExp(
      r'(^|;\s*)SESSDATA=([^;]+)',
      caseSensitive: false,
    ).firstMatch(cookie);
    return match?.group(2)?.trim().isNotEmpty ?? false;
  }

  /// 请求账号状态接口，并把官方明确的未登录结果和暂时故障分开处理。
  Future<BilibiliSessionState> _requestCurrentSession(
    String cookieHeader,
  ) async {
    try {
      final BilibiliNavResponse response = await _api.requestNavigation(
        cookieHeader,
      );
      if (response.statusCode != HttpStatus.ok) {
        return BilibiliSessionState.networkError(
          message: '登录状态服务暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      return _parseCurrentSession(response.body);
    } on SocketException {
      return const BilibiliSessionState.networkError(
        message: '无法连接到登录状态服务，请检查网络。',
      );
    } on HttpException {
      return const BilibiliSessionState.networkError(
        message: '登录状态网络响应异常，请稍后重试。',
      );
    } on TimeoutException {
      return const BilibiliSessionState.networkError(
        message: '验证登录状态超时，请检查网络后重试。',
      );
    } on FormatException {
      return const BilibiliSessionState.networkError(
        message: '登录状态数据无法解析，请稍后重试。',
      );
    } catch (_) {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取登录状态，请稍后重试。',
      );
    }
  }

  /// 解析账号状态 JSON；只有官方明确的未登录信号才会被判断为会话过期。
  BilibiliSessionState _parseCurrentSession(String responseText) {
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw const FormatException('账号状态根节点不是对象。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    final Object? rawData = root['data'];
    if (code == -101) {
      return const BilibiliSessionState.expired();
    }
    if (code != 0 || rawData is! Map) {
      return const BilibiliSessionState.networkError(
        message: '登录状态服务暂时不可用，请稍后重试。',
      );
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    if (data['isLogin'] != true) {
      return const BilibiliSessionState.expired();
    }
    return BilibiliSessionState.active(
      BilibiliAccount(
        mid: (data['mid'] as num?)?.toInt() ?? 0,
        name: _readText(data['uname'], '已登录用户'),
        avatarUrl: _normalizeHttpsUrl(_readText(data['face'], '')),
      ),
    );
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
