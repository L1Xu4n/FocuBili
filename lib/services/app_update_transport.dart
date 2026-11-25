import 'dart:convert';
import 'dart:io';

import 'app_http_client.dart';

/// A bounded update response with optional revalidation headers.
class AppUpdateResponse {
  /// Keeps status and validators together with the response body.
  const AppUpdateResponse(
    this.statusCode,
    this.body,
    this.etag,
    this.lastModified,
  );

  final int statusCode;
  final String body;
  final String? etag, lastModified;
}

/// Anonymous, bounded reads of this repository's release API and JSON assets.
class AppUpdateTransport {
  /// Uses the shared pool unless a test supplies a client or client factory.
  AppUpdateTransport({HttpClient? client, HttpClient Function()? clientFactory})
    : _transport = client != null
          ? AppHttpTransport(clientFactory: () => _BorrowedUpdateClient(client))
          : clientFactory != null
          ? AppHttpTransport(clientFactory: clientFactory)
          : AppHttpTransport.shared;

  static const maxReleaseBytes = 1024 * 1024;
  final AppHttpTransport _transport;

  /// Reads a JSON asset while retaining the existing strict redirect policy.
  Future<Object?> readJson(Uri uri, {bool releaseAsset = false}) async {
    final response = await fetch(uri, releaseAsset: releaseAsset);
    if (response.statusCode != HttpStatus.ok) {
      throw const HttpException('Unexpected update response without a body');
    }
    return jsonDecode(response.body);
  }

  /// Sends one conditional or unconditional GET, following only asset redirects.
  Future<AppUpdateResponse> fetch(
    Uri uri, {
    bool releaseAsset = false,
    String? etag,
    String? lastModified,
  }) async {
    if (!_safeUrl(uri) ||
        (releaseAsset
            ? uri.host.toLowerCase() != 'github.com' ||
                  !uri.path.startsWith('/L1Xu4n/FocuBili/releases/download/') ||
                  uri.hasQuery
            : uri.host != 'api.github.com' ||
                  !{
                    '/repos/L1Xu4n/FocuBili/releases',
                    '/repos/L1Xu4n/FocuBili/releases/latest',
                  }.contains(uri.path))) {
      throw const FormatException('Invalid update source');
    }
    var current = uri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      final response = await _transport.send(
        uri: current,
        timeout: const Duration(seconds: 10),
        maxResponseBytes: releaseAsset ? 64 * 1024 : maxReleaseBytes,
        followRedirects: false,
        headers: {
          HttpHeaders.acceptHeader: 'application/vnd.github+json',
          HttpHeaders.userAgentHeader: 'FocuBili-update-checker',
          'X-GitHub-Api-Version': '2022-11-28',
          HttpHeaders.ifNoneMatchHeader: ?etag,
          HttpHeaders.ifModifiedSinceHeader: ?lastModified,
        },
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.redirectLocation;
        final next = location == null ? null : current.resolve(location);
        if (!releaseAsset ||
            redirects == 3 ||
            next == null ||
            !_safeUrl(next) ||
            !{
              'release-assets.githubusercontent.com',
              'objects.githubusercontent.com',
            }.contains(next.host.toLowerCase())) {
          throw const HttpException('Update redirect rejected');
        }
        current = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.notModified) {
        throw const HttpException('Update request failed');
      }
      return AppUpdateResponse(
        response.statusCode,
        response.statusCode == HttpStatus.ok ? response.bodyUtf8 : '',
        response.header(HttpHeaders.etagHeader),
        response.header(HttpHeaders.lastModifiedHeader),
      );
    }
    throw const HttpException('Update redirect limit reached');
  }

  /// Limits update requests to HTTPS without credentials or custom ports.
  static bool _safeUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      uri.fragment.isEmpty;
}

/// Adapts an explicitly borrowed GET client without closing it after a request.
class _BorrowedUpdateClient implements HttpClient {
  /// Wraps the caller-owned client.
  _BorrowedUpdateClient(this._client);

  final HttpClient _client;

  /// Applies the shared transport's decompression preference.
  @override
  set autoUncompress(bool value) => _client.autoUncompress = value;

  /// Opens the GET request using the existing injected-read contract.
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _client.getUrl(url);

  /// Opens the GET request using the existing injected-read contract.
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _client.getUrl(url);

  /// Leaves ownership with the caller that supplied the client.
  @override
  void close({bool force = false}) {}

  /// Reports unsupported operations outside update GET requests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
