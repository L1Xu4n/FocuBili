import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/media_cache_service.dart';

/// 验证 Windows media_kit 缓冲只在应用专属目录内统计、限额和清理。
void main() {
  late Directory testRoot;
  late Directory cacheDirectory;

  /// 每项测试创建独立临时根目录和固定名称的受管缓冲子目录。
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    testRoot = await Directory.systemTemp.createTemp(
      'focubili_windows_cache_test_',
    );
    cacheDirectory = Directory(
      '${testRoot.path}${Platform.pathSeparator}'
      '${WindowsMediaCacheService.cacheDirectoryName}',
    );
  });

  /// 测试结束后只删除本用例创建的临时根目录，不触碰真实应用缓存。
  tearDown(() async {
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  /// 创建使用当前测试目录与内存偏好设置的 Windows 缓冲服务。
  WindowsMediaCacheService createService({bool playbackActive = false}) {
    return WindowsMediaCacheService(
      directoryLoader: () async => cacheDirectory,
      preferencesLoader: SharedPreferences.getInstance,
      playbackActiveLoader: () => playbackActive,
    );
  }

  test(
    'maintenance preserves active playback and explicit offline downloads',
    () async {
      await cacheDirectory.create(recursive: true);
      final old = await File(
        '${cacheDirectory.path}/old.cache',
      ).writeAsBytes([1, 2, 3]);
      final offline = await File(
        '${testRoot.path}/offline_video.mp4',
      ).writeAsBytes([9]);
      var active = true;
      final service = WindowsMediaCacheService(
        directoryLoader: () async => cacheDirectory,
        playbackActiveLoader: () => active,
      );
      await service.maintain();
      expect(await old.exists(), isTrue);
      active = false;
      await service.maintain();
      expect(await old.exists(), isFalse);
      expect(await offline.readAsBytes(), [9]);
      expect((await service.loadStatus()).usedBytes, 0);
    },
  );
  test('playback starting while directory loads blocks deletion', () async {
    await cacheDirectory.create(recursive: true);
    final old = await File(
      '${cacheDirectory.path}/old.cache',
    ).writeAsBytes([1]);
    final ready = Completer<Directory>();
    var active = false;
    final service = WindowsMediaCacheService(
      directoryLoader: () => ready.future,
      playbackActiveLoader: () => active,
    );
    final clear = service.clearCache();
    final rejected = expectLater(clear, throwsA(isA<MediaCacheException>()));
    await Future<void>.delayed(Duration.zero);
    active = true;
    ready.complete(cacheDirectory);
    await rejected;
    expect(await old.exists(), isTrue);
  });
  test(
    'linked cache root is rejected without touching its target',
    () async {
      final target = await Directory(
        '${testRoot.path}/user_downloads',
      ).create();
      final file = await File('${target.path}/saved.mp4').writeAsBytes([7]);
      await Link(cacheDirectory.path).create(target.path);
      await expectLater(
        createService().clearCache(),
        throwsA(isA<MediaCacheException>()),
      );
      expect(await file.readAsBytes(), [7]);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows developer mode'
        : false,
  );

  /// 验证服务统计真实文件大小、保存受支持容量并只清空受管目录内容。
  test('统计容量设置和清空 Windows 播放缓冲', () async {
    final WindowsMediaCacheService service = createService();
    await cacheDirectory.create(recursive: true);
    await File(
      '${cacheDirectory.path}${Platform.pathSeparator}video.cache',
    ).writeAsBytes(<int>[1, 2, 3, 4]);
    final Directory nested = Directory(
      '${cacheDirectory.path}${Platform.pathSeparator}nested',
    );
    await nested.create();
    await File(
      '${nested.path}${Platform.pathSeparator}audio.cache',
    ).writeAsBytes(<int>[5, 6, 7]);

    final MediaCacheStatus initial = await service.loadStatus();
    expect(initial.usedBytes, 7);
    expect(initial.capacityBytes, defaultMemoryBufferBytes);
    expect(initial.storageKind, MediaCacheStorageKind.windowsPlaybackBuffer);

    final MediaCacheStatus resized = await service.setCapacityBytes(
      supportedMemoryBufferBytes.first,
    );
    expect(resized.capacityBytes, supportedMemoryBufferBytes.first);
    expect(resized.usedBytes, 0);

    final MediaCacheStatus cleared = await service.clearCache();
    expect(cleared.usedBytes, 0);
    expect(await cacheDirectory.exists(), isTrue);
    expect(await testRoot.exists(), isTrue);
  });

  /// 验证播放器仍持有缓冲目录时，服务拒绝容量修改和文件删除。
  test('播放中拒绝修改或清空 Windows 缓冲', () async {
    final WindowsMediaCacheService service = createService(
      playbackActive: true,
    );

    await expectLater(
      service.setCapacityBytes(supportedMemoryBufferBytes.first),
      throwsA(
        isA<MediaCacheException>().having(
          (MediaCacheException error) => error.code,
          'code',
          'cache_busy',
        ),
      ),
    );
    await expectLater(
      service.clearCache(),
      throwsA(
        isA<MediaCacheException>().having(
          (MediaCacheException error) => error.code,
          'code',
          'cache_busy',
        ),
      ),
    );
  });

  /// 验证目录名称不符合固定边界时拒绝执行，避免误清理宽泛路径。
  test('拒绝不属于应用的 Windows 缓冲目录', () async {
    final WindowsMediaCacheService service = WindowsMediaCacheService(
      directoryLoader: () async => testRoot,
      preferencesLoader: SharedPreferences.getInstance,
      playbackActiveLoader: () => false,
    );

    await expectLater(
      service.clearCache(),
      throwsA(
        isA<MediaCacheException>().having(
          (MediaCacheException error) => error.code,
          'code',
          'unsafe_cache_path',
        ),
      ),
    );
    expect(await testRoot.exists(), isTrue);
  });
}
