import 'dart:convert';
import 'dart:io';

/// Anonymous, bounded reads of this repository's release API and JSON assets.
class AppUpdateTransport {
  AppUpdateTransport({HttpClient? client}) : _client = client;
  final HttpClient? _client;

  Future<Object?> readJson(Uri uri, {bool releaseAsset = false}) async {
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
    final client = _client ?? HttpClient();
    final ownsClient = _client == null;
    final limit = releaseAsset ? 64 * 1024 : 1024 * 1024;
    try {
      client.connectionTimeout = const Duration(seconds: 8);
      var current = uri;
      for (var redirects = 0; redirects <= 3; redirects++) {
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 10));
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
          ..set(HttpHeaders.userAgentHeader, 'FocuBili-update-checker')
          ..set('X-GitHub-Api-Version', '2022-11-28');
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          final next = location == null ? null : current.resolve(location);
          await _read(response, limit);
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
        if (response.statusCode != HttpStatus.ok) {
          await response.listen((_) {}, onError: (Object _) {}).cancel();
          throw const HttpException('Update request failed');
        }
        return jsonDecode(await _read(response, limit));
      }
      throw const HttpException('Update redirect limit reached');
    } finally {
      if (ownsClient) client.close(force: true);
    }
  }

  static bool _safeUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      uri.fragment.isEmpty;

  static Future<String> _read(HttpClientResponse response, int limit) async {
    if (response.contentLength > limit) {
      await response.listen((_) {}, onError: (Object _) {}).cancel();
      throw const FormatException('Update response too large');
    }
    final bytes = <int>[];
    await response
        .forEach((chunk) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('Update response too large');
          }
          bytes.addAll(chunk);
        })
        .timeout(const Duration(seconds: 10));
    return utf8.decode(bytes);
  }
}
