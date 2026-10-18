import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/media_cache_service.dart';

bool _samePath(String first, String second) =>
    File(first).absolute.uri == File(second).absolute.uri;

typedef _DeleteHook = void Function(FileSystemEntity entity, bool recursive);

// Real temporary files, with a deterministic unlink between enumeration and
// deletion. No production filesystem hooks or real application data are used.
class _RaceDirectory implements Directory {
  _RaceDirectory(this.inner, this.beforeDelete);

  final Directory inner;
  final _DeleteHook beforeDelete;

  FileSystemEntity _wrap(FileSystemEntity entity) => switch (entity) {
    Directory() => _RaceDirectory(entity, beforeDelete),
    File() => _RaceFile(entity, beforeDelete),
    _ => entity,
  };

  @override
  String get path => inner.path;
  @override
  Uri get uri => inner.uri;
  @override
  Directory get absolute => this;
  @override
  Directory get parent => inner.parent;
  @override
  Future<Directory> create({bool recursive = false}) async {
    await inner.create(recursive: recursive);
    return this;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => inner.list(recursive: recursive, followLinks: followLinks).map(_wrap);

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => inner
      .listSync(recursive: recursive, followLinks: followLinks)
      .map(_wrap)
      .toList();

  @override
  void deleteSync({bool recursive = false}) {
    beforeDelete(inner, recursive);
    inner.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RaceFile implements File {
  _RaceFile(this.inner, this.beforeDelete);

  final File inner;
  final _DeleteHook beforeDelete;
  @override
  String get path => inner.path;
  @override
  Uri get uri => inner.uri;
  @override
  void deleteSync({bool recursive = false}) {
    beforeDelete(inner, recursive);
    inner.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Directory cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili_cleanup_race_');
    cache = await Directory(
      '${root.path}/${WindowsMediaCacheService.cacheDirectoryName}',
    ).create();
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  WindowsMediaCacheService service(_DeleteHook hook) =>
      WindowsMediaCacheService(
        directoryLoader: () async => _RaceDirectory(cache, hook),
        playbackActiveLoader: () => false,
      );

  for (final name in ['session_abandoned', 'legacy']) {
    test('$name child disappears while its parent remains', () async {
      final directory = await Directory('${cache.path}/$name').create();
      final packet = await File('${directory.path}/packet').writeAsBytes([1]);
      var raced = false;
      await service((entity, recursive) {
        if (raced) return;
        if (_samePath(entity.path, directory.path) && recursive) {
          // macOS recursive unlink reports the root path when a child is gone.
          packet.deleteSync();
          raced = true;
          expect(directory.existsSync(), isTrue);
          throw PathNotFoundException(
            directory.path,
            const OSError('No such file or directory', 2),
            'Deletion failed',
          );
        }
        if (_samePath(entity.path, packet.path)) {
          packet.deleteSync();
          raced = true;
          expect(directory.existsSync(), isTrue);
        }
      }).maintain();
      expect(raced, isTrue);
      expect(directory.existsSync(), isFalse);
    });

    test('$name itself disappears after enumeration', () async {
      final directory = await Directory('${cache.path}/$name').create();
      var raced = false;
      await service((entity, _) {
        if (!_samePath(entity.path, directory.path) || raced) return;
        raced = true;
        directory.deleteSync(recursive: true);
      }).maintain();
      expect(raced, isTrue);
      expect(directory.existsSync(), isFalse);
    });
  }

  for (final errorCode in [2, 5, 13]) {
    test(
      'does not hide deletion error $errorCode for a surviving node',
      () async {
        final directory = await Directory('${cache.path}/legacy').create();
        final packet = await File('${directory.path}/packet').writeAsBytes([7]);
        await expectLater(
          service((_, _) {
            throw FileSystemException(
              'synthetic deletion failure',
              packet.path,
              OSError('failure', errorCode),
            );
          }).maintain(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await packet.readAsBytes(), [7]);
        // Both process-wide serialization and sessions.lock must release on error.
        await WindowsMediaCacheService(
          directoryLoader: () async => cache,
          playbackActiveLoader: () => false,
        ).maintain();
        expect(directory.existsSync(), isFalse);
      },
    );
  }

  for (final errorCode in <int?>[3, 5, 13, null]) {
    test('missing node does not mask unrelated OS error $errorCode', () async {
      final packet = await File('${cache.path}/packet').writeAsBytes([1]);
      final failure = FileSystemException(
        'synthetic deletion failure',
        packet.path,
        errorCode == null ? null : OSError('failure', errorCode),
      );
      final operation = service((entity, _) {
        if (!_samePath(entity.path, packet.path)) return;
        packet.deleteSync();
        throw failure;
      }).maintain();
      if (Platform.isWindows && errorCode == 3) {
        await operation;
      } else {
        await expectLater(operation, throwsA(same(failure)));
      }
      expect(packet.existsSync(), isFalse);
    });
  }

  test(
    'a failed no-follow type lookup cannot silently skip deletion',
    () async {
      final packet = await File('${cache.path}/packet').writeAsBytes([1]);
      final nativeZone = Zone.current;
      var deletionAttempted = false;
      await IOOverrides.runZoned(
        () => expectLater(
          service((entity, _) {
            if (!_samePath(entity.path, packet.path)) return;
            deletionAttempted = true;
            throw FileSystemException(
              'permission denied',
              packet.path,
              const OSError('permission denied', 13),
            );
          }).maintain(),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.osError?.errorCode,
              'OS error',
              13,
            ),
          ),
        ),
        fseGetTypeSync: (name, followLinks) => _samePath(name, packet.path)
            ? FileSystemEntityType.notFound
            : nativeZone.run(
                () => FileSystemEntity.typeSync(name, followLinks: followLinks),
              ),
      );
      expect(deletionAttempted, isTrue);
      expect(packet.existsSync(), isTrue);
    },
  );

  test(
    'legacy symbolic links are removed without deleting their target',
    () async {
      final target = await Directory('${root.path}/outside').create();
      final saved = await File('${target.path}/saved').writeAsBytes([9]);
      final nested = await Directory('${cache.path}/legacy').create();
      final link = Link('${nested.path}/linked');
      if (Platform.isWindows) {
        // A temporary-directory junction requires no developer mode/admin.
        final result = await Process.run(
          'powershell.exe',
          [
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '\$ErrorActionPreference = "Stop"\n'
                'New-Item -ItemType Junction -Path \$env:FOCUBILI_TEST_LINK '
                '-Target \$env:FOCUBILI_TEST_TARGET | Out-Null',
          ],
          environment: {
            'FOCUBILI_TEST_LINK': link.path,
            'FOCUBILI_TEST_TARGET': target.path,
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      } else {
        await link.create(target.path);
      }
      expect(
        FileSystemEntity.typeSync(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      await service((_, _) {}).maintain();
      expect(await saved.readAsBytes(), [9]);
      expect(await link.exists(), isFalse);
      expect(nested.existsSync(), isFalse);
    },
  );

  test(
    'nested legacy child disappears without skipping remaining files',
    () async {
      final directory = await Directory(
        '${cache.path}/legacy/nested',
      ).create(recursive: true);
      final packet = await File('${directory.path}/packet').writeAsBytes([1]);
      final other = await File('${directory.path}/other').writeAsBytes([2]);
      var raced = false;
      await service((entity, recursive) {
        if (raced) return;
        if (recursive || _samePath(entity.path, packet.path)) {
          raced = true;
          packet.deleteSync();
          expect(directory.existsSync(), isTrue);
          if (recursive) {
            throw PathNotFoundException(
              entity.path,
              const OSError('No such file or directory', 2),
              'Deletion failed',
            );
          }
        }
      }).maintain();
      expect(raced, isTrue);
      expect(other.existsSync(), isFalse);
      expect(Directory('${cache.path}/legacy').existsSync(), isFalse);
    },
  );
}
