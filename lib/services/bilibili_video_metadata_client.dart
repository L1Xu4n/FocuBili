import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/video_metadata_request_diagnostic.dart';
import 'app_http_client.dart';
import 'bilibili_auth_service.dart';
import 'bilibili_lookup_exception.dart';
import 'bilibili_request_policy.dart';
import 'bilibili_http_user_agent.dart';
import 'http_user_agent_preferences.dart';
import 'bilibili_wbi_signing_service.dart';
import 'cache_lifecycle.dart';
import 'problem_diagnostics_service.dart';

class VideoMetadataResponse {
  const VideoMetadataResponse(
    this.statusCode,
    this.body, {
    this.cookies = const [],
  });
  final int statusCode;
  final String body;
  final List<String> cookies;
}

typedef VideoMetadataTransport =
    Future<VideoMetadataResponse> Function(
      Uri endpoint,
      Map<String, String> headers,
    );

/// 保存通过官方接口和调用方解析验证的成功正文，按最近使用顺序淘汰。
class BilibiliVideoMetadataCache {
  /// 允许测试注入私有缓存和时钟。
  BilibiliVideoMetadataCache({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _clock;
  final _bodies = <Object, (DateTime, String)>{};
  final _pending = <Object, (Future<String>, Map<String, Object?>)>{};
  int _revision = CacheLifecycle.account.value;

  /// 首次访问新账号时释放旧正文与在途工作。
  void _syncAccount() {
    if (_revision == CacheLifecycle.account.value) return;
    _revision = CacheLifecycle.account.value;
    _bodies.clear();
    _pending.clear();
  }

  /// 读取有效正文并提升到最近使用位置。
  String? _read(Object key) {
    final entry = _bodies.remove(key);
    if (entry == null || !_clock().isBefore(entry.$1)) return null;
    _bodies[key] = entry;
    return entry.$2;
  }

  /// 保存正文并维持固定条目上限。
  void _write(Object key, String body) {
    if (maxEntries <= 0) return;
    _bodies.remove(key);
    _bodies[key] = (_clock().add(ttl), body);
    while (_bodies.length > maxEntries) {
      _bodies.remove(_bodies.keys.first);
    }
  }
}

/// 请求、解析及结果交付均使用同一份受保护的会话快照。
class BilibiliVideoMetadataClient {
  /// 默认客户端共享缓存，注入传输时默认使用隔离缓存与签名器。
  BilibiliVideoMetadataClient({
    BilibiliAuthService? authService,
    VideoMetadataTransport? transport,
    ProblemDiagnosticsService? diagnostics,
    BilibiliVideoMetadataCache? cache,
  }) : _auth = authService ?? BilibiliAuthService(),
       _transport = transport ?? _get,
       _cache =
           cache ??
           (transport == null && authService == null
               ? _sharedCache
               : BilibiliVideoMetadataCache()),
       _signer = transport == null
           ? BilibiliWbiSigningService.shared
           : BilibiliWbiSigningService(
               requestJson: (_, _) async => throw const WbiSigningException(),
             ),
       _diagnostics = diagnostics ?? ProblemDiagnosticsService();

  static final _sharedCache = _createSharedCache();

  /// 在账号切换或登出时立即丢弃线上正文与在途请求表。
  static BilibiliVideoMetadataCache _createSharedCache() {
    final cache = BilibiliVideoMetadataCache();
    CacheLifecycle.account.addListener(cache._syncAccount);
    return cache;
  }

  final BilibiliAuthService _auth;
  final VideoMetadataTransport _transport;
  final ProblemDiagnosticsService _diagnostics;
  final BilibiliVideoMetadataCache _cache;
  final BilibiliWbiSigningService _signer;
  static int _requestId = 0;
  static const viewPath = '/x/web-interface/wbi/view';
  static const partsPath = '/x/player/pagelist';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 共享已校验正文，每个调用方独立解析和验证交付。
  Future<T> load<T extends Object>({
    required String bvid,
    required bool details,
    required FutureOr<T> Function(String body) parse,
    Future<T?> Function()? offlineFallback,
  }) async {
    final facts = <String, Object?>{
      'request_id': ++_requestId,
      'stage': 'cookie',
      'outcome': 'error',
      'session_read': 'error',
      'session_source': _auth.cookieStoreSource,
      'wbi_signed': false,
      'dedup_shared': false,
      'endpoint_kind': details ? 'view_wbi' : 'pagelist',
    };
    BilibiliPlaybackSession? captured;
    try {
      final session = await _auth.capturePlaybackSession(
        details ? viewPath : partsPath,
      );
      captured = session;
      facts['session_read'] = 'ok';
      facts['auth_state'] = session.snapshot.state == 'session'
          ? 'session_present_unverified'
          : 'anonymous';
      final customUserAgent = await const HttpUserAgentPreferences()
          .forRequest();
      // Changing this optional header must not attach new requests to an
      // in-flight response from a different preference. The WBI material
      // cache remains scoped by authorization only.
      final key = (session.scopeKey, bvid, details, customUserAgent);
      await session.validate();
      _cache._syncAccount();
      final cachedBody = _cache._read(key);
      if (cachedBody != null) {
        facts['stage'] = 'parse';
        final result = await parse(cachedBody);
        await session.validate();
        facts['stage'] = 'complete';
        facts['outcome'] = 'success';
        return result;
      }
      final pending = _cache._pending;
      var work = pending[key];
      if (work == null) {
        work = (_load(bvid, details, session, facts, customUserAgent), facts);
        pending[key] = work;
        final created = work;
        // The listener consumes both outcomes and cannot leak an unhandled error.
        unawaited(
          work.$1.then<void>(
            (_) {
              if (identical(pending[key], created)) pending.remove(key);
            },
            onError: (Object _, StackTrace _) {
              if (identical(pending[key], created)) pending.remove(key);
            },
          ),
        );
      } else {
        facts['dedup_shared'] = true;
      }
      final String body;
      try {
        body = await work.$1;
      } finally {
        // Shared calls report the actual signed transport, not an invented
        // unsigned request. Preserve each caller's own id and dedup flag.
        for (final key in [
          'endpoint_kind',
          'stage',
          'wbi_signed',
          'http_status',
          'api_code',
        ]) {
          if (work.$2.containsKey(key)) facts[key] = work.$2[key];
        }
      }
      await session.validate();
      facts['stage'] = 'parse';
      final result = await parse(body);
      await session.validate();
      _cache._write(key, body);
      facts['stage'] = 'complete';
      facts['outcome'] = 'success';
      return result;
    } catch (caught) {
      Object error = caught;
      try {
        await captured?.validate();
      } catch (changed) {
        error = changed;
      }
      if (error is BilibiliPlaybackSessionException) {
        facts['session_read'] = error.state;
        throw error;
      }
      if (error is BilibiliRequestFailure) {
        if (error.httpStatus != null) facts['http_status'] = error.httpStatus;
        if (error.apiCode != null) facts['api_code'] = error.apiCode;
      }
      // Existing completed downloads can still open offline, under the same fence.
      if (captured != null && offlineFallback != null) {
        final T? cached;
        try {
          cached = await offlineFallback();
          await captured.validate();
        } on BilibiliPlaybackSessionException catch (changed) {
          facts['session_read'] = changed.state;
          rethrow;
        }
        if (cached != null) {
          facts['offline_cache'] = true;
          return cached;
        }
      }
      if (error is BilibiliLookupException) throw error;
      throw BilibiliLookupException(
        facts['stage'] == 'signing'
            ? '视频详情签名材料暂时不可用，请稍后重试。'
            : '视频资料请求未完成，请检查网络后重试。',
        httpStatus: error is BilibiliRequestFailure ? error.httpStatus : null,
        apiCode: error is BilibiliRequestFailure ? error.apiCode : null,
      );
    } finally {
      try {
        unawaited(
          _diagnostics
              .recordVideoMetadataRequest(
                VideoMetadataRequestDiagnostic.fromMap(facts)!,
                details: details,
              )
              .catchError((Object _) {}),
        );
      } catch (_) {
        /* Diagnostics must not change request behavior. */
      }
    }
  }

  /// 使用会话签名并发起详情或分 P 请求。
  Future<String> _load(
    String bvid,
    bool details,
    BilibiliPlaybackSession session,
    Map<String, Object?> facts,
    String? customUserAgent,
  ) async {
    var parameters = <String, String>{'bvid': bvid};
    final path = details ? viewPath : partsPath;
    if (details) {
      facts['stage'] = 'signing';
      facts['endpoint_kind'] = 'nav';
      parameters = await _signer.signParameters(
        parameters,
        headers: const {},
        requestJson: (uri, headers) => _read(uri, session, facts),
        scopeKey: identical(_signer, BilibiliWbiSigningService.shared)
            ? session.signingScopeKey
            : session.scopeKey,
      );
      await session.validate();
      facts['wbi_signed'] = true;
    }
    facts['stage'] = 'request';
    final endpoint = Uri.https(
      'api.bilibili.com',
      path,
    ).replace(query: BilibiliWbiSigningService.encodeQuery(parameters));
    final body = await _read(
      endpoint,
      session,
      facts,
      customUserAgent: customUserAgent,
    );
    await session.validate();
    return body;
  }

  /// 校验 HTTP 和业务结果，保留响应中的多值 Cookie。
  Future<String> _read(
    Uri uri,
    BilibiliPlaybackSession session,
    Map<String, Object?> facts, {
    String? customUserAgent,
  }) async {
    facts.remove('http_status');
    facts.remove('api_code');
    facts['endpoint_kind'] = uri.path == '/x/web-interface/nav'
        ? 'nav'
        : uri.path == viewPath
        ? 'view_wbi'
        : 'pagelist';
    final cookie = await session.headerFor(uri.path);
    final headers = <String, String>{
      ...BilibiliRequestPolicy.publicJsonHeaders(
        uri,
        userAgent: BilibiliHttpUserAgent.allowsMetadata(uri)
            ? customUserAgent ?? _userAgent
            : _userAgent,
      ),
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final response = await _transport(uri, headers);
    await session.validate();
    facts['http_status'] = response.statusCode;
    // HTTP errors never parse a server body as a business result.
    if (response.statusCode != HttpStatus.ok) {
      throw BilibiliLookupException(
        '视频资料接口暂时不可用（HTTP ${response.statusCode}）。',
        httpStatus: response.statusCode,
      );
    }
    final root = jsonDecode(response.body);
    if (root is! Map || root['code'] is! int) {
      throw const BilibiliLookupException('视频资料接口返回的数据格式不正确。');
    }
    final code = root['code'] as int;
    facts['api_code'] = code;
    if (code != 0 && !(uri.path == '/x/web-interface/nav' && code == -101)) {
      throw BilibiliLookupException('视频资料请求失败（错误码：$code）。', apiCode: code);
    }
    await session.mergeResponse(uri.path, response.cookies);
    return response.body;
  }

  /// 使用共享连接读取正文和所有 Set-Cookie 响应头。
  static Future<VideoMetadataResponse> _get(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await AppHttpTransport.shared.send(
      uri: uri,
      headers: headers,
      followRedirects: false,
    );
    return VideoMetadataResponse(
      response.statusCode,
      response.bodyUtf8,
      cookies: response.headerValues(HttpHeaders.setCookieHeader),
    );
  }
}
