import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/cache_file_lock.dart';
import 'package:focubili/services/image_resource_cache.dart';

Future<void> _increment(String root) async {
  for (var i = 0; i < 10; i++) {
    final lock = await CacheFileLock.acquire('$root/lock');
    try {
      final counter = File('$root/counter');
      final value = int.parse(await counter.readAsString());
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await counter.writeAsString('${value + 1}');
    } finally {
      await lock.release();
    }
  }
}

Future<void> _image(String root) async {
  final cache = ImageResourceCache(
    directory: () async => Directory('$root/focubili_images_v1'),
    request: (_, _) async {
      await File(
        '$root/requests',
      ).writeAsString('x', mode: FileMode.append, flush: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return ImageCacheResponse(200, Uint8List.fromList([1, 2, 3, 4]));
    },
  );
  try {
    await cache.load('https://fixture.invalid/shared');
  } finally {
    cache.dispose();
  }
}

void main() {
  test('read-only acquisition never creates an absent lock file', () async {
    final root = await Directory.systemTemp.createTemp('focubili_read_lock_');
    addTearDown(() => root.delete(recursive: true));
    expect(
      await CacheFileLock.acquireExisting('${root.path}/missing/lock'),
      isNull,
    );
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'shared readers coexist and an exclusive writer waits for both',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focubili_shared_lock_',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/lock';
      await File(path).writeAsString('fixture');
      final first = (await CacheFileLock.acquireExisting(path))!;
      final second = (await CacheFileLock.acquireExisting(path))!;
      var firstReleased = false, secondReleased = false;
      addTearDown(() async {
        if (!firstReleased) await first.release();
        if (!secondReleased) await second.release();
      });
      var acquired = false;
      final writer = CacheFileLock.acquire(path).then((lock) {
        acquired = true;
        return lock;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(acquired, isFalse);
      await first.release();
      firstReleased = true;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(acquired, isFalse);
      await second.release();
      secondReleased = true;
      await (await writer).release();
      expect(await File(path).readAsString(), 'fixture');
    },
  );

  test('failed read-only lock acquisition releases its descriptor', () async {
    final root = await Directory.systemTemp.createTemp(
      'focubili_timeout_lock_',
    );
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/lock';
    final writer = await CacheFileLock.acquire(path);
    try {
      await expectLater(
        CacheFileLock.acquireExisting(
          path,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await writer.release();
    }
    await (await CacheFileLock.acquireExisting(path))!.release();
    await File(path).delete();
    expect(await File(path).exists(), isFalse);
  });

  test(
    'separate isolates cannot simultaneously modify a cache index',
    () async {
      final root = await Directory.systemTemp.createTemp('focubili_lock_');
      try {
        await File('${root.path}/counter').writeAsString('0');
        final path = root.path;
        await Future.wait(
          List.generate(3, (_) => Isolate.run(() => _increment(path))),
        );
        expect(await File('$path/counter').readAsString(), '30');
        final lock = await CacheFileLock.acquire('$path/lock');
        await lock.release();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'two isolates share an expiring download lease and committed image',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focubili_image_isolates_',
      );
      try {
        final path = root.path;
        await Future.wait(
          List.generate(2, (_) => Isolate.run(() => _image(path))),
        );
        expect(await File('$path/requests').readAsString(), 'x');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
