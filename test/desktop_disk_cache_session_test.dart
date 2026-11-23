import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/desktop_disk_cache_session.dart';
import 'package:focubili/services/media_cache_service.dart';
import 'package:media_kit/media_kit.dart';

import '../tool/desktop_disk_cache_probe.dart';

class TestDiskStorage extends WindowsMediaCacheService {
  /// Uses test-owned storage with a deliberately small threshold.
  TestDiskStorage(Directory directory)
    : super(
        directoryLoader: () async => directory,
        playbackActiveLoader: () => false,
      );
  bool failRead = false;
  @override
  /// Keeps the threshold small enough to cross with a short fixture.
  Future<int> loadCapacityBytes() async => 128;
  @override
  /// Can simulate a disk accounting failure without touching outside files.
  Future<int> diskBytes() {
    if (failRead) throw const FileSystemException('Synthetic read failure');
    return super.diskBytes();
  }
}

/// Exercises the cache policy through its property and filesystem interfaces.
void main() {
  final libmpv = Platform.environment['FOCUBILI_DESKTOP_CACHE_PROBE_LIBMPV'];
  if (libmpv != null) {
    test('native loopback pauses both media transfers before EOF', () async {
      MediaKit.ensureInitialized(libmpv: libmpv);
      await verifyPausedReadAheadPlateau();
    });
  }
  late Directory root;
  late TestDiskStorage storage;
  late DesktopDiskCacheSession session;
  late Map<String, String> properties;
  late Set<String> rejectedProperties;
  late Map<String, String> forcedReadback;
  Completer<void>? blockWrite;
  Completer<void>? enteredWrite;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili_disk_session_');
    storage = TestDiskStorage(
      Directory('${root.path}/${WindowsMediaCacheService.cacheDirectoryName}'),
    );
    properties = {};
    rejectedProperties = {};
    forcedReadback = {};
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
      readProperty: (name) async {
        if (forcedReadback.containsKey(name)) return forcedReadback[name]!;
        final value = properties[name] ?? '';
        return name.endsWith('-secs') && value.isNotEmpty
            ? double.parse(value).toStringAsFixed(6)
            : value;
      },
    );
  });

  /// Creates a lease and opts into the unmetered media policy.
  Future<void> configureForPlayback() async {
    await session.configure();
    await session.applyPlaybackPolicy(
      diskAllowed: true,
      preferDataSaving: false,
    );
  }

  /// Checks time and byte limits together so a partial policy fails the test.
  void expectBudgets(int seconds, int forwardBytes, int backBytes) {
    expect(double.parse(properties['cache-secs']!), seconds);
    expect(double.parse(properties['demuxer-readahead-secs']!), seconds);
    expect(properties['demuxer-max-bytes'], '$forwardBytes');
    expect(properties['demuxer-max-back-bytes'], '$backBytes');
  }

  tearDown(() async {
    await session.releaseAfterPlayerClosed();
    WindowsMediaCacheRuntime.diskMessages.clear();
    await root.delete(recursive: true);
  });

  test(
    'uses visible disk packet files and preserves both metadata budgets',
    () async {
      await session.configure();
      final lease = session.directoryPath;
      expect(properties['cache-on-disk'], 'no');
      await configureForPlayback();
      expect(session.directoryPath, lease);
      expect(properties['cache-on-disk'], 'yes');
      expect(properties['demuxer-cache-dir'], session.directoryPath);
      expect(properties['demuxer-cache-unlink-files'], 'whendone');
      expectBudgets(30, 128, 128);
      expect(WindowsMediaCacheRuntime.bufferMessage, isNull);
      expect(session.configurationError, isNull);
    },
  );

  test(
    'classroom suppresses disk writes even after sampler sees an empty session',
    () async {
      await configureForPlayback();
      const mib = 1024 * 1024;
      await session.applyPlaybackPolicy(
        diskAllowed: false,
        preferDataSaving: false,
      );
      expect(properties['cache-on-disk'], 'no');
      expectBudgets(30, 32 * mib, 64 * mib);
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('课堂'));
      await session.sample();
      expect(properties['cache-on-disk'], 'no');
      await session.applyPlaybackPolicy(
        diskAllowed: false,
        preferDataSaving: true,
      );
      expectBudgets(15, 16 * mib, 16 * mib);
      await session.sample();
      expect(properties['cache-on-disk'], 'no');
      await session.applyPlaybackPolicy(
        diskAllowed: true,
        preferDataSaving: true,
      );
      expectBudgets(15, 16 * mib, 16 * mib);
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('计量网络'));
      await session.sample();
      expect(properties['cache-on-disk'], 'no');
      await session.applyPlaybackPolicy(
        diskAllowed: true,
        preferDataSaving: false,
      );
      await session.sample();
      expect(properties['cache-on-disk'], 'yes');
      expectBudgets(30, 128, 128);
    },
  );

  test(
    'mpv 0.36 legacy names preserve disk mode with verified directory and unlink policy',
    () async {
      rejectedProperties = {'demuxer-cache-dir'};
      await configureForPlayback();
      expect(properties['cache-dir'], session.directoryPath);
      expect(properties['cache-unlink-files'], 'whendone');
      expect(properties['cache-on-disk'], 'yes');
      expect(session.configurationError, isNull);
    },
  );

  test(
    'soft threshold retains active bytes, disables writes and recovers next media',
    () async {
      await configureForPlayback();
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
      expectBudgets(30, 32 * 1024 * 1024, desktopFallbackMemoryBytes);
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
      await configureForPlayback();
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
    await configureForPlayback();
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
      await configureForPlayback();
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
      await configureForPlayback();
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
      await configureForPlayback();
      expect(WindowsMediaCacheRuntime.bufferMessage, contains('无法确认'));
    },
  );

  test(
    'rejects invalid, nonfinite and out of tolerance time readback',
    () async {
      await session.configure();
      for (final readback in ['bad', 'NaN', 'Infinity', '30.01']) {
        forcedReadback['cache-secs'] = readback;
        await session.applyPlaybackPolicy(
          diskAllowed: true,
          preferDataSaving: false,
        );
        expect(session.configurationError, isA<StateError>());
        expect(session.configurationError.toString(), contains('cache-secs'));
        expect(WindowsMediaCacheRuntime.bufferMessage, contains('无法确认'));
        expect(properties['cache-on-disk'], 'no');
      }
      forcedReadback.clear();
      await session.applyPlaybackPolicy(
        diskAllowed: true,
        preferDataSaving: false,
      );
      expect(session.configurationError, isNull);
      expectBudgets(30, 128, 128);
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
