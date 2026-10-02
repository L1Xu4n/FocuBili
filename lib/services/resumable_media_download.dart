import 'dart:convert';
import 'dart:io';

import 'download_control.dart';
import 'media_url_policy.dart';

/// Streams a validated CDN response and resumes only with a server validator.
class ResumableMediaDownload {
  /// Allows a loopback-only transport in tests; production uses the CDN policy.
  const ResumableMediaDownload({this.acceptUri = _trustedUri});

  final bool Function(Uri) acceptUri;

  /// Applies the shared HTTPS and trusted-host policy to every redirect hop.
  static bool _trustedUri(Uri uri) => MediaUrlPolicy.isSafe(uri.toString());

  /// Returns the sidecar path; it contains only validators, never URLs or cookies.
  static File validatorFile(File file) => File('${file.path}.resume');

  /// Follows bounded redirects without ever forwarding Cookie credentials.
  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    for (var hop = 0; hop < 5; hop++) {
      if (!acceptUri(uri)) throw const FormatException('Untrusted media URL');
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach((key, value) {
        if (key.toLowerCase() != 'cookie') request.headers.set(key, value);
      });
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().timeout(const Duration(seconds: 10));
      if (location == null) break;
      uri = uri.resolve(location);
    }
    throw const HttpException('Media redirect failed');
  }

  /// Resumes only the same media identity and validator, then checks exact ranges.
  Future<int> download(
    Uri uri,
    Map<String, String> headers,
    File output,
    void Function(int, int?) onProgress, {
    DownloadControl? control,
    String? mediaIdentity,
  }) async {
    control?.check();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    control?.abort = () => client.close(force: true);
    final sidecar = validatorFile(output);
    try {
      var offset = await output.exists() ? await output.length() : 0;
      String? validator;
      if (offset > 0 && await sidecar.exists()) {
        try {
          final data = jsonDecode(await sidecar.readAsString()) as Map;
          if (mediaIdentity == null || data['mediaIdentity'] == mediaIdentity) {
            validator = data['validator'] as String?;
          }
        } catch (_) {
          // An invalid sidecar must never authorize appending to unknown bytes.
        }
      }
      if (validator == null || validator.isEmpty) offset = 0;
      var response = await _open(client, uri, {
        ...headers,
        'Accept-Encoding': 'identity',
        if (offset > 0) 'Range': 'bytes=$offset-',
        if (offset > 0) 'If-Range': validator!,
      });
      control?.check();
      if (offset > 0 && response.statusCode == 416) {
        await response.drain<void>().timeout(const Duration(seconds: 10));
        offset = 0;
        response = await _open(client, uri, {
          ...headers,
          'Accept-Encoding': 'identity',
        });
      }
      int? total;
      if (offset > 0 && response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) + 1 != int.parse(range[3]!)) {
          throw const FormatException('Invalid resume range');
        }
        total = int.parse(range[3]!);
      } else if (response.statusCode == 200) {
        offset =
            0; // If-Range mismatch or unsupported range: overwrite, never append.
        total = response.contentLength > 0 ? response.contentLength : null;
      } else {
        throw const HttpException('Download response failed');
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.startsWith('text/') || type.contains('json')) {
        throw const FormatException('Response is not media');
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final nextValidator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      final sink = await output.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      try {
        if (nextValidator != null) {
          await sidecar.writeAsString(
            jsonEncode({
              'validator': nextValidator,
              'mediaIdentity': ?mediaIdentity,
            }),
            flush: true,
          );
        } else if (await sidecar.exists()) {
          await sidecar.delete();
        }
        onProgress(received, total);
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          control?.check();
          await sink.writeFrom(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      control?.check();
      if (received == 0 || (total != null && received != total)) {
        throw const HttpException('Incomplete media');
      }
      return received;
    } catch (_) {
      control?.check();
      rethrow;
    } finally {
      control?.abort = null;
      client.close(force: true);
    }
  }
}
