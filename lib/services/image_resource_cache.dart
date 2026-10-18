import 'cache_file_lock.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'cache_lifecycle.dart';

/// Bounded encoded image cache. URL transformations and every request header
/// remain part of identity; neither URLs nor headers are written into the index.
/// Files are read/written under a process + OS lock, never while downloading.
class ImageResourceCache extends ChangeNotifier {
  ImageResourceCache({
    Future<Directory> Function()? directory,
    ImageCacheRequest? request,
    DateTime Function()? clock,
    this.defaultCapacity = 256 * 1024 * 1024,
    this.accountScoped = false,
  }) : _directory = directory ?? _defaultDirectory,
       _request = request ?? _download,
       _clock = clock ?? DateTime.now {
    if (accountScoped) CacheLifecycle.account.addListener(_accountChanged);
  }

  /// Remove only entries owned by the previous image cache. Never scan or
  /// delete the surrounding application cache/download directories.
  static Future<void> cleanLegacyCache() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      const key = 'legacy_image_cache_cleaned_v1';
      if (preferences.getBool(key) == true) return;
      await DefaultCacheManager().emptyCache();
      await preferences.setBool(key, true);
    } catch (_) {
      // Retry next startup when the legacy cache database is available.
    }
  }

  static final instance = ImageResourceCache(accountScoped: true);
  static const capacities = [64, 128, 256, 512]; // MiB
  static const maximumObjectBytes = 16 * 1024 * 1024;
  static final Map<String, Future<void>> _locks = {};
  static int _leaseSerial = 0;
  final Future<Directory> Function() _directory;
  final ImageCacheRequest _request;
  final DateTime Function() _clock;
  final int defaultCapacity;
  final bool accountScoped;
  final List<Completer<void>> _waiting = [];
  int _activeDownloads = 0;
  final Map<String, Future<CachedImageBytes>> _pending = {};
  final Map<String, DateTime> _retryAfter = {};
  int _revision = 0;
  int get revision => _revision;
  bool _accountInvalidation = false;
  bool get accountInvalidation => _accountInvalidation;
  void _accountChanged() {
    _accountInvalidation = true;
    _revision++;
    _retryAfter.clear();
    notifyListeners();
  }

  String _key(String url, Map<String, String> headers) => resourceKey(
    '${accountScoped ? CacheLifecycle.accountScope : 'test'}\n$url',
    headers,
  );

  /// No lossy canonicalization of query strings, CDN transforms or headers.
  static String resourceKey(String url, Map<String, String> headers) {
    final keys = headers.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              url,
              for (final key in keys) [key, headers[key]],
            ]),
          ),
        )
        .toString();
  }

  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) {
    final key = _key(url, headers);
    final pendingKey = '$_revision:$key';
    return _pending.putIfAbsent(pendingKey, () {
      final operation = _load(url, Map.of(headers), key, _revision);
      operation.then<void>(
        (_) {
          _pending.remove(pendingKey);
        },
        onError: (Object _, StackTrace _) {
          _pending.remove(pendingKey);
        },
      );
      return operation;
    });
  }

  Future<CachedImageBytes> _load(
    String url,
    Map<String, String> headers,
    String key,
    int revision,
  ) async {
    Map<String, dynamic>? record;
    CachedImageBytes? previous;
    String? epoch;
    String? lease;
    bool waitForWriter = false;
    try {
      await _locked((dir, index) async {
        epoch = index['epoch'] as String;
        final entries = index['entries'] as Map<String, dynamic>;
        final value = entries[key];
        if (value is Map) {
          record = Map<String, dynamic>.from(value);
          try {
            final file = File('${dir.path}/$key.bin');
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file) {
              throw const FileSystemException('Invalid cache file');
            }
            final bytes = await file.readAsBytes();
            final digest = sha256.convert(bytes).toString();
            if (bytes.length != record!['size'] ||
                digest != record!['digest']) {
              throw const FileSystemException('Damaged cache file');
            }
            previous = CachedImageBytes(bytes, '$epoch:$key:$digest');
            record!['used'] = _clock().microsecondsSinceEpoch;
            entries[key] = record;
          } catch (_) {
            entries.remove(key);
            record = null;
          }
        }
        if (!(_retryAfter[key]?.isAfter(_clock()) ?? false) &&
            (previous == null ||
                (record!['expires'] as int) <=
                    _clock().millisecondsSinceEpoch)) {
          final leases =
              index.putIfAbsent('leases', () => <String, dynamic>{}) as Map;
          final existing = leases[key];
          if (existing != null || leases.length >= 6) {
            waitForWriter = true;
          } else {
            lease =
                '$pid:${DateTime.now().microsecondsSinceEpoch}:${_leaseSerial++}';
            leases[key] = {
              'owner': lease,
              'until': DateTime.now()
                  .add(const Duration(seconds: 30))
                  .millisecondsSinceEpoch,
            };
          }
        }
      });
    } on FileSystemException {
      // A full/unavailable cache disk must not stop images from loading online.
    }
    _checkRevision(revision);
    if (waitForWriter) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _checkRevision(revision);
      return _load(url, headers, key, revision);
    }
    if (previous != null &&
        (record!['expires'] as int) > _clock().millisecondsSinceEpoch) {
      return previous!;
    }
    if ((_retryAfter[key]?.isAfter(_clock()) ?? false)) {
      if (previous != null && record?['mustRevalidate'] != true) {
        return previous!;
      }
      throw const ImageCacheFailure();
    }
    final conditional = Map<String, String>.of(headers);
    if (record?['etag'] is String) {
      conditional['If-None-Match'] = record!['etag'] as String;
    }
    if (record?['modified'] is String) {
      conditional['If-Modified-Since'] = record!['modified'] as String;
    }
    try {
      final response = await _limitedRequest(
        Uri.parse(url),
        conditional,
        revision,
      );
      _checkRevision(revision);
      if (response.status != 200 &&
          !(response.status == 304 && previous != null)) {
        if ([401, 403, 404, 410].contains(response.status)) {
          await remove(url, headers: headers);
          previous = null;
        }
        throw const ImageCacheFailure();
      }
      final bytes = response.status == 304 ? previous!.bytes : response.bytes;
      if (bytes.isEmpty || bytes.length > maximumObjectBytes) {
        throw const ImageCacheFailure();
      }
      final digest = sha256.convert(bytes).toString();
      final control =
          response.headers['cache-control']?.toLowerCase() ??
          (response.status == 304 ? (record?['control'] as String?) : null) ??
          '';
      final noStore =
          control.contains('no-store') ||
          response.headers['vary']?.trim() == '*';
      final seconds = int.tryParse(
        RegExp(
              r'(?:^|,)\s*max-age\s*=\s*"?(\d+)',
            ).firstMatch(control)?.group(1) ??
            '',
      );
      final age = int.tryParse(response.headers['age'] ?? '') ?? 0;
      // Recheck mutable avatars at least daily, even if the CDN advertises years.
      final ttl = control.contains('no-cache')
          ? 0
          : ((seconds ?? 86400) - age).clamp(0, 86400);
      final now = _clock();
      if (epoch != null && lease != null) {
        try {
          await _locked((dir, index) async {
            _checkRevision(revision);
            if (index['epoch'] != epoch) throw const ImageCacheCancelled();
            if ((index['leases'] as Map?)?[key]?['owner'] != lease) {
              throw const ImageCacheCancelled();
            }
            final entries = index['entries'] as Map<String, dynamic>;
            final capacity = index['capacity'] as int;
            if (noStore || bytes.length > capacity) {
              entries.remove(key);
              await _delete(File('${dir.path}/$key.bin'));
              return;
            }
            final temp = File('${dir.path}/$key.part');
            if (await FileSystemEntity.type(temp.path, followLinks: false) ==
                FileSystemEntityType.link) {
              await Link(temp.path).delete();
            }
            await temp.writeAsBytes(bytes, flush: true);
            await temp.rename('${dir.path}/$key.bin');
            entries[key] = {
              'size': bytes.length,
              'digest': digest,
              'used': now.microsecondsSinceEpoch,
              'expires': now.millisecondsSinceEpoch + ttl * 1000,
              'control': control,
              'mustRevalidate':
                  control.contains('must-revalidate') ||
                  control.contains('no-cache'),
              'etag':
                  response.headers['etag'] ??
                  (response.status == 304 ? (record?['etag']) : null),
              'modified':
                  response.headers['last-modified'] ??
                  (response.status == 304 ? (record?['modified']) : null),
            };
            await _trim(dir, index);
          });
        } on FileSystemException {
          // Atomic .part writes are cleaned during maintenance; deliver bytes.
        }
      }
      _retryAfter.remove(key);
      return CachedImageBytes(
        bytes,
        '${epoch ?? revision}:$key:$digest',
        cacheable: !noStore,
      );
    } on ImageCacheCancelled {
      rethrow;
    } catch (_) {
      _checkRevision(revision);
      _retryAfter[key] = _clock().add(const Duration(seconds: 20));
      if (_retryAfter.length > 512) _retryAfter.remove(_retryAfter.keys.first);
      if (previous != null && record?['mustRevalidate'] != true) {
        return previous!;
      }
      throw const ImageCacheFailure();
    } finally {
      if (lease != null) {
        try {
          await _locked((_, index) async {
            final leases = index['leases'];
            if (leases is Map &&
                leases[key] is Map &&
                leases[key]['owner'] == lease) {
              leases.remove(key);
            }
          });
        } catch (_) {
          /* Expiring lease repairs a killed writer or full disk. */
        }
      }
    }
  }

  void _checkRevision(int expected) {
    if (expected != _revision) throw const ImageCacheCancelled();
  }

  /// Reads the configured capacity without repairing or creating cache data.
  /// Unrelated object/lease corruption is left for the normal cache lifecycle.
  Future<int> readCapacity() async {
    final dir = (await _directory()).absolute;
    if (dir.uri.pathSegments.where((s) => s.isNotEmpty).last !=
        'focubili_images_v1') {
      throw const FileSystemException('Unsafe image cache directory');
    }
    final prior = _locks[dir.path] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[dir.path] = done.future;
    await prior;
    CacheFileLock? lock;
    try {
      final type = await FileSystemEntity.type(dir.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('Unsafe image cache directory');
      }
      if (type == FileSystemEntityType.notFound) return _defaultReadCapacity();
      for (final name in ['cache.lock', 'index.json']) {
        final metadataType = await FileSystemEntity.type(
          '${dir.path}/$name',
          followLinks: false,
        );
        if (metadataType != FileSystemEntityType.file &&
            metadataType != FileSystemEntityType.notFound) {
          throw const FileSystemException('Unsafe image cache metadata');
        }
      }
      lock = await CacheFileLock.acquireExisting('${dir.path}/cache.lock');
      final file = File('${dir.path}/index.json');
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return _defaultReadCapacity();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['capacity'] is! int ||
          (decoded['capacity'] as int) < 0) {
        throw const FormatException('Invalid image cache capacity');
      }
      return decoded['capacity'] as int;
    } finally {
      try {
        await lock?.release();
      } finally {
        done.complete();
        if (identical(_locks[dir.path], done.future)) _locks.remove(dir.path);
      }
    }
  }

  int _defaultReadCapacity() {
    if (defaultCapacity < 0) {
      throw const FormatException('Invalid default image cache capacity');
    }
    return defaultCapacity;
  }

  Future<ImageCacheUsage> status() => _locked((dir, index) async {
    await _repair(dir, index);
    await _trim(dir, index);
    return _usage(index);
  });

  Future<ImageCacheUsage> setCapacity(int bytes) => _locked((dir, index) async {
    if (bytes < 0) throw ArgumentError.value(bytes);
    index['capacity'] = bytes;
    await _trim(dir, index);
    return _usage(index);
  });

  /// Fence first, then delete. Old downloads cannot repopulate after completion.
  Future<ImageCacheUsage> clear() {
    _accountInvalidation = false;
    _revision++;
    _retryAfter.clear();
    notifyListeners();
    return _locked((dir, index) async {
      index['epoch'] = '${DateTime.now().microsecondsSinceEpoch}-$_revision';
      index['entries'] = <String, dynamic>{};
      index['leases'] = <String, dynamic>{};
      await _repair(dir, index);
      return _usage(index);
    });
  }

  Future<void> remove(String url, {Map<String, String> headers = const {}}) =>
      _locked((dir, index) async {
        final key = _key(url, headers);
        (index['entries'] as Map).remove(key);
        (index['leases'] as Map).remove(key);
        await _delete(File('${dir.path}/$key.bin'));
      });

  ImageCacheUsage _usage(Map<String, dynamic> index) => ImageCacheUsage(
    (index['entries'] as Map).values.fold<int>(
      0,
      (sum, entry) => sum + (entry['size'] as int),
    ),
    index['capacity'] as int,
    (index['entries'] as Map).length,
  );

  Future<void> _trim(Directory dir, Map<String, dynamic> index) async {
    final entries = index['entries'] as Map<String, dynamic>;
    var total = _usage(index).usedBytes;
    final keys = entries.keys.toList()
      ..sort(
        (a, b) =>
            (entries[a]['used'] as int).compareTo(entries[b]['used'] as int),
      );
    for (final key in keys) {
      if (total <= (index['capacity'] as int) && entries.length <= 2000) break;
      await _delete(File('${dir.path}/$key.bin'));
      total -= entries.remove(key)['size'] as int;
    }
  }

  Future<void> _repair(Directory dir, Map<String, dynamic> index) async {
    final entries = index['entries'] as Map<String, dynamic>;
    final found = <String>{};
    await for (final entity in dir.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (RegExp(r'^[a-f0-9]{64}\.bin$').hasMatch(name)) {
        final key = name.substring(0, 64);
        if (entity is File && entries[key]?['size'] == await entity.length()) {
          found.add(key);
        } else {
          await entity.delete();
        }
      } else if (RegExp(r'^[a-f0-9]{64}\.part$').hasMatch(name)) {
        await entity.delete();
      }
    }
    entries.removeWhere((key, _) => !found.contains(key));
  }

  Future<T> _locked<T>(
    Future<T> Function(Directory, Map<String, dynamic>) action,
  ) async {
    final dir = (await _directory()).absolute;
    if (dir.uri.pathSegments.where((s) => s.isNotEmpty).last !=
            'focubili_images_v1' ||
        await FileSystemEntity.type(dir.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FileSystemException('Unsafe image cache directory');
    }
    await dir.create(recursive: true);
    final prior = _locks[dir.path] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[dir.path] = done.future;
    await prior;
    CacheFileLock? lock;
    try {
      for (final name in ['cache.lock', 'index.json', 'index.part']) {
        if (await FileSystemEntity.type(
              '${dir.path}/$name',
              followLinks: false,
            ) ==
            FileSystemEntityType.link) {
          throw const FileSystemException('Unsafe image cache metadata');
        }
      }
      lock = await CacheFileLock.acquire('${dir.path}/cache.lock');
      final file = File('${dir.path}/index.json');
      Map<String, dynamic> index;
      try {
        index = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (index['epoch'] is! String ||
            index['entries'] is! Map ||
            index['capacity'] is! int ||
            (index['capacity'] as int) < 0) {
          throw const FormatException();
        }
        (index['entries'] as Map).removeWhere(
          (key, value) =>
              key is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
              value is! Map ||
              value['size'] is! int ||
              value['size'] < 0 ||
              value['size'] > maximumObjectBytes ||
              value['used'] is! int ||
              value['expires'] is! int ||
              value['digest'] is! String,
        );
      } catch (_) {
        index = {
          'epoch': DateTime.now().microsecondsSinceEpoch.toString(),
          'entries': <String, dynamic>{},
          'capacity': defaultCapacity,
        };
        await _repair(dir, index);
      }
      if (index['leases'] is! Map) index['leases'] = <String, dynamic>{};
      (index['leases'] as Map).removeWhere(
        (key, value) =>
            key is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
            value is! Map ||
            value['owner'] is! String ||
            value['until'] is! int ||
            value['until'] <= DateTime.now().millisecondsSinceEpoch ||
            value['until'] >
                DateTime.now()
                    .add(const Duration(seconds: 31))
                    .millisecondsSinceEpoch,
      );
      final result = await action(dir, index);
      final temp = File('${dir.path}/index.part');
      await temp.writeAsString(jsonEncode(index), flush: true);
      await temp.rename(file.path);
      return result;
    } finally {
      try {
        await lock?.release();
      } finally {
        done.complete();
        if (identical(_locks[dir.path], done.future)) _locks.remove(dir.path);
      }
    }
  }

  static Future<void> _delete(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<ImageCacheResponse> _limitedRequest(
    Uri uri,
    Map<String, String> headers,
    int revision,
  ) async {
    if (_activeDownloads < 6) {
      _activeDownloads++;
    } else {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    }
    try {
      _checkRevision(revision);
      return await _request(uri, headers);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _activeDownloads--;
      }
    }
  }

  @override
  void dispose() {
    if (accountScoped) CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationCacheDirectory()).path}/focubili_images_v1',
  );

  static Future<ImageCacheResponse> _download(
    Uri uri,
    Map<String, String> headers,
  ) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const ImageCacheFailure();
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final deadline = Timer(
      const Duration(seconds: 25),
      () => client.close(force: true),
    );
    try {
      final request = await client.getUrl(uri);
      // Do not forward caller headers (possibly credentials) to redirect hosts.
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.contentLength > maximumObjectBytes) {
        throw const ImageCacheFailure();
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (builder.length + chunk.length > maximumObjectBytes) {
          throw const ImageCacheFailure();
        }
        builder.add(chunk);
      }
      return ImageCacheResponse(response.statusCode, builder.takeBytes(), {
        for (final name in [
          'cache-control',
          'etag',
          'last-modified',
          'vary',
          'age',
        ])
          name: ?response.headers.value(name),
      });
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}

typedef ImageCacheRequest =
    Future<ImageCacheResponse> Function(Uri, Map<String, String>);

class ImageCacheResponse {
  const ImageCacheResponse(this.status, this.bytes, [this.headers = const {}]);
  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;
}

class CachedImageBytes {
  const CachedImageBytes(this.bytes, this.identity, {this.cacheable = true});
  final Uint8List bytes;
  final String identity;
  final bool cacheable;
}

class ImageCacheUsage {
  const ImageCacheUsage(this.usedBytes, this.capacityBytes, this.objects);
  final int usedBytes, capacityBytes, objects;
}

class ImageCacheFailure implements Exception {
  const ImageCacheFailure();
}

class ImageCacheCancelled implements Exception {
  const ImageCacheCancelled();
}
