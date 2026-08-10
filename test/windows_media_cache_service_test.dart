import 'dart:io';

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
    expect(initial.capacityBytes, defaultMediaCacheBytes);
    expect(initial.storageKind, MediaCacheStorageKind.windowsPlaybackBuffer);

    final MediaCacheStatus resized = await service.setCapacityBytes(
      supportedMediaCacheBytes.first,
    );
    expect(resized.capacityBytes, supportedMediaCacheBytes.first);
    expect(resized.usedBytes, 7);

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
      service.setCapacityBytes(supportedMediaCacheBytes.first),
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
