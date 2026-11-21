import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/video_metadata_request_diagnostic.dart';
import 'bilibili_auth_service.dart';
import 'bilibili_lookup_exception.dart';
import 'bilibili_request_policy.dart';
import 'bilibili_http_user_agent.dart';
import 'http_user_agent_preferences.dart';
import 'bilibili_wbi_signing_service.dart';
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

/// A single guarded session covers nav, signed details, parsing and publication.
/// Only concurrent work is shared; completed metadata and credentials aren't cached.
class BilibiliVideoMetadataClient {
  BilibiliVideoMetadataClient({
    BilibiliAuthService? authService,
    VideoMetadataTransport? transport,
    ProblemDiagnosticsService? diagnostics,
  }) : _auth = authService ?? BilibiliAuthService(),
       _transport = transport ?? _get,
       _diagnostics = diagnostics ?? ProblemDiagnosticsService();

  final BilibiliAuthService _auth;
  final VideoMetadataTransport _transport;
  final ProblemDiagnosticsService _diagnostics;
  final Map<Object, (Future<String>, Map<String, Object?>)> _pending = {};
  Object? _signingScope;
  BilibiliWbiSigningService? _signer;
  static int _requestId = 0;
  static const viewPath = '/x/web-interface/wbi/view';
  static const partsPath = '/x/player/pagelist';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

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
      var work = _pending[key];
      if (work == null) {
        work = (_load(bvid, details, session, facts, customUserAgent), facts);
        _pending[key] = work;
        // The listener consumes both outcomes and cannot leak an unhandled error.
        unawaited(
          work.$1.then<void>(
            (_) {
              _pending.remove(key);
            },
            onError: (Object _, StackTrace _) {
              _pending.remove(key);
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
      if (_signingScope != session.scopeKey) {
        _signingScope = session.scopeKey;
        _signer = BilibiliWbiSigningService(
          // Every call supplies its guarded request below; never retain a session
          // or credential snapshot in the public-material cache.
          requestJson: (_, _) async => throw const WbiSigningException(),
        );
      }
      parameters = await _signer!.signParameters(
        parameters,
        headers: const {},
        requestJson: (uri, headers) => _read(uri, session, facts),
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

  static Future<VideoMetadataResponse> _get(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return VideoMetadataResponse(
        response.statusCode,
        body,
        cookies: response.headers[HttpHeaders.setCookieHeader] ?? const [],
      );
    } finally {
      client.close(force: true);
    }
  }
}
