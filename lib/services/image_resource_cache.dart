import 'cache_file_lock.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'cache_lifecycle.dart';
import 'app_http_client.dart';
import 'bilibili_image_url_policy.dart';

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
  static final Map<String, Set<Completer<void>>> _directoryWaiters = {};
  static final Set<String> _localLeases = {};
  static final int _isolateId = Random.secure().nextInt(1 << 32);
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
  final _leaseReleases = <String, Future<void> Function()>{};
  int _revision = 0;
  final _revisionWaiters = <Completer<void>>{};
  int get revision => _revision;
  bool _accountInvalidation = false;
  bool get accountInvalidation => _accountInvalidation;

  /// Cancels local waiters when the active account changes.
  void _accountChanged() {
    _accountInvalidation = true;
    _advanceRevision();
    notifyListeners();
  }

  /// Invalidates in-flight work and immediately releases its local waiters.
  void _advanceRevision() {
    _revision++;
    _retryAfter.clear();
    for (final waiter in _revisionWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _revisionWaiters.clear();
    for (final release in _leaseReleases.values.toList()) {
      unawaited(release());
    }
  }

  /// Gives equivalent paths one lock and notification key in this isolate.
  static String _directoryKey(Directory dir) {
    final path = dir.uri.normalizePath().toFilePath(
      windows: Platform.isWindows,
    );
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  /// Wakes waiters after a change to the persisted directory state.
  static void _wakeDirectory(String key) {
    for (final waiter
        in _directoryWaiters.remove(key) ?? const <Completer<void>>{}) {
      if (!waiter.isCompleted) waiter.complete();
    }
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

  /// Loads validated bytes, sharing each persisted download lease.
  /// Rechecks the cache revision after retrying a load blocked by a writer.
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
    Completer<void>? writerSignal;
    String? waitingDirectory;
    Duration? writerPoll;
    try {
      try {
        await _locked((dir, index) async {
          _checkRevision(revision);
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
              final blockers = existing != null ? [existing] : leases.values;
              waitingDirectory = _directoryKey(dir);
              writerSignal = Completer<void>();
              _directoryWaiters
                  .putIfAbsent(waitingDirectory!, () => {})
                  .add(writerSignal!);
              _revisionWaiters.add(writerSignal!);
              if (blockers.any(
                (entry) => !_localLeases.contains(entry['owner']),
              )) {
                writerPoll = const Duration(milliseconds: 100);
              } else {
                final firstExpiry = blockers
                    .map((entry) => entry['until'] as int)
                    .reduce(min);
                writerPoll = Duration(
                  milliseconds: max(
                    1,
                    firstExpiry - DateTime.now().millisecondsSinceEpoch,
                  ),
                );
              }
            } else {
              final owner =
                  '$pid:$_isolateId:${DateTime.now().microsecondsSinceEpoch}:${_leaseSerial++}';
              lease = owner;
              _localLeases.add(owner);
              Future<void>? release;
              _leaseReleases[owner] = () =>
                  release ??= _releaseLease(key, owner);
              leases[key] = {
                'owner': owner,
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
      if (writerSignal case final signal?) {
        final timer = Timer(writerPoll!, () {
          if (!signal.isCompleted) signal.complete();
        });
        try {
          _checkRevision(revision);
          await signal.future;
        } finally {
          timer.cancel();
          _revisionWaiters.remove(signal);
          final directory = waitingDirectory!;
          final waiters = _directoryWaiters[directory];
          waiters?.remove(signal);
          if (waiters?.isEmpty == true) _directoryWaiters.remove(directory);
        }
        _checkRevision(revision);
        return await _load(url, headers, key, revision);
      }
      _checkRevision(revision);
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
        final uri = Uri.parse(url);
        var response = await _limitedRequest(uri, conditional, revision);
        while (true) {
          _checkRevision(revision);
          if (response.status != 200 &&
              !(response.status == 304 && previous != null)) {
            if ([401, 403, 404, 410].contains(response.status)) {
              previous = null;
              if (epoch != null && lease != null) {
                await _removeKey(key, epoch: epoch, lease: lease);
              }
            }
            throw const ImageCacheFailure();
          }
          final bytes = response.status == 304
              ? previous!.bytes
              : response.bytes;
          if (bytes.isEmpty || bytes.length > maximumObjectBytes) {
            throw const ImageCacheFailure();
          }
          final digest = response.status == 304
              ? record!['digest'] as String
              : sha256.convert(bytes).toString();
          final control =
              response.headers['cache-control']?.toLowerCase() ??
              (response.status == 304
                  ? (record?['control'] as String?)
                  : null) ??
              '';
          final noStore =
              control.contains('no-store') ||
              (response.headers['vary']
                      ?.split(',')
                      .any((value) => value.trim() == '*') ??
                  false);
          final seconds = int.tryParse(
            RegExp(
                  r'(?:^|,)\s*max-age\s*=\s*"?(\d+)',
                ).firstMatch(control)?.group(1) ??
                '',
          );
          final age = int.tryParse(response.headers['age'] ?? '') ?? 0;
          final maxTtl = BilibiliImageUrlPolicy.isProvenImmutableContentUrl(uri)
              ? 7 * 86400
              : 86400;
          final ttl = control.contains('no-cache')
              ? 0
              : ((seconds ?? 86400) - max(0, age)).clamp(0, maxTtl);
          final now = _clock();
          var retryUnconditionally = response.status == 304 && lease == null;
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
                final file = File('${dir.path}/$key.bin');
                if (response.status == 304) {
                  if (entries[key]?['digest'] != digest ||
                      await FileSystemEntity.type(
                            file.path,
                            followLinks: false,
                          ) !=
                          FileSystemEntityType.file ||
                      await file.length() != bytes.length) {
                    retryUnconditionally = true;
                    entries.remove(key);
                    return;
                  }
                } else {
                  final temp = File('${dir.path}/$key.part');
                  if (await FileSystemEntity.type(
                        temp.path,
                        followLinks: false,
                      ) ==
                      FileSystemEntityType.link) {
                    await Link(temp.path).delete();
                  }
                  await temp.writeAsBytes(bytes, flush: true);
                  await temp.rename(file.path);
                }
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
              retryUnconditionally = response.status == 304;
            }
          }
          if (retryUnconditionally) {
            _checkRevision(revision);
            previous = null;
            record = null;
            final unconditional = Map<String, String>.of(headers)
              ..removeWhere(
                (name, _) => const {
                  'if-none-match',
                  'if-modified-since',
                }.contains(name.toLowerCase()),
              );
            response = await _limitedRequest(uri, unconditional, revision);
            continue;
          }
          _checkRevision(revision);
          _retryAfter.remove(key);
          return CachedImageBytes(
            bytes,
            '${epoch ?? revision}:$key:$digest',
            cacheable: !noStore,
          );
        }
      } on ImageCacheCancelled {
        rethrow;
      } catch (_) {
        _checkRevision(revision);
        _retryAfter[key] = _clock().add(const Duration(seconds: 20));
        if (_retryAfter.length > 512) {
          _retryAfter.remove(_retryAfter.keys.first);
        }
        if (previous != null && record?['mustRevalidate'] != true) {
          return previous!;
        }
        throw const ImageCacheFailure();
      }
    } finally {
      await _leaseReleases[lease]?.call();
      _checkRevision(revision);
    }
  }

  /// Releases just this writer's persisted lease, including after cancellation.
  Future<void> _releaseLease(String key, String owner) async {
    try {
      await _locked((_, index) async {
        final leases = index['leases'] as Map;
        if (leases[key]?['owner'] == owner) leases.remove(key);
      }, notifyWaiters: true);
    } catch (_) {
      // An expired lease also recovers from a killed writer or full disk.
    } finally {
      _leaseReleases.remove(owner);
      _localLeases.remove(owner);
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
    final directoryKey = _directoryKey(dir);
    final prior = _locks[directoryKey] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[directoryKey] = done.future;
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
        if (identical(_locks[directoryKey], done.future)) {
          _locks.remove(directoryKey);
        }
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
    _advanceRevision();
    notifyListeners();
    return _locked((dir, index) async {
      index['epoch'] = '${DateTime.now().microsecondsSinceEpoch}-$_revision';
      index['entries'] = <String, dynamic>{};
      index['leases'] = <String, dynamic>{};
      await _repair(dir, index);
      return _usage(index);
    }, notifyWaiters: true);
  }

  /// Removes the image for the current account and request headers.
  Future<void> remove(String url, {Map<String, String> headers = const {}}) =>
      _removeKey(_key(url, headers));

  /// Removes the captured key even if the active account has since changed.
  Future<void> _removeKey(String key, {String? epoch, String? lease}) =>
      _locked((dir, index) async {
        if (lease != null &&
            (index['epoch'] != epoch ||
                (index['leases'] as Map)[key]?['owner'] != lease)) {
          throw const ImageCacheCancelled();
        }
        (index['entries'] as Map).remove(key);
        (index['leases'] as Map).remove(key);
        await _delete(File('${dir.path}/$key.bin'));
      }, notifyWaiters: true);

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

  /// Serializes index transactions and signals changes after releasing the lock.
  Future<T> _locked<T>(
    Future<T> Function(Directory, Map<String, dynamic>) action, {
    bool notifyWaiters = false,
  }) async {
    final dir = (await _directory()).absolute;
    if (dir.uri.pathSegments.where((s) => s.isNotEmpty).last !=
            'focubili_images_v1' ||
        await FileSystemEntity.type(dir.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FileSystemException('Unsafe image cache directory');
    }
    await dir.create(recursive: true);
    final directoryKey = _directoryKey(dir);
    final prior = _locks[directoryKey] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[directoryKey] = done.future;
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
        if (identical(_locks[directoryKey], done.future)) {
          _locks.remove(directoryKey);
        }
        if (notifyWaiters) _wakeDirectory(directoryKey);
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

  /// Downloads through the bounded image pool without forwarding redirects.
  static Future<ImageCacheResponse> _download(
    Uri uri,
    Map<String, String> headers,
  ) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const ImageCacheFailure();
    }
    final response = await AppHttpTransport.shared.send(
      uri: uri,
      headers: headers,
      followRedirects: false,
      maxResponseBytes: maximumObjectBytes,
      timeout: const Duration(seconds: 25),
      pool: AppHttpClientPoolKind.publicImage,
    );
    return ImageCacheResponse(response.statusCode, response.bytes, {
      for (final name in [
        'cache-control',
        'etag',
        'last-modified',
        'vary',
        'age',
      ])
        if (response.headerValues(name).isNotEmpty)
          name: response.headerValues(name).join(', '),
    });
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
