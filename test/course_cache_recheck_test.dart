import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_access.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/course_cache_validity.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/resumable_media_download.dart';

import 'course_cache_library_test.dart'
    show Access, FixtureTransfer, part, video;

void main() {
  late Directory tmp;
  late HttpServer cdn;
  late CourseCacheLibrary store;
  late Access access;
  late List<int> bytes;
  late List<String> requests;
  late String tag;
  late int mediaBodyBytes;
  late bool unsupported;
  late bool unavailable;
  Completer<void>? entered, releaseHead;

  void plan(
    String signature, {
    String rendition = 'original',
    int quality = 64,
    bool withFallback = false,
  }) {
    final root = 'http://127.0.0.1:${cdn.port}';
    access.media = OfflineMediaPlan(
      video: OfflineMediaTrack(
        id: quality,
        codec: 'avc1.640028',
        bandwidth: 1234,
        urls: [
          '$root/v.m4s?upsig=$signature&rendition=$rendition',
          if (withFallback) '$root/backup.m4s?upsig=$signature',
        ],
      ),
      audio: OfflineMediaTrack(
        id: 30280,
        codec: 'mp4a.40.2',
        urls: ['$root/a.m4s?upsig=$signature'],
      ),
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('course_cache_recheck');
    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bytes = FixtureTransfer().payload;
    requests = [];
    mediaBodyBytes = 0;
    tag = '"etag-local-test-one"';
    unsupported = unavailable = false;
    entered = releaseHead = null;
    access = Access()..now = DateTime.utc(2026, 11, 18);
    plan('secret-signature-before');
    store = CourseCacheLibrary(
      access: access,
      clock: () => access.now,
      root: () async => tmp,
      downloader: ResumableMediaDownload(
        acceptUri: (u) => u.host == cdn.address.address && u.port == cdn.port,
      ),
    );
    cdn.listen((r) async {
      requests.add('${r.method} ${r.uri.path}');
      expect(r.headers.value('cookie'), isNull);
      if (r.method == 'HEAD' && entered != null) {
        if (!entered!.isCompleted) entered!.complete();
        await releaseHead!.future;
      }
      if (r.method == 'HEAD' &&
          (r.uri.path == '/backup.m4s' || unavailable || unsupported)) {
        r.response.statusCode = unavailable || r.uri.path == '/backup.m4s'
            ? 503
            : 405;
      } else {
        r.response.headers
          ..set('etag', tag)
          ..contentType = ContentType('video', 'mp4');
        r.response.contentLength = bytes.length;
        if (r.method != 'HEAD') {
          mediaBodyBytes += bytes.length;
          r.response.add(bytes);
        }
      }
      try {
        await r.response.close();
      } on HttpException {
        /* Interrupted by the test while HEAD was in flight. */
      }
    });
  });

  tearDown(() async {
    if (releaseHead case final release? when !release.isCompleted) {
      release.complete();
    }
    store.dispose();
    await cdn.close(force: true);
    await tmp.delete(recursive: true);
  });

  Future<CourseCacheEntry> cache() async {
    await store.start(video, part);
    expect(store.error, isNull);
    return (await store.entries()).single;
  }

  test(
    'signed URL rotation verifies two exact versions without downloading bytes',
    () async {
      final old = await cache();
      final files = await store.open(old);
      await File(files.video).setLastModified(DateTime.utc(2020));
      expect(requests, ['GET /v.m4s', 'GET /a.m4s']);
      expect(mediaBodyBytes, bytes.length * 2);
      final receipt = File.fromUri(
        File(files.video).parent.uri.resolve('entry.json'),
      );
      var raw = await receipt.readAsString();
      expect(raw, isNot(contains('upsig')));
      expect(raw, isNot(contains('etag-local')));
      expect(raw, isNot(contains('127.0.0.1')));
      expect(raw, contains('videoVersion'));
      expect(raw, contains('audioHash'));

      access.now = old.until!;
      plan('secret-signature-after');
      requests.clear();
      mediaBodyBytes = 0;
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
      final renewed = await cache();
      expect(requests, ['HEAD /v.m4s', 'HEAD /a.m4s']);
      expect(mediaBodyBytes, 0);
      expect(renewed.checkedAt, access.now);
      expect(renewed.until, access.now.add(access.window));
      expect(renewed.videoHash, old.videoHash);
      expect(
        (await File(files.video).lastModified()).toUtc(),
        DateTime.utc(2020),
      );
      raw = await receipt.readAsString();
      expect(raw, isNot(contains('secret-signature-after')));
      await cdn.close(force: true);
      expect(
        await File((await store.open(renewed)).video).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'legacy receipt keeps its old cutoff; authenticated recheck migrates matching bytes',
    () async {
      final old = await cache();
      final files = await store.open(old);
      final receipt = File.fromUri(
        File(files.video).parent.uri.resolve('entry.json'),
      );
      await receipt.writeAsString(
        jsonEncode(
          old.toJson()
            ..remove('authorization')
            ..['until'] = old.until!.millisecondsSinceEpoch,
        ),
      );
      var legacy = (await store.entries()).single;
      expect(legacy.expiryKind, CourseCacheExpiryKind.legacyReceipt);
      expect((await store.open(legacy)).video, files.video);
      access.now = old.checkedAt!.add(const Duration(days: 4));
      await expectLater(store.open(legacy), throwsA(isA<CourseCacheFailure>()));

      access.expiryKind = CourseCacheExpiryKind.noDeclaredDeadline;
      plan('new-signature-after-old-receipt');
      requests.clear();
      mediaBodyBytes = 0;
      final converted = await cache();
      expect(requests, ['HEAD /v.m4s', 'HEAD /a.m4s']);
      expect(mediaBodyBytes, 0);
      expect(converted.until, isNull);
      expect(converted.expiryKind, CourseCacheExpiryKind.noDeclaredDeadline);
      expect(converted.videoHash, old.videoHash);
      expect(converted.audioHash, old.audioHash);
      await cdn.close(force: true);
      final calls = access.calls;
      access.now = converted.checkedAt!.add(const Duration(days: 9));
      legacy = (await store.entries()).single;
      expect((await store.open(legacy)).video, files.video);
      expect(await File(files.video).readAsBytes(), bytes);
      expect(access.calls, calls); // No new entitlement or CDN request on open.
      access.mid = 73;
      CacheLifecycle.accountChanged();
      expect(await store.entries(), isEmpty);
      await expectLater(
        store.open(converted),
        throwsA(isA<CourseCacheFailure>()),
      );
    },
  );

  test(
    'a real deadline seen during a failed recheck caps a previously undated receipt',
    () async {
      access.expiryKind = CourseCacheExpiryKind.explicitLongTerm;
      final old = await cache();
      access.now = access.now.add(const Duration(days: 2));
      expect(await store.open(old), isNotNull);
      final end = access.now.add(const Duration(days: 3));
      access.failure = CourseCacheAccessException(
        '后续媒体请求失败',
        revokesReceipt: false,
        knownUntil: end,
      );
      requests.clear();
      await store.start(video, part);
      expect(requests, isEmpty);
      final shortened = (await store.entries()).single;
      expect(shortened.until, end);
      expect(shortened.expiryKind, CourseCacheExpiryKind.serverDeadline);
      access.now = end.subtract(const Duration(milliseconds: 1));
      expect(await store.open(old), isNotNull);
      access.now = end;
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
    },
  );

  test(
    'observed removal or refund revokes an undated receipt without deleting media',
    () async {
      access.expiryKind = CourseCacheExpiryKind.noDeclaredDeadline;
      final old = await cache();
      final files = await store.open(old);
      access.now = access.now.add(const Duration(days: 12));
      expect(await store.open(old), isNotNull);
      access.denied = true;
      requests.clear();
      await store.start(video, part);
      expect(requests, isEmpty);
      final revoked = (await store.entries()).single;
      expect(revoked.complete, isFalse);
      expect(revoked.hasMedia, isTrue);
      expect(await File(files.video).exists(), isTrue);
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
    },
  );

  test('a later missing date cannot extend a known real cutoff', () async {
    final old = await cache();
    final end = old.until!;
    access.now = end.subtract(const Duration(minutes: 10));
    access.expiryKind = CourseCacheExpiryKind.noDeclaredDeadline;
    requests.clear();
    final current = await cache();
    expect(requests, ['HEAD /v.m4s', 'HEAD /a.m4s']);
    expect(current.until, end);

    access.now = end;
    requests.clear();
    access.expiryKind = CourseCacheExpiryKind.explicitLongTerm;
    await store.start(video, part);
    expect(requests, isEmpty);
    expect((await store.entries()).single.until, end);
    await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
  });

  test(
    'a revoked receipt cannot turn an observed cutoff into no declared date',
    () async {
      access.expiryKind = CourseCacheExpiryKind.noDeclaredDeadline;
      final old = await cache();
      access.now = access.now.add(const Duration(days: 3));
      access.failure = CourseCacheAccessException(
        '已到期',
        knownUntil: access.now,
      );
      requests.clear();
      await store.start(video, part);
      expect((await store.entries()).single.complete, isFalse);
      expect(requests, isEmpty);

      access.failure = null;
      await store.start(video, part);
      expect(requests, isEmpty);
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
      access.expiryKind = CourseCacheExpiryKind.serverDeadline;
      access.window = const Duration(days: 5);
      final newer = await cache();
      expect(requests, ['HEAD /v.m4s', 'HEAD /a.m4s']);
      expect(newer.until, access.now.add(const Duration(days: 5)));
    },
  );

  test(
    'a changed ETag and identical lengths force a clean replacement',
    () async {
      final old = await cache();
      tag = '"etag-local-test-two"';
      bytes.last ^= 1;
      access.now = old.until!;
      requests.clear();
      final next = await cache();
      expect(requests, ['HEAD /v.m4s', 'GET /v.m4s', 'GET /a.m4s']);
      expect(next.videoHash, isNot(old.videoHash));
      expect(next.videoBytes, old.videoBytes);
    },
  );

  test('same tag on an alternate query representation is not proof', () async {
    final old = await cache();
    access.now = old.until!;
    plan('new-signature', rendition: 'other');
    requests.clear();
    await cache();
    expect(requests, ['HEAD /v.m4s', 'GET /v.m4s', 'GET /a.m4s']);
  });

  test('one damaged same-length audio track cannot renew or play', () async {
    final old = await cache();
    final files = await store.open(old);
    final audio = File(files.audio!);
    final damaged = await audio.readAsBytes();
    damaged.last ^= 1;
    await audio.writeAsBytes(damaged, flush: true);
    await audio.setLastModified(DateTime.utc(2020));
    await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
    access.now = old.until!;
    requests.clear();
    await cache();
    expect(requests, ['GET /v.m4s', 'GET /a.m4s']);
  });

  test(
    'incompatible legacy receipt is replaced once, then HEAD can renew',
    () async {
      final old = await cache();
      final files = await store.open(old);
      final receipt = File.fromUri(
        File(files.video).parent.uri.resolve('entry.json'),
      );
      await receipt.writeAsString(
        jsonEncode(
          old.toJson()
            ..remove('videoVersion')
            ..remove('audioVersion')
            ..remove('videoHash')
            ..remove('audioHash'),
        ),
      );
      access.now = old.until!;
      requests.clear();
      final updated = await cache();
      expect(requests, ['GET /v.m4s', 'GET /a.m4s']);
      access.now = updated.until!;
      requests.clear();
      await cache();
      expect(requests, ['HEAD /v.m4s', 'HEAD /a.m4s']);
    },
  );

  test(
    'unsupported HEAD and weak validators cannot renew without downloading',
    () async {
      final old = await cache();
      access.now = old.until!;
      unsupported = true;
      tag = 'W/"weak-etag"';
      requests.clear();
      final newEntry = await cache();
      expect(requests, ['HEAD /v.m4s', 'GET /v.m4s', 'GET /a.m4s']);
      expect(newEntry.videoVersion, isNull);
      expect(newEntry.videoHash, isNotNull);
    },
  );

  test(
    'available GET is not blocked by one HEAD 405 and another HEAD 503',
    () async {
      final old = await cache();
      access.now = old.until!;
      plan('renewed', withFallback: true);
      unsupported = true;
      requests.clear();
      final renewed = await cache();
      expect(requests, [
        'HEAD /v.m4s',
        'HEAD /backup.m4s',
        'GET /v.m4s',
        'GET /a.m4s',
      ]);
      expect(renewed.until!.isAfter(old.until!), isTrue);
    },
  );

  test(
    'short network failure neither extends nor invalidates a still-valid receipt',
    () async {
      final old = await cache();
      final checkout = access.now.add(const Duration(minutes: 10));
      access.now = checkout;
      requests.clear();
      access.failure = const CourseCacheAccessException(
        '网络暂不可用',
        revokesReceipt: false,
      );
      await store.start(video, part);
      expect((await store.open(old)).entry.until, old.until);
      expect(requests, isEmpty);

      access.failure = null;
      unavailable = true;
      await store.start(video, part);
      expect(store.error, contains('网络'));
      expect((await store.open(old)).entry.until, old.until);
      expect(requests, ['HEAD /v.m4s']);
      access.now = old.until!;
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
    },
  );

  test(
    'known earlier entitlement cap survives a later transient HEAD error',
    () async {
      final old = await cache();
      access.now = access.now.add(const Duration(minutes: 10));
      access.window = const Duration(minutes: 15);
      unavailable = true;
      await store.start(video, part);
      expect(store.error, contains('网络'));
      final fresh = (await store.open(old)).entry;
      expect(fresh.checkedAt, old.checkedAt);
      expect(fresh.until, access.now.add(access.window));
    },
  );

  test(
    'a transient API error retains an earlier verified authorization limit',
    () async {
      final old = await cache();
      final cap = access.now.add(const Duration(minutes: 30));
      access.failure = CourseCacheAccessException(
        '课程接口暂不可用',
        revokesReceipt: false,
        knownUntil: cap,
      );
      await store.start(video, part);
      expect(store.error, contains('暂不可用'));
      final fresh = (await store.open(old)).entry;
      expect(fresh.until, cap);
      expect(fresh.checkedAt, old.checkedAt);
    },
  );

  test(
    'known denial revokes the local receipt without a CDN request',
    () async {
      final old = await cache();
      access.failure = const CourseCacheAccessException('购买资格已失效');
      requests.clear();
      await store.start(video, part);
      expect(store.error, contains('资格'));
      final denied = (await store.entries()).single;
      expect(denied.hasMedia, isTrue);
      expect(denied.complete, isFalse);
      expect(requests, isEmpty);
      await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
    },
  );

  for (final changeAccount in [false, true]) {
    test(
      'unfinished HEAD publishes nothing when ${changeAccount ? 'changing accounts' : 'cancelled'}',
      () async {
        final old = await cache();
        access.now = old.until!;
        entered = Completer<void>();
        releaseHead = Completer<void>();
        final refresh = store.start(video, part);
        await entered!.future;
        if (changeAccount) {
          access.mid = 73;
          CacheLifecycle.accountChanged();
        } else {
          await store.pause();
        }
        await refresh;
        if (changeAccount) {
          expect(await store.entries(), isEmpty);
          access.mid = 51;
          CacheLifecycle.accountChanged();
        }
        expect((await store.entries()).single.until, old.until);
        await expectLater(store.open(old), throwsA(isA<CourseCacheFailure>()));
      },
    );
  }
}
