import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 区分共享长连接池用途，避免图片批量拉取挤占 API 请求连接槽位。
enum AppHttpClientPoolKind { api, publicImage }

/// 用于主动取消单次 HTTP 请求（覆盖建连、发送与响应读取三个阶段），绝不影响同池其他请求。
class AppHttpCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// 触发取消并同步通知所有已注册的清理回调。
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final List<void Function()> callbacks = List<void Function()>.of(
      _listeners,
    );
    _listeners.clear();
    for (final void Function() callback in callbacks) {
      try {
        callback();
      } catch (_) {
        // 单个清理回调异常不阻断其他取消动作。
      }
    }
  }

  /// 注册取消监听；若当前已取消则立即同步触发。
  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// 当响应正文（解压后）超过调用方规定的字节上限时抛出。
class AppHttpResponseTooLargeException implements Exception {
  const AppHttpResponseTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'AppHttpResponseTooLargeException(maxBytes: $maxBytes)';
}

/// 当调用方通过 [AppHttpCancelToken] 主动中止请求时抛出。
class AppHttpCancelledException implements Exception {
  const AppHttpCancelledException();

  @override
  String toString() => 'AppHttpCancelledException()';
}

/// 保存单次 HTTP 响应的状态码、原始字节和保留多值的响应头（如多条 Set-Cookie）。
class AppHttpResponse {
  const AppHttpResponse({
    required this.statusCode,
    required this.bytes,
    required this.headers,
    this.redirectLocation,
  });

  final int statusCode;
  final Uint8List bytes;

  /// 全部键名均已转为小写；保留同一头名对应的多条原始值。
  final Map<String, List<String>> headers;

  /// 响应的原始 `Location` 头值（常用于 `followRedirects: false` 的受控跳转）。
  final String? redirectLocation;

  /// 读取单个响应头的首个值（不区分大小写）。
  String? header(String name) {
    final List<String>? values = headers[name.toLowerCase()];
    if (values == null || values.isEmpty) {
      return null;
    }
    return values.first;
  }

  /// 读取指定响应头的全部值（不区分大小写）。
  List<String> headerValues(String name) =>
      headers[name.toLowerCase()] ?? const <String>[];

  /// 以 UTF-8 解码响应正文。
  String get bodyUtf8 => utf8.decode(bytes);
}

/// 进程级共享的 HTTP 长连接池传输层。
///
/// - 绝不维护共享 CookieJar；所有 Cookie、Referer、UA 均由调用方按单次请求显式传入。
/// - 单次请求超时或主动取消只中止当前请求/响应流，绝不对共享池调用 `close(force: true)`。
/// - 默认透明协商 gzip，并按**解压后**的流式字节数严格执行 `maxResponseBytes` 上限。
class AppHttpTransport {
  AppHttpTransport({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory;

  static final AppHttpTransport shared = AppHttpTransport();

  static const Duration defaultIdleTimeout = Duration(seconds: 15);
  static const Duration defaultConnectionTimeout = Duration(seconds: 10);
  static const int defaultMaxConnectionsPerHost = 6;

  final HttpClient Function()? _clientFactory;
  final Map<AppHttpClientPoolKind, HttpClient> _pools =
      <AppHttpClientPoolKind, HttpClient>{};

  HttpClient _obtainPoolClient(AppHttpClientPoolKind kind) {
    return _pools.putIfAbsent(kind, () {
      return HttpClient()
        ..idleTimeout = defaultIdleTimeout
        ..connectionTimeout = defaultConnectionTimeout
        ..maxConnectionsPerHost = defaultMaxConnectionsPerHost
        ..autoUncompress = true;
    });
  }

  /// 执行单次 HTTP 请求（支持 GET/POST、请求体、多值响应头、304 与受控重定向）。
  Future<AppHttpResponse> send({
    required Uri uri,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    List<int>? bodyBytes,
    Duration timeout = const Duration(seconds: 15),
    int? maxResponseBytes,
    bool followRedirects = true,
    int maxRedirects = 5,
    bool autoUncompress = true,
    AppHttpClientPoolKind pool = AppHttpClientPoolKind.api,
    AppHttpCancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const AppHttpCancelledException();
    }
    final bool usesInjectedClient = _clientFactory != null;
    final bool usesZonedOverride =
        !usesInjectedClient && HttpOverrides.current != null;
    final bool ownsClient = usesInjectedClient || usesZonedOverride;
    final HttpClient client = usesInjectedClient
        ? _clientFactory()
        : usesZonedOverride
        ? HttpClient()
        : _obtainPoolClient(pool);
    if (ownsClient) {
      try {
        client.connectionTimeout = defaultConnectionTimeout;
      } on NoSuchMethodError {
        // 测试替身 HttpClient 可能仅实现部分 setter。
      }
      if (!autoUncompress) {
        try {
          client.autoUncompress = false;
        } on NoSuchMethodError {
          // 下面仍会发送 Accept-Encoding: identity 保证语义一致。
        }
      }
    }

    final Completer<AppHttpResponse> completer = Completer<AppHttpResponse>();
    HttpClientRequest? activeRequest;
    StreamSubscription<List<int>>? activeSubscription;
    bool terminated = false;

    void failOnce(Object error, [StackTrace? stackTrace]) {
      if (terminated) {
        return;
      }
      terminated = true;
      try {
        activeRequest?.abort(error, stackTrace);
      } catch (_) {
        // 忽略已关闭/已中止请求的重复中止异常。
      }
      final StreamSubscription<List<int>>? sub = activeSubscription;
      activeSubscription = null;
      if (sub != null) {
        unawaited(sub.cancel().catchError((Object _) {}));
      }
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace ?? StackTrace.current);
      }
    }

    final Timer deadline = Timer(timeout, () {
      failOnce(TimeoutException('HTTP request timed out', timeout));
    });
    final void Function() removeCancelListener =
        cancelToken?.addListener(() {
          failOnce(const AppHttpCancelledException());
        }) ??
        () {};

    unawaited(() async {
      try {
        final String normalizedMethod = method.toUpperCase();
        final HttpClientRequest request;
        if (normalizedMethod == 'GET') {
          HttpClientRequest opened;
          try {
            opened = await client.getUrl(uri);
          } on NoSuchMethodError {
            opened = await client.openUrl(normalizedMethod, uri);
          }
          request = opened;
        } else {
          request = await client.openUrl(normalizedMethod, uri);
        }
        if (terminated) {
          try {
            request.abort();
          } catch (_) {}
          return;
        }
        activeRequest = request;
        try {
          request.followRedirects = followRedirects;
        } on NoSuchMethodError {
          // 测试替身 HttpClientRequest 可能仅实现部分重定向字段。
        }
        try {
          request.maxRedirects = maxRedirects;
        } on NoSuchMethodError {
          // 测试替身 HttpClientRequest 可能未实现 maxRedirects。
        }
        try {
          request.persistentConnection = true;
        } on NoSuchMethodError {
          // 测试替身 HttpClientRequest 可能未实现 persistentConnection。
        }

        bool hasExplicitAcceptEncoding = false;
        headers.forEach((String name, String value) {
          if (name.toLowerCase() == HttpHeaders.acceptEncodingHeader) {
            hasExplicitAcceptEncoding = true;
          }
          request.headers.set(name, value);
        });
        // 共享池开启 autoUncompress；若调用方明确要求禁用解压，则发送 identity。
        if (!autoUncompress && !hasExplicitAcceptEncoding) {
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        }

        if (bodyBytes != null && bodyBytes.isNotEmpty) {
          request.contentLength = bodyBytes.length;
          request.add(bodyBytes);
        }

        void discardResponse(HttpClientResponse discarded) {
          // 取消正文订阅并中止当前请求以释放单个底层连接，绝不 drain 大响应体，也不关闭共享池。
          try {
            final StreamSubscription<List<int>> sub = discarded.listen(
              (_) {},
              onError: (Object _) {},
              cancelOnError: true,
            );
            unawaited(sub.cancel().catchError((Object _) {}));
          } catch (_) {
            // 忽略极简测试替身响应的取消异常。
          }
        }

        final HttpClientResponse response = await request.close();
        if (terminated) {
          discardResponse(response);
          return;
        }

        final Map<String, List<String>> responseHeaders =
            <String, List<String>>{};
        try {
          response.headers.forEach((String name, List<String> values) {
            responseHeaders[name.toLowerCase()] = List<String>.unmodifiable(
              values,
            );
          });
        } on NoSuchMethodError {
          for (final String name in const <String>[
            HttpHeaders.setCookieHeader,
            HttpHeaders.contentEncodingHeader,
            HttpHeaders.locationHeader,
            HttpHeaders.etagHeader,
            HttpHeaders.lastModifiedHeader,
            HttpHeaders.contentTypeHeader,
            HttpHeaders.cacheControlHeader,
            HttpHeaders.contentLengthHeader,
          ]) {
            try {
              final List<String>? values = response.headers[name];
              if (values != null && values.isNotEmpty) {
                responseHeaders[name] = List<String>.unmodifiable(values);
              }
            } on NoSuchMethodError {
              // 忽略不支持下标读取的极简测试头实现。
            }
          }
        }

        final String? contentEncoding =
            responseHeaders[HttpHeaders.contentEncodingHeader]?.first
                .toLowerCase()
                .trim();
        final bool isCompressed =
            contentEncoding != null &&
            contentEncoding.isNotEmpty &&
            contentEncoding != 'identity';

        int responseContentLength = -1;
        try {
          responseContentLength = response.contentLength;
        } on NoSuchMethodError {
          responseContentLength = -1;
        }

        if (maxResponseBytes != null &&
            !isCompressed &&
            responseContentLength > maxResponseBytes) {
          discardResponse(response);
          failOnce(AppHttpResponseTooLargeException(maxResponseBytes));
          return;
        }

        final BytesBuilder builder = BytesBuilder(copy: false);
        final Completer<Uint8List> bodyCompleter = Completer<Uint8List>();
        activeSubscription = response.listen(
          (List<int> chunk) {
            if (terminated) {
              return;
            }
            if (maxResponseBytes != null &&
                builder.length + chunk.length > maxResponseBytes) {
              final StreamSubscription<List<int>>? sub = activeSubscription;
              activeSubscription = null;
              if (sub != null) {
                unawaited(sub.cancel().catchError((Object _) {}));
              }
              final error = AppHttpResponseTooLargeException(maxResponseBytes);
              if (!bodyCompleter.isCompleted) {
                bodyCompleter.completeError(error);
              }
              return;
            }
            builder.add(chunk);
          },
          onDone: () {
            activeSubscription = null;
            if (!bodyCompleter.isCompleted) {
              bodyCompleter.complete(builder.takeBytes());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            activeSubscription = null;
            if (!bodyCompleter.isCompleted) {
              bodyCompleter.completeError(error, stackTrace);
            }
          },
          cancelOnError: true,
        );

        final Uint8List bytes = await bodyCompleter.future;
        if (terminated) {
          return;
        }
        terminated = true;
        final List<String>? locationValues =
            responseHeaders[HttpHeaders.locationHeader];
        final String? redirectLocation =
            locationValues != null && locationValues.isNotEmpty
            ? locationValues.first
            : null;
        if (!completer.isCompleted) {
          completer.complete(
            AppHttpResponse(
              statusCode: response.statusCode,
              bytes: bytes,
              headers: Map<String, List<String>>.unmodifiable(responseHeaders),
              redirectLocation: redirectLocation,
            ),
          );
        }
      } catch (error, stackTrace) {
        failOnce(error, stackTrace);
      }
    }());

    try {
      return await completer.future;
    } finally {
      deadline.cancel();
      removeCancelListener();
      if (ownsClient) {
        try {
          client.close(force: true);
        } on NoSuchMethodError {
          // 忽略未实现 close 的极简测试替身。
        }
      }
    }
  }

  /// 仅用于测试清理或应用退出时回收共享池连接。
  void closePools({bool force = false}) {
    for (final HttpClient client in _pools.values) {
      client.close(force: force);
    }
    _pools.clear();
  }
}
