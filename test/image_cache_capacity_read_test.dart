import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/cache_file_lock.dart';
import 'package:focubili/services/image_resource_cache.dart';

void main() {
  late Directory root, directory;
  late ImageResourceCache cache;
  var notifications = 0, requests = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili-capacity-read-');
    directory = Directory('${root.path}/focubili_images_v1');
    cache = ImageResourceCache(
      directory: () async => directory,
      defaultCapacity: 1234,
      request: (_, _) async {
        requests++;
        throw StateError('Capacity reads must not download');
      },
    );
    notifications = requests = 0;
    cache.addListener(() => notifications++);
  });
  tearDown(() async {
    expect(notifications, 0);
    expect(requests, 0);
    cache.dispose();
    await root.delete(recursive: true);
  });
  Future<File> index(String raw) async {
    await directory.create();
    return File('${directory.path}/index.json')..writeAsStringSync(raw);
  }

  test('cold read defaults without creating a directory or lock', () async {
    expect(await cache.readCapacity(), 1234);
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'missing index preserves existing files without creating metadata',
    () async {
      await directory.create();
      final orphan = File('${directory.path}/orphan.part');
      await orphan.writeAsString('untouched');
      expect(await cache.readCapacity(), 1234);
      expect(await orphan.readAsString(), 'untouched');
      final entries = await directory.list().toList();
      expect(entries, hasLength(1));
      expect(
        await FileSystemEntity.identical(entries.single.path, orphan.path),
        isTrue,
      );
    },
  );

  test(
    'reads only capacity without repair, trimming, or index rewrite',
    () async {
      const raw = '{"capacity":0,"entries":"malformed","leases":false}';
      final file = await index(raw);
      final modified = await file.lastModified();
      final orphan = File('${directory.path}/${'a' * 64}.bin');
      await orphan.writeAsString('keep even at zero capacity');
      expect(await cache.readCapacity(), 0);
      expect(await file.readAsString(), raw);
      expect(await file.lastModified(), modified);
      expect(await orphan.readAsString(), 'keep even at zero capacity');
      expect(await File('${directory.path}/cache.lock').exists(), isFalse);
      expect(await File('${directory.path}/index.part').exists(), isFalse);
    },
  );

  test('corrupt capacity never repairs or falls back to the default', () async {
    for (final raw in [
      '{broken',
      '[]',
      'null',
      '{}',
      for (final value in <Object?>[null, true, -1, 1.5, 1.0, '123', [], {}])
        jsonEncode({'capacity': value}),
    ]) {
      final file = await index(raw);
      await expectLater(cache.readCapacity(), throwsFormatException);
      expect(await file.readAsString(), raw);
      expect(await File('${directory.path}/cache.lock').exists(), isFalse);
    }
  });

  test(
    'existing writer lock is awaited without changing the lock file',
    () async {
      final file = await index('{"capacity":1}');
      final lockPath = '${directory.path}/cache.lock';
      await File(lockPath).writeAsString('fixture lock');
      final lockBytes = await File(lockPath).readAsBytes();
      final modified = await File(lockPath).lastModified();
      final lock = await CacheFileLock.acquire(lockPath);
      var released = false;
      addTearDown(() async {
        if (!released) await lock.release();
      });
      var finished = false;
      final pending = cache.readCapacity().whenComplete(() => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(finished, isFalse);
      await file.writeAsString('{"capacity":9876}');
      await lock.release();
      released = true;
      expect(await pending, 9876);
      expect(await File(lockPath).readAsBytes(), lockBytes);
      expect(await File(lockPath).lastModified(), modified);
    },
  );

  test(
    'invalid capacity releases both reader locks for the next writer',
    () async {
      final file = await index('{"capacity":-1}');
      final path = '${directory.path}/cache.lock';
      await (await CacheFileLock.acquire(path)).release();
      await expectLater(cache.readCapacity(), throwsFormatException);
      final writer = await CacheFileLock.acquire(path);
      try {
        await file.writeAsString('{"capacity":5}');
      } finally {
        await writer.release();
      }
      expect(await cache.readCapacity(), 5);
    },
  );

  test(
    'invalid metadata entity fails rather than being treated as missing',
    () async {
      await directory.create();
      await Directory('${directory.path}/index.json').create();
      await expectLater(
        cache.readCapacity(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${directory.path}/cache.lock').exists(), isFalse);
    },
  );
}
