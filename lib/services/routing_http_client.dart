import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/network_proxy_settings.dart';

typedef ProxyResolver = Future<NetworkProxyRoute> Function(Uri uri);

/// Dart's findProxy callback is synchronous, while OS/PAC lookup is asynchronous.
/// Resolve before opening each request, then pool by route. Redirects are handled
/// here as well so a redirect cannot accidentally inherit another host's route.
class RoutingHttpOverrides extends HttpOverrides {
  RoutingHttpOverrides({required this.resolve, this.previous});
  final ProxyResolver resolve;
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) => RoutingHttpClient(
    resolve: resolve,
    createClient: () =>
        previous?.createHttpClient(context) ?? super.createHttpClient(context),
  );
}

class RoutingHttpClient implements HttpClient {
  RoutingHttpClient({required this.resolve, required this.createClient})
    : _template = createClient();

  final ProxyResolver resolve;
  final HttpClient Function() createClient;
  final HttpClient _template;
  final Map<String, HttpClient> _clients = {};
  final List<void Function(HttpClient)> _configuration = [];
  bool _closed = false;
  String Function(Uri)? _customProxy;

  void _configure(void Function(HttpClient) action) {
    action(_template);
    for (final client in _clients.values) {
      action(client);
    }
    _configuration.add(action);
  }

  Future<HttpClientRequest> _openRaw(String method, Uri uri) async {
    if (_closed) throw StateError('HTTP client is closed');
    final directive = _customProxy?.call(uri) ?? (await resolve(uri)).directive;
    if (_closed) throw StateError('HTTP client is closed');
    final client = _clients.putIfAbsent(directive, () {
      final client = createClient();
      for (final configure in _configuration) {
        configure(client);
      }
      client.findProxy = (_) => directive;
      return client;
    });
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    return request;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _RoutingRequest(await _openRaw(method, url), this);

  Future<HttpClientRequest> _redirectRequest(
    String method,
    Uri from,
    Uri to,
    HttpHeaders previousHeaders,
  ) async {
    if (to.scheme != 'http' && to.scheme != 'https') {
      throw const HttpException('Unsupported redirect scheme');
    }
    final request = await _openRaw(method, to);
    final sameOrigin =
        from.scheme == to.scheme &&
        from.host == to.host &&
        from.port == to.port;
    previousHeaders.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower == HttpHeaders.hostHeader ||
          lower == HttpHeaders.contentLengthHeader ||
          lower == HttpHeaders.transferEncodingHeader ||
          lower == HttpHeaders.proxyAuthorizationHeader) {
        return;
      }
      const sensitive = {
        'authorization',
        'www-authenticate',
        'proxy-authorization',
        'proxy-authenticate',
        'cookie',
        'cookie2',
      };
      if (!sameOrigin && sensitive.contains(lower)) return;
      request.headers.set(name, values);
    });
    return request;
  }

  Future<HttpClientResponse> _follow(
    HttpClientResponse response,
    String method,
    Uri uri,
    HttpHeaders headers,
    bool follow,
    int maxRedirects, [
    List<RedirectInfo> history = const [],
    Set<Uri>? visited,
  ]) async {
    var current = response;
    var currentMethod = method;
    var currentUri = uri;
    var currentHeaders = headers;
    final redirects = [...history];
    final seen = {...?visited, uri};
    while (follow && current.isRedirect) {
      final location = current.headers.value(HttpHeaders.locationHeader);
      if (location == null) break;
      final next = currentUri.resolve(location);
      if (redirects.length >= maxRedirects || seen.contains(next)) {
        await current.drain<void>();
        throw RedirectException('Redirect limit or loop', redirects);
      }
      final nextMethod = current.statusCode == 303 && currentMethod == 'POST'
          ? 'GET'
          : currentMethod;
      await current.drain<void>();
      final request = await _redirectRequest(
        nextMethod,
        currentUri,
        next,
        currentHeaders,
      );
      redirects.add(_ProxyRedirectInfo(current.statusCode, nextMethod, next));
      seen.add(next);
      currentMethod = nextMethod;
      currentUri = next;
      currentHeaders = request.headers;
      current = await request.close();
    }
    return _RoutingResponse(current, redirects, (
      method,
      url,
      followLoops,
    ) async {
      // Manual redirect is called after the consumer has read/drained the body.
      // It always performs one request, ignoring maxRedirects, without rereading it.
      final location =
          url?.toString() ?? current.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        throw RedirectException('Redirect has no Location header', redirects);
      }
      final next = currentUri.resolve(location);
      if (!followLoops && seen.contains(next)) {
        throw RedirectException('Redirect loop', redirects);
      }
      final nextMethod =
          method ??
          (current.statusCode == 303 && currentMethod == 'POST'
              ? 'GET'
              : currentMethod);
      final request = await _redirectRequest(
        nextMethod,
        currentUri,
        next,
        currentHeaders,
      );
      final nextResponse = await request.close();
      return _follow(
        nextResponse,
        nextMethod,
        next,
        request.headers,
        false,
        maxRedirects,
        [
          ...redirects,
          _ProxyRedirectInfo(current.statusCode, nextMethod, next),
        ],
        {...seen, next},
      );
    });
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(
    method,
    Uri.parse('http://${Uri(host: host, port: port).authority}$path'),
  );
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Duration get idleTimeout => _template.idleTimeout;
  @override
  set idleTimeout(Duration value) =>
      _configure((client) => client.idleTimeout = value);
  @override
  Duration? get connectionTimeout => _template.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) =>
      _configure((client) => client.connectionTimeout = value);
  @override
  int? get maxConnectionsPerHost => _template.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _configure((client) => client.maxConnectionsPerHost = value);
  @override
  bool get autoUncompress => _template.autoUncompress;
  @override
  set autoUncompress(bool value) =>
      _configure((client) => client.autoUncompress = value);
  @override
  String? get userAgent => _template.userAgent;
  @override
  set userAgent(String? value) =>
      _configure((client) => client.userAgent = value);
  @override
  set findProxy(String Function(Uri)? value) => _customProxy = value;
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? value) =>
      _configure((client) => client.authenticate = value);
  @override
  set authenticateProxy(
    Future<bool> Function(String, int, String, String?)? value,
  ) => _configure((client) => client.authenticateProxy = value);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) => _configure((client) => client.badCertificateCallback = value);
  @override
  set keyLog(Function(String)? value) =>
      _configure((client) => client.keyLog = value);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) => _configure((client) => client.connectionFactory = value);
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _configure((client) => client.addCredentials(url, realm, credentials));
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _configure(
    (client) => client.addProxyCredentials(host, port, realm, credentials),
  );
  @override
  void close({bool force = false}) {
    _closed = true;
    _template.close(force: force);
    for (final client in _clients.values) {
      client.close(force: force);
    }
  }
}

class _RoutingRequest implements HttpClientRequest {
  _RoutingRequest(this.delegate, this.client);
  final HttpClientRequest delegate;
  final RoutingHttpClient client;
  Future<HttpClientResponse>? _result;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  Future<HttpClientResponse> get done => _result ??= delegate.done.then(
    (response) => client._follow(
      response,
      method,
      uri,
      headers,
      followRedirects,
      maxRedirects,
    ),
  );
  @override
  Future<HttpClientResponse> close() {
    delegate.close();
    return done;
  }

  @override
  String get method => delegate.method;
  @override
  Uri get uri => delegate.uri;
  @override
  HttpHeaders get headers => delegate.headers;
  @override
  List<Cookie> get cookies => delegate.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => delegate.connectionInfo;
  @override
  bool get persistentConnection => delegate.persistentConnection;
  @override
  set persistentConnection(bool value) => delegate.persistentConnection = value;
  @override
  int get contentLength => delegate.contentLength;
  @override
  set contentLength(int value) => delegate.contentLength = value;
  @override
  bool get bufferOutput => delegate.bufferOutput;
  @override
  set bufferOutput(bool value) => delegate.bufferOutput = value;
  @override
  Encoding get encoding => delegate.encoding;
  @override
  set encoding(Encoding value) => delegate.encoding = value;
  @override
  void write(Object? value) => delegate.write(value);
  @override
  void writeAll(Iterable values, [String separator = '']) =>
      delegate.writeAll(values, separator);
  @override
  void writeln([Object? value = '']) => delegate.writeln(value);
  @override
  void writeCharCode(int value) => delegate.writeCharCode(value);
  @override
  void add(List<int> data) => delegate.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      delegate.addStream(stream);
  @override
  Future<void> flush() => delegate.flush();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      delegate.abort(exception, stackTrace);
}

class _RoutingResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _RoutingResponse(this.delegate, List<RedirectInfo> history, this._redirect)
    : redirects = List.unmodifiable(history),
      super(delegate);
  final HttpClientResponse delegate;
  final Future<HttpClientResponse> Function(String?, Uri?, bool) _redirect;
  @override
  final List<RedirectInfo> redirects;
  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => _redirect(method, url, followLoops ?? false);
  @override
  int get statusCode => delegate.statusCode;
  @override
  String get reasonPhrase => delegate.reasonPhrase;
  @override
  int get contentLength => delegate.contentLength;
  @override
  HttpClientResponseCompressionState get compressionState =>
      delegate.compressionState;
  @override
  bool get persistentConnection => delegate.persistentConnection;
  @override
  bool get isRedirect => delegate.isRedirect;
  @override
  HttpHeaders get headers => delegate.headers;
  @override
  List<Cookie> get cookies => delegate.cookies;
  @override
  X509Certificate? get certificate => delegate.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => delegate.connectionInfo;
  @override
  Future<Socket> detachSocket() => delegate.detachSocket();
}

class _ProxyRedirectInfo implements RedirectInfo {
  const _ProxyRedirectInfo(this.statusCode, this.method, this.location);
  @override
  final int statusCode;
  @override
  final String method;
  @override
  final Uri location;
}
