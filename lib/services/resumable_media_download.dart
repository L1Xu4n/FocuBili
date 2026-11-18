import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'download_control.dart';
import 'media_url_policy.dart';

/// A strong representation validator scoped to the effective CDN resource.
final class _MediaVersion {
  const _MediaVersion(this.token, this.etag, this.bytes);
  final String token, etag;
  final int bytes;

  static _MediaVersion? read(
    Uri uri,
    HttpClientResponse response,
    int? length,
  ) {
    final tag = response.headers[HttpHeaders.etagHeader];
    final encoding = response.headers[HttpHeaders.contentEncodingHeader];
    if (length == null ||
        length <= 0 ||
        (encoding != null &&
            (encoding.length != 1 || encoding.single != 'identity')) ||
        (response.headers['vary'] ?? []).any((value) => value.contains('*')) ||
        tag == null ||
        tag.length != 1 ||
        !RegExp(r'^"[\x21\x23-\x7e]{1,256}"$').hasMatch(tag.single)) {
      return null;
    }
    // Keep *all* non-transport query fields, including duplicates and order.
    // Removing only known auth fields permits a renewed signature on the
    // identical query-shaped representation, not equivalence across CDNs.
    const signingFields = {
      'deadline',
      'expires',
      'expire',
      'expiresat',
      'expireat',
      'wstime',
      'authkey',
      'sign',
      'signature',
      'upsig',
      'wssecret',
    };
    final resource = [
      uri.scheme,
      uri.host,
      uri.port,
      uri.path,
      for (final part in uri.query.split('&'))
        if (part.isNotEmpty &&
            !signingFields.contains(
              Uri.decodeQueryComponent(
                part.split('=').first,
              ).toLowerCase().replaceAll(RegExp('[^a-z0-9]'), ''),
            ))
          part,
    ];
    final token = sha256
        .convert(utf8.encode(jsonEncode([resource, tag.single, length])))
        .toString();
    return _MediaVersion(token, tag.single, length);
  }
}

/// Separate the digest of actual local bytes from the server validator. A
/// resumed range cannot confer version proof on a locally corrupted prefix.
final class _LocalMediaDigest implements Sink<Digest> {
  _LocalMediaDigest() {
    input = sha256.startChunkedConversion(this);
  }

  late final ByteConversionSink input;
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

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
  Future<({Uri uri, HttpClientResponse response})> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers, {
    String method = 'GET',
    void Function(Uri)? beforeRequest,
  }) async {
    for (var hop = 0; hop < 5; hop++) {
      if (!acceptUri(uri)) throw const FormatException('Untrusted media URL');
      beforeRequest?.call(uri);
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      headers.forEach((key, value) {
        if (key.toLowerCase() != 'cookie') request.headers.set(key, value);
      });
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (!response.isRedirect) return (uri: uri, response: response);
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().timeout(const Duration(seconds: 10));
      if (location == null) break;
      uri = uri.resolve(location);
    }
    throw const HttpException('Media redirect failed');
  }

  /// Inspect headers only. No fallback GET is made if HEAD is unsupported.
  /// A missing strong validator is incompatible, not grounds for renewal.
  Future<String?> probeVersion(
    Uri uri,
    Map<String, String> headers, {
    required DownloadControl control,
    void Function(Uri)? beforeRequest,
  }) async {
    control.check();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false;
    control.abort = () => client.close(force: true);
    try {
      return (await _probe(client, uri, headers, beforeRequest))?.token;
    } finally {
      control.abort = null;
      client.close(force: true);
      control.check();
    }
  }

  Future<_MediaVersion?> _probe(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    void Function(Uri)? beforeRequest,
  ) async {
    final result = await _open(
      client,
      uri,
      {...headers, 'Accept-Encoding': 'identity'},
      method: 'HEAD',
      beforeRequest: beforeRequest,
    );
    final response = result.response;
    final status = response.statusCode;
    final version =
        status == HttpStatus.ok &&
            response.headers[HttpHeaders.contentRangeHeader] == null
        ? _MediaVersion.read(result.uri, response, response.contentLength)
        : null;
    await response.drain<void>().timeout(const Duration(seconds: 10));
    if (status != HttpStatus.ok && status != 405 && status != 501) {
      throw const HttpException('Media headers temporarily unavailable');
    }
    return version;
  }

  /// Resumes only the same media identity and validator, then checks exact ranges.
  Future<int> download(
    Uri uri,
    Map<String, String> headers,
    File output,
    void Function(int, int?) onProgress, {
    DownloadControl? control,
    String? mediaIdentity,
    void Function(Uri)? beforeRequest,
    void Function(String?)? onCompleteVersion,
  }) async {
    control?.check();
    final course = onCompleteVersion != null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = !course;
    control?.abort = () => client.close(force: true);
    final sidecar = validatorFile(output);
    try {
      var offset = await output.exists() ? await output.length() : 0;
      String? validator;
      _MediaVersion? resumeVersion;
      _LocalMediaDigest? runningDigest;
      if (offset > 0 && await sidecar.exists()) {
        try {
          final data = jsonDecode(await sidecar.readAsString()) as Map;
          if (mediaIdentity == null || data['mediaIdentity'] == mediaIdentity) {
            if (course) {
              final token = data['version'];
              final savedHash = data['localHash'];
              if (token is String &&
                  savedHash is String &&
                  data['bytes'] == offset &&
                  RegExp(r'^[0-9a-f]{64}$').hasMatch(token) &&
                  RegExp(r'^[0-9a-f]{64}$').hasMatch(savedHash)) {
                final verifier = _LocalMediaDigest();
                final extension = _LocalMediaDigest();
                await for (final chunk in output.openRead()) {
                  control?.check();
                  verifier.input.add(chunk);
                  extension.input.add(chunk);
                }
                verifier.input.close();
                if (verifier.value.toString() == savedHash) {
                  final current = await _probe(
                    client,
                    uri,
                    headers,
                    beforeRequest,
                  );
                  if (current != null && current.token == token) {
                    if (current.bytes == offset) {
                      control?.check();
                      onCompleteVersion(current.token);
                      onProgress(offset, offset);
                      return offset;
                    }
                    if (current.bytes > offset) {
                      resumeVersion = current;
                      validator = current.etag;
                      runningDigest = extension;
                    }
                  }
                }
              }
            } else {
              validator = data['validator'] as String?;
            }
          }
        } catch (_) {
          // An invalid sidecar must never authorize appending to unknown bytes.
          control?.check();
        }
      }
      if (validator == null || validator.isEmpty) offset = 0;
      var opened = await _open(client, uri, {
        ...headers,
        'Accept-Encoding': 'identity',
        if (offset > 0) 'Range': 'bytes=$offset-',
        if (offset > 0) 'If-Range': validator!,
      }, beforeRequest: beforeRequest);
      var response = opened.response;
      control?.check();
      if (offset > 0 && response.statusCode == 416) {
        await response.drain<void>().timeout(const Duration(seconds: 10));
        offset = 0;
        opened = await _open(client, uri, {
          ...headers,
          'Accept-Encoding': 'identity',
        }, beforeRequest: beforeRequest);
        response = opened.response;
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
      if (course &&
          (response.headers[HttpHeaders.contentEncodingHeader] ?? []).any(
            (value) => value != 'identity',
          )) {
        throw const FormatException(
          'Expected an identity-encoded media object',
        );
      }
      final version = course
          ? _MediaVersion.read(opened.uri, response, total)
          : null;
      if (course && offset > 0 && version?.token != resumeVersion?.token) {
        // A range must prove it is the same object, not just have the same size.
        if (await sidecar.exists()) await sidecar.delete();
        throw const FormatException('Media version changed during resume');
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final nextValidator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      if (course && offset == 0) runningDigest = _LocalMediaDigest();
      final sink = await output.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      try {
        if (!course && nextValidator != null) {
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
          runningDigest?.input.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
        runningDigest?.input.close();
        if (course &&
            version != null &&
            received > 0 &&
            runningDigest?.value != null) {
          await sidecar.writeAsString(
            jsonEncode({
              'version': version.token,
              'mediaIdentity': ?mediaIdentity,
              'bytes': received,
              'localHash': runningDigest!.value.toString(),
            }),
            flush: true,
          );
        }
      }
      control?.check();
      if (received == 0 || (total != null && received != total)) {
        throw const HttpException('Incomplete media');
      }
      onCompleteVersion?.call(version?.token);
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
