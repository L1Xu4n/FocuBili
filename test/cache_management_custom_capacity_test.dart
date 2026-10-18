import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/cache_management_page.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/media_cache_service.dart';

const _mib = 1024 * 1024;

class _VideoCache implements MediaCacheService {
  @override
  Future<MediaCacheStatus> loadStatus() async => const MediaCacheStatus(
    usedBytes: 0,
    capacityBytes: defaultMediaCacheBytes,
    isPlaybackActive: false,
  );

  @override
  Future<MediaCacheStatus> setCapacityBytes(int bytes) async =>
      throw StateError('Unexpected video capacity change');

  @override
  Future<MediaCacheStatus> clearCache() async =>
      throw StateError('Unexpected cache clearing');
}

class _MemoryImages extends ImageResourceCache {
  _MemoryImages(int capacity) : value = ImageCacheUsage(0, capacity, 0);
  ImageCacheUsage value;

  @override
  Future<ImageCacheUsage> status() async => value;

  @override
  Future<ImageCacheUsage> setCapacity(int bytes) async =>
      value = ImageCacheUsage(0, bytes, 0);

  @override
  Future<ImageCacheUsage> clear() async =>
      throw StateError('Unexpected image clearing');
}

class _TemporaryImages extends _MemoryImages {
  _TemporaryImages(this.tester, this.backend, ImageCacheUsage initial)
    : super(initial.capacityBytes) {
    value = initial;
  }
  final WidgetTester tester;
  final ImageResourceCache backend;
  Future<ImageCacheUsage>? pendingWrite;

  @override
  Future<ImageCacheUsage> setCapacity(int bytes) => pendingWrite = tester
      .runAsync(() => backend.setCapacity(bytes))
      .then((saved) => value = saved!);
}

Finder _field(int capacity) =>
    find.byKey(ValueKey('image-cache-capacity-$capacity'));

Future<DropdownButton<int>> _render(
  WidgetTester tester,
  ImageResourceCache images,
  int capacity, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CacheManagementPage(service: _VideoCache(), imageCache: images),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await tester.scrollUntilVisible(_field(capacity), 300, maxScrolls: 20);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return tester.widget<DropdownButton<int>>(
    find.descendant(
      of: _field(capacity),
      matching: find.byWidgetPredicate(
        (widget) => widget is DropdownButton<int>,
      ),
    ),
  );
}

void _uniqueCurrentAndPresets(DropdownButton<int> picker, int capacity) {
  final values = picker.items!.map((item) => item.value).toList();
  final presets = ImageResourceCache.capacities
      .map((mib) => mib * _mib)
      .toList();
  expect(picker.value, capacity);
  expect(values.where((value) => value == capacity), hasLength(1));
  expect(values.toSet().length, values.length);
  expect(values, containsAll(presets));
  expect(values, hasLength(presets.contains(capacity) ? 4 : 5));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final capacity in [0, 1, 128, 100 * _mib]) {
    testWidgets(
      'custom image capacity $capacity renders its exact current value',
      (tester) async {
        final images = _MemoryImages(capacity);
        addTearDown(images.dispose);
        final picker = await _render(tester, images, capacity);
        _uniqueCurrentAndPresets(picker, capacity);
        expect(
          find.text('自定义 · ${formatMediaCacheBytes(capacity)}'),
          findsOneWidget,
        );
        expect(images.value.capacityBytes, capacity);
      },
    );
  }

  for (final mib in ImageResourceCache.capacities) {
    testWidgets('preset $mib MiB has no duplicate custom current item', (
      tester,
    ) async {
      final images = _MemoryImages(mib * _mib);
      addTearDown(images.dispose);
      final picker = await _render(tester, images, mib * _mib);
      _uniqueCurrentAndPresets(picker, mib * _mib);
      expect(find.textContaining('自定义'), findsNothing);
    });
  }

  testWidgets(
    'every preset persists in a temporary cache and survives remount',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('focubili-picker-'),
      ))!;
      final directory = Directory('${root.path}/focubili_images_v1');
      addTearDown(() async => root.delete(recursive: true));
      ImageResourceCache cache() {
        final result = ImageResourceCache(
          directory: () async => directory,
          request: (_, _) async => throw StateError('No network in fixture'),
        );
        addTearDown(result.dispose);
        return result;
      }

      var backend = cache();
      final initial = (await tester.runAsync(() => backend.setCapacity(128)))!;
      var images = _TemporaryImages(tester, backend, initial);
      addTearDown(images.dispose);
      var capacity = 128;
      for (final mib in ImageResourceCache.capacities) {
        await _render(tester, images, capacity);
        await tester.tap(_field(capacity));
        await tester.pumpAndSettle();
        await tester.tap(find.text('$mib MB').last);
        expect(images.pendingWrite, isNotNull);
        await images.pendingWrite;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        capacity = mib * _mib;
        expect((await images.status()).capacityBytes, capacity);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        backend = cache();
        final reopened = (await tester.runAsync(backend.status))!;
        expect(reopened.capacityBytes, capacity);
        images = _TemporaryImages(tester, backend, reopened);
        addTearDown(images.dispose);
        final rebuilt = await _render(tester, images, capacity);
        _uniqueCurrentAndPresets(rebuilt, capacity);
        expect(find.textContaining('自定义'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  for (final capacity in [128, 100 * _mib]) {
    testWidgets('custom capacity $capacity fits 320px with 200 percent text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final images = _MemoryImages(capacity);
      addTearDown(images.dispose);
      final picker = await _render(tester, images, capacity, textScale: 2);
      _uniqueCurrentAndPresets(picker, capacity);
      await tester.tap(_field(capacity));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('512 MB').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(images.value.capacityBytes, 512 * _mib);
    });
  }
}
