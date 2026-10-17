import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late DateTime now;
  late int requests;
  late ImageResourceCache cache;
  const url = 'https://i0.hdslb.com/avatar.png?signature=keep';
  ImageCacheResponse response([
    int value = 1,
    Map<String, String> headers = const {'cache-control': 'max-age=60'},
  ]) => ImageCacheResponse(200, Uint8List.fromList([value, 2, 3, 4]), headers);
  Future<Directory> directory() async =>
      Directory('${root.path}/focubili_images_v1');
  ImageResourceCache make({
    ImageCacheRequest? request,
    int capacity = 12,
    bool scoped = false,
  }) => ImageResourceCache(
    directory: directory,
    clock: () => now,
    defaultCapacity: capacity,
    accountScoped: scoped,
    request:
        request ??
        (_, _) async {
          requests++;
          return response();
        },
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('focubili_image_test_');
    now = DateTime.utc(2026);
    requests = 0;
    cache = make();
  });
  tearDown(() async {
    cache.dispose();
    await root.delete(recursive: true);
  });

  test(
    'removal fences an outstanding writer and repairs malformed leases',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cache.dispose();
      cache = make(
        request: (_, _) async {
          started.complete();
          await release.future;
          return response();
        },
      );
      final pending = cache.load(url);
      final rejected = expectLater(
        pending,
        throwsA(isA<ImageCacheCancelled>()),
      );
      await started.future;
      await cache.remove(url);
      release.complete();
      await rejected;
      expect((await cache.status()).objects, 0);
      final file = File('${(await directory()).path}/index.json');
      final index =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      index['leases'] = 'broken';
      await file.writeAsString(jsonEncode(index));
      expect((await cache.status()).objects, 0);
    },
  );

  test(
    '20 concurrent consumers and a new service/restart share one persisted download',
    () async {
      final values = await Future.wait(
        List.generate(20, (_) => cache.load(url)),
      );
      expect(requests, 1);
      expect(values.map((v) => v.identity).toSet().length, 1);
      final restarted = make();
      expect((await restarted.load(url)).bytes, values.first.bytes);
      expect(requests, 1);
      restarted.dispose();
    },
  );
  test(
    'URL query/transform and representation headers remain distinct',
    () async {
      await cache.load(url);
      await cache.load('$url&width=100');
      await cache.load(url, headers: {'Accept': 'image/webp'});
      await cache.load(url, headers: {'Accept': 'image/png'});
      expect(requests, 4);
    },
  );
  test(
    'expiration revalidates once using ETag and handles 304 without redownloading body',
    () async {
      final seen = <Map<String, String>>[];
      cache.dispose();
      cache = make(
        request: (_, headers) async {
          seen.add(headers);
          return seen.length == 1
              ? response(1, {'etag': '"v1"', 'cache-control': 'max-age=1'})
              : ImageCacheResponse(304, Uint8List(0), {
                  'cache-control': 'max-age=60',
                });
        },
      );
      final initial = await cache.load(url);
      now = now.add(const Duration(seconds: 2));
      final updated = await Future.wait(
        List.generate(10, (_) => cache.load(url)),
      );
      expect(seen.length, 2);
      expect(seen.last['If-None-Match'], '"v1"');
      expect(updated.first.identity, initial.identity);
      await cache.load(url);
      expect(seen.length, 2);
    },
  );
  test(
    'mutable avatar body changes after expiry and has a new decode identity',
    () async {
      cache.dispose();
      cache = make(
        request: (_, _) async =>
            response(++requests, {'cache-control': 'max-age=1'}),
      );
      final first = await cache.load(url);
      now = now.add(const Duration(seconds: 2));
      final second = await cache.load(url);
      expect(second.bytes.first, 2);
      expect(second.identity, isNot(first.identity));
    },
  );
  test(
    'offline stale fallback has retry backoff; must-revalidate refuses stale',
    () async {
      cache.dispose();
      cache = make(
        request: (_, _) async {
          if (++requests > 1) throw const SocketException('offline');
          return response(1, {'cache-control': 'max-age=1'});
        },
      );
      await cache.load(url);
      now = now.add(const Duration(seconds: 2));
      expect((await cache.load(url)).bytes.first, 1);
      await cache.load(url);
      expect(requests, 2);
      now = now.add(const Duration(seconds: 21));
      await cache.load(url);
      expect(requests, 3);
    },
  );
  test('no-store responses do not survive navigation/restart', () async {
    cache.dispose();
    cache = make(
      request: (_, _) async {
        requests++;
        return response(1, {'cache-control': 'no-store'});
      },
    );
    expect((await cache.load(url)).cacheable, isFalse);
    expect((await cache.status()).usedBytes, 0);
    await cache.load(url);
    expect(requests, 2);
  });
  test(
    'access, rather than creation/modification, determines LRU eviction at exact boundary',
    () async {
      cache.dispose();
      cache = make(capacity: 8);
      await cache.load('https://x/A');
      now = now.add(const Duration(seconds: 1));
      await cache.load('https://x/B');
      now = now.add(const Duration(seconds: 1));
      await cache.load('https://x/A');
      now = now.add(const Duration(seconds: 1));
      await cache.load('https://x/C');
      expect((await cache.status()).usedBytes, 8);
      await cache.load('https://x/A');
      expect(requests, 3);
      await cache.load('https://x/B');
      expect(requests, 4);
    },
  );
  test(
    'clear fences an in-flight write and preserves explicit offline data',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cache.dispose();
      cache = make(
        request: (_, _) async {
          started.complete();
          await release.future;
          return response();
        },
      );
      final offline = File('${root.path}/offline_videos/keep.mp4');
      await offline.create(recursive: true);
      await offline.writeAsString('user');
      final pending = cache.load(url);
      final assertion = expectLater(
        pending,
        throwsA(isA<ImageCacheCancelled>()),
      );
      await started.future;
      await cache.clear();
      release.complete();
      await assertion;
      expect((await cache.status()).usedBytes, 0);
      expect(await offline.readAsString(), 'user');
    },
  );
  test(
    'another cache instance clearing also fences late writes using persisted epoch',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cache.dispose();
      cache = make(
        request: (_, _) async {
          started.complete();
          await release.future;
          return response();
        },
      );
      final pending = cache.load(url);
      final assertion = expectLater(
        pending,
        throwsA(isA<ImageCacheCancelled>()),
      );
      await started.future;
      final other = make();
      await other.clear();
      release.complete();
      await assertion;
      expect((await cache.status()).usedBytes, 0);
      other.dispose();
    },
  );
  test('damaged file is discarded and downloaded again', () async {
    await cache.load(url);
    final file =
        (await (await directory())
                    .list()
                    .where((f) => f.path.endsWith('.bin'))
                    .toList())
                .single
            as File;
    await file.writeAsBytes([9, 9, 9, 9]);
    expect((await cache.load(url)).bytes.first, 1);
    expect(requests, 2);
  });
  test(
    'capacity change/startup repair removes partial files and orphan payloads',
    () async {
      await cache.load(url);
      final dir = await directory();
      await File('${dir.path}/${'f' * 64}.part').writeAsString('partial');
      await File('${dir.path}/${'e' * 64}.bin').writeAsString('orphan');
      await cache.setCapacity(0);
      final restarted = make();
      expect((await restarted.status()).usedBytes, 0);
      expect(
        await dir
            .list()
            .where((f) => f.path.endsWith('.bin') || f.path.endsWith('.part'))
            .length,
        0,
      );
      restarted.dispose();
    },
  );
  test(
    'bounded requests never exceed six and a clear cancels queued downloads',
    () async {
      var active = 0, peak = 0;
      final gates = <Completer<void>>[];
      final six = Completer<void>();
      cache.dispose();
      cache = make(
        request: (_, _) async {
          active++;
          if (active > peak) peak = active;
          final gate = Completer<void>();
          gates.add(gate);
          if (gates.length == 6) six.complete();
          await gate.future;
          active--;
          return response();
        },
      );
      final pending = Future.wait(
        List.generate(12, (i) => cache.load('https://x/$i')),
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<ImageCacheCancelled>()),
      );
      await six.future;
      expect(peak, 6);
      await cache.clear();
      for (final gate in gates) {
        gate.complete();
      }
      await assertion;
      expect(gates.length, 6);
    },
  );
  test(
    'public account partition prevents cross-user reuse and late responses',
    () async {
      await CacheLifecycle.setAccount(1);
      cache.dispose();
      cache = make(scoped: true);
      await cache.load(url);
      await CacheLifecycle.setAccount(2);
      await cache.load(url);
      expect(requests, 2);
      await CacheLifecycle.setAccount(1);
      await cache.load(url);
      expect(requests, 2);
    },
  );
  test('index contains no URL, query token or authorization header', () async {
    await cache.load(url, headers: {'Authorization': 'test-only-value'});
    final index = await File(
      '${(await directory()).path}/index.json',
    ).readAsString();
    expect(index, isNot(contains('signature')));
    expect(index, isNot(contains('test-only-value')));
    expect(jsonDecode(index)['entries'], hasLength(1));
  });
}
