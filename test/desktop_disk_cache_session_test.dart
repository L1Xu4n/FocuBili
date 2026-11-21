import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/desktop_disk_cache_session.dart';
import 'package:focubili/services/media_cache_service.dart';

class TestDiskStorage extends WindowsMediaCacheService {
  TestDiskStorage(Directory directory)
    : super(
        directoryLoader: () async => directory,
        playbackActiveLoader: () => false,
      );
  bool failRead = false;
  @override
  Future<int> loadCapacityBytes() async => 128;
  @override
  Future<int> diskBytes() {
    if (failRead) throw const FileSystemException('Synthetic read failure');
    return super.diskBytes();
  }
}

void main() {
  late Directory root;
  late TestDiskStorage storage;
  late DesktopDiskCacheSession session;
  late Map<String, String> properties;
  late Set<String> rejectedProperties;
  Completer<void>? blockWrite;
  Completer<void>? enteredWrite;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili_disk_session_');
    storage = TestDiskStorage(
      Directory('${root.path}/${WindowsMediaCacheService.cacheDirectoryName}'),
    );
    properties = {};
    rejectedProperties = {};
    blockWrite = null;
    enteredWrite = null;
    session = DesktopDiskCacheSession(
      storage: storage,
      pollInterval: const Duration(days: 1),
      writeProperty: (name, value) async {
        if (blockWrite != null) {
          enteredWrite?.complete();
          await blockWrite!.future;
          blockWrite = null;
        }
        if (!rejectedProperties.contains(name)) properties[name] = value;
      },
      readProperty: (name) async => properties[name] ?? '',
    );
  });
  tearDown(() async {
    await session.releaseAfterPlayerClosed();
    WindowsMediaCacheRuntime.diskMessages.clear();
    await root.delete(recursive: true);
  });

  test(
    'uses visible disk packet files and preserves both metadata budgets',
    () async {
      await session.configure();
      expect(properties['cache-on-disk'], 'yes');
      expect(properties['demuxer-cache-dir'], session.directoryPath);
      expect(properties['demuxer-cache-unlink-files'], 'whendone');
      expect(properties['demuxer-max-bytes'], '128');
      expect(properties['demuxer-max-back-bytes'], '128');
      expect(WindowsMediaCacheRuntime.bufferMessage, isNull);
      expect(session.configurationError, isNull);
    },
  );

  test(
    'classroom suppresses disk writes even after sampler sees an empty session',
    () async {
      await session.configure();
      await session.setDiskAllowed(false);
      expect(properties['cache-on-disk'], 'no');
      await session.sample();
      expect(properties['cache-on-disk'], 'no');
      await session.setDiskAllowed(true);
      await session.sample();
      expect(properties['cache-on-disk'], 'yes');
    },
  );

  test(
    'mpv 0.36 legacy names preserve disk mode with verified directory and unlink policy',
    () async {
      rejectedProperties = {'demuxer-cache-dir'};
      await session.configure();
      expect(properties['cache-dir'], session.directoryPath);
      expect(properties['cache-unlink-files'], 'whendone');
      expect(properties['cache-on-disk'], 'yes');
      expect(session.configurationError, isNull);
    },
  );

  test(
    'soft threshold retains active bytes, disables writes and recovers next media',
    () async {
      await session.configure();
      final packet = await File(
        '${session.directoryPath}/mpv-packet',
      ).writeAsBytes(List.filled(160, 1));
      await session.sample();
      expect(session.writesSuspended, isTrue);
      expect(
        await storage.diskBytes(),
        160,
      ); // Overshoot is explicit, never truncated.
      expect(await packet.exists(), isTrue);
      expect(properties['cache-on-disk'], 'no');
      expect(
        properties['demuxer-max-back-bytes'],
        desktopFallbackMemoryBytes.toString(),
      );
      await storage.maintain();
      expect(await packet.exists(), isTrue);
      await expectLater(
        storage.clearCache(),
        throwsA(isA<MediaCacheException>()),
      );
      await packet.writeAsBytes([1]);
      await session.sample();
      expect(
        properties['cache-on-disk'],
        'no',
        reason: 'Do not append to an existing suspended file',
      );
      await packet.delete(); // Simulate mpv closing the old media.
      await session.sample();
      expect(properties['cache-on-disk'], 'yes');
      await File('${session.directoryPath}/next-media').writeAsBytes([2]);
      await session.stopMonitoring();
      await storage.maintain();
      expect(await Directory(session.directoryPath!).exists(), isTrue);
      await session.releaseAfterPlayerClosed();
      expect(await Directory(session.directoryPath!).exists(), isFalse);
    },
  );

  test('aggregates live sessions without evicting a peer', () async {
    final peer = await storage.openSession();
    try {
      final packet = await File(
        '${peer.directory.path}/peer-packet',
      ).writeAsBytes(List.filled(150, 2));
      await session.configure();
      expect(properties['cache-on-disk'], 'no');
      expect(session.writesSuspended, isTrue);
      await session.sample();
      expect(await packet.exists(), isTrue);
      expect(await storage.diskBytes(), 150);
    } finally {
      await peer.close();
    }
    await session.sample();
    expect(properties['cache-on-disk'], 'yes');
  });

  test('mpv write rejection is detected by readback and retried', () async {
    await session.configure();
    await File(
      '${session.directoryPath}/packet',
    ).writeAsBytes(List.filled(150, 1));
    rejectedProperties = {'cache-on-disk'};
    await session.sample();
    expect(session.writesSuspended, isFalse);
    expect(WindowsMediaCacheRuntime.bufferMessage, contains('未能暂停'));
    rejectedProperties = {};
    await session.sample();
    expect(session.writesSuspended, isTrue);
    expect(properties['cache-on-disk'], 'no');
  });

  test(
    'accounting failure stops new disk writes without deleting active data',
    () async {
      await session.configure();
      final packet = await File(
        '${session.directoryPath}/packet',
      ).writeAsBytes([1]);
      storage.failRead = true;
      await session.sample();
      expect(session.writesSuspended, isTrue);
      expect(properties['cache-on-disk'], 'no');
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('无法读取'));
      expect(await packet.readAsBytes(), [1]);
    },
  );

  test(
    'unsupported required option falls back with an explicit diagnostic',
    () async {
      rejectedProperties = {'demuxer-cache-unlink-files', 'cache-unlink-files'};
      await session.configure();
      expect(properties['cache-on-disk'], 'no');
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('未能启用'));
      expect(
        session.configurationError.toString(),
        contains('cache-unlink-files'),
      );
    },
  );

  test(
    'failed fallback does not claim that the threshold is enforced',
    () async {
      rejectedProperties = {'cache-on-disk'};
      await session.configure();
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('无法确认'));
    },
  );

  test(
    'disposal waits for in-flight configuration and retains lease until media closes',
    () async {
      blockWrite = Completer<void>();
      enteredWrite = Completer<void>();
      final configuring = session.configure();
      await enteredWrite!.future;
      var stopped = false;
      final stopping = session.stopMonitoring().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      blockWrite!.complete();
      await configuring;
      await stopping;
      await storage.maintain();
      expect(await Directory(session.directoryPath!).exists(), isTrue);
      final before = Map.of(properties);
      await session.sample();
      expect(properties, before);
      await session.releaseAfterPlayerClosed();
      expect(await Directory(session.directoryPath!).exists(), isFalse);
    },
  );
}
