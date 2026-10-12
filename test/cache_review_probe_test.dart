import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/common/app_network_image.dart';
import 'package:focubili/features/profile/cache_management_page.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/media_cache_service.dart';

import 'subscription_compact_ui_test.dart'
    show captureSubscriptionUi, loadBetaReviewFonts;

class _RealNetwork extends HttpOverrides {}

class _Media implements MediaCacheService {
  _Media(this.status);
  MediaCacheStatus status;
  @override
  Future<MediaCacheStatus> loadStatus() async => status;
  @override
  Future<MediaCacheStatus> setCapacityBytes(int bytes) async =>
      status = MediaCacheStatus(
        usedBytes: status.usedBytes,
        capacityBytes: bytes,
        isPlaybackActive: false,
        storageKind: status.storageKind,
      );
  @override
  Future<MediaCacheStatus> clearCache() async => status = MediaCacheStatus(
    usedBytes: 0,
    capacityBytes: status.capacityBytes,
    isPlaybackActive: false,
    storageKind: status.storageKind,
  );
}

class _Images extends ImageResourceCache {
  ImageCacheUsage value = const ImageCacheUsage(
    37 * 1024 * 1024,
    256 * 1024 * 1024,
    128,
  );
  @override
  Future<ImageCacheUsage> status() async => value;
  @override
  Future<ImageCacheUsage> setCapacity(int bytes) async =>
      value = ImageCacheUsage(value.usedBytes, bytes, value.objects);
  @override
  Future<ImageCacheUsage> clear() async =>
      value = ImageCacheUsage(0, value.capacityBytes, 0);
}

class _BytesImageCache extends ImageResourceCache {
  _BytesImageCache(this.bytes, Directory root)
    : super(
        directory: () async => Directory('${root.path}/focubili_images_v1'),
        accountScoped: true,
      );
  final Uint8List bytes;
  int loads = 0;
  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    loads++;
    return CachedImageBytes(bytes, 'fixture-decoded-image');
  }
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff3c7580), BlendMode.src);
  canvas.drawCircle(
    const Offset(200, 75),
    50,
    Paint()..color = const Color(0xffe3dbc4),
  );
  canvas.drawRect(
    const Rect.fromLTWH(40, 40, 80, 120),
    Paint()..color = const Color(0xff74a791),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 180);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  testWidgets('actual HTTP and widget revisit/restart request comparison', (
    tester,
  ) async {
    final report = <String, Object?>{};
    await tester.runAsync(() async {
      final bytes = await _png();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final root = await Directory.systemTemp.createTemp(
        'focubili_cache_probe_',
      );
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.set('content-type', 'image/png');
        request.response.headers.set('cache-control', 'max-age=60');
        request.response.add(bytes);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/cover.png';
      final original = HttpOverrides.current;
      HttpOverrides.global = _RealNetwork();
      final previousClient = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => HttpClient();
      try {
        // The old Image.network path has only decoded RAM storage. Evict that
        // layer to model memory pressure/restart before each route reopening.
        for (var i = 0; i < 10; i++) {
          final ready = Completer<void>();
          final provider = NetworkImage(url);
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (image, sync) {
              if (!ready.isCompleted) ready.complete();
            },
            onError: (Object error, StackTrace? stack) {
              if (!ready.isCompleted) ready.completeError(error, stack);
            },
          );
          stream.addListener(listener);
          await ready.future;
          stream.removeListener(listener);
          await provider.evict();
        }
        report['before_network_image_10_reopens'] = {'http_requests': requests};
        expect(requests, 10);
        requests = 0;
        ImageResourceCache service() => ImageResourceCache(
          directory: () async => Directory('${root.path}/focubili_images_v1'),
          accountScoped: true,
        );
        final cache = service();
        final watch = Stopwatch()..start();
        for (var i = 0; i < 10; i++) {
          await cache.load(url);
        }
        watch.stop();
        final restarted = service();
        await restarted.load(url);
        report['after_10_reopens_plus_service_restart'] = {
          'http_requests': requests,
          'elapsed_microseconds': watch.elapsedMicroseconds,
          'encoded_bytes': (await cache.status()).usedBytes,
        };
        expect(requests, 1);
        await cache.clear();
        requests = 0;
        await Future.wait([cache.load(url), restarted.load(url)]);
        report['two_instances_concurrent'] = {'http_requests': requests};
        expect(requests, 1);
        cache.dispose();
        restarted.dispose();
        const output = String.fromEnvironment('CACHE_PERF_OUTPUT');
        if (output.isNotEmpty) {
          await File(output).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          );
        }
      } finally {
        debugNetworkImageHttpClientProvider = previousClient;
        HttpOverrides.global = original;
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    });
  });

  testWidgets('cache management narrow large text and desktop screenshots', (
    tester,
  ) async {
    await loadBetaReviewFonts(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final config in [
      (const Size(390, 844), 1.0, Brightness.light, 'mobile'),
      (const Size(320, 850), 1.8, Brightness.light, 'large-text'),
      (const Size(1280, 950), 1.0, Brightness.dark, 'desktop-dark'),
      (const Size(1280, 950), 1.0, Brightness.dark, 'desktop-memory'),
    ]) {
      tester.view.physicalSize = config.$1;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      final images = _Images();
      final theme = config.$3 == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'BetaReview'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(config.$2)),
              child: child!,
            ),
            home: CacheManagementPage(
              imageCache: images,
              service: _Media(
                MediaCacheStatus(
                  usedBytes: 128 * 1024 * 1024,
                  capacityBytes: config.$4 == 'desktop-memory'
                      ? defaultMemoryBufferBytes
                      : defaultMediaCacheBytes,
                  isPlaybackActive: false,
                  storageKind: config.$4 == 'desktop-memory'
                      ? MediaCacheStorageKind.windowsPlaybackBuffer
                      : MediaCacheStorageKind.androidPersistent,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureSubscriptionUi(tester, key, 'cache-video-${config.$4}');
      await tester.scrollUntilVisible(
        find.byKey(const Key('clear-image-cache')),
        250,
      );
      await captureSubscriptionUi(tester, key, 'cache-images-${config.$4}');
      await tester.scrollUntilVisible(
        find.byKey(const Key('clear-subtitle-cache')),
        250,
      );
      await captureSubscriptionUi(tester, key, 'cache-subtitles-${config.$4}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      images.dispose();
    }
  });

  testWidgets(
    'account invalidation reloads public images but never stale credentials',
    (tester) async {
      late Directory root;
      late Uint8List bytes;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('account_image_');
        bytes = await _png();
      });
      final cache = _BytesImageCache(bytes, root);
      for (final private in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: AppNetworkImage(
              key: ValueKey(private),
              cache: cache,
              imageUrl: 'https://fixture.invalid/a',
              httpHeaders: private ? {'Cookie': 'fixture-only'} : const {},
              width: 100,
              height: 60,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final previous = cache.loads;
        CacheLifecycle.accountChanged();
        await tester.pumpAndSettle();
        expect(cache.loads, previous + (private ? 0 : 1));
      }
      await tester.pumpWidget(const SizedBox());
      cache.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );

  testWidgets(
    'real decoded image clear removes visible and offscreen memory keys',
    (tester) async {
      late Directory root;
      late ImageResourceCache cache;
      late Uint8List bytes;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('focubili_widget_cache_');
        bytes = await _png();
        cache = _BytesImageCache(bytes, root);
      });
      final baseline = PaintingBinding.instance.imageCache.currentSize;
      await tester.pumpWidget(
        MaterialApp(
          home: AppNetworkImage(
            cache: cache,
            imageUrl: 'https://fixture.invalid/a',
            width: 160,
            height: 90,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 10 &&
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .every((image) => image.image == null);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(RawImage), findsOneWidget);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(
        PaintingBinding.instance.imageCache.currentSize,
        greaterThan(baseline),
      );
      await tester.runAsync(() => cache.clear());
      await tester.pump();
      expect(PaintingBinding.instance.imageCache.currentSize, baseline);
      cache.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
