import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 区分 Android 持久边播缓存和 Windows media_kit 临时播放缓冲，供页面展示准确说明。
enum MediaCacheStorageKind { androidPersistent, windowsPlaybackBuffer }

/// 保存当前平台视频缓存或播放缓冲的可展示状态。
class MediaCacheStatus {
  /// 创建一个包含当前占用、容量上限和播放器占用状态的缓存快照。
  const MediaCacheStatus({
    required this.usedBytes,
    required this.capacityBytes,
    required this.isPlaybackActive,
    this.storageKind = MediaCacheStorageKind.androidPersistent,
  });

  final int usedBytes;
  final int capacityBytes;
  final bool isPlaybackActive;
  final MediaCacheStorageKind storageKind;

  /// 把 Android 方法通道返回的字典转换为经过边界保护的 Dart 数据。
  factory MediaCacheStatus.fromPlatformMap(Map<Object?, Object?> values) {
    final int usedBytes = (values['usedBytes'] as num?)?.toInt() ?? 0;
    final int capacityBytes =
        (values['capacityBytes'] as num?)?.toInt() ?? defaultMediaCacheBytes;
    return MediaCacheStatus(
      usedBytes: usedBytes < 0 ? 0 : usedBytes,
      capacityBytes: supportedMediaCacheBytes.contains(capacityBytes)
          ? capacityBytes
          : defaultMediaCacheBytes,
      isPlaybackActive: values['isPlaybackActive'] == true,
      storageKind: MediaCacheStorageKind.androidPersistent,
    );
  }
}

/// 表示缓存管理过程中可向用户展示的原生错误。
class MediaCacheException implements Exception {
  /// 创建保留原生错误码和提示文本的缓存管理异常。
  const MediaCacheException(this.code, this.message);

  final String code;
  final String message;

  /// 让调试日志显示稳定、可读的错误说明。
  @override
  String toString() => 'MediaCacheException($code, $message)';
}

/// 所有页面可选择的边播边缓存容量，单位为字节。
const List<int> supportedMediaCacheBytes = <int>[
  128 * 1024 * 1024,
  256 * 1024 * 1024,
  512 * 1024 * 1024,
  1024 * 1024 * 1024,
  2 * 1024 * 1024 * 1024,
];

/// 新安装 App 使用的默认缓存上限：512MB。
const int defaultMediaCacheBytes = 512 * 1024 * 1024;

/// 约束 Flutter 缓存管理页需要的原生能力，便于页面测试使用假实现。
abstract interface class MediaCacheService {
  /// 读取当前缓存用量、容量上限和播放器是否正在占用缓存。
  Future<MediaCacheStatus> loadStatus();

  /// 保存新的缓存上限，并返回应用 LRU 策略后的最新状态。
  Future<MediaCacheStatus> setCapacityBytes(int capacityBytes);

  /// 删除所有可清理的边播边缓存，并返回清理后的最新状态。
  Future<MediaCacheStatus> clearCache();
}

/// 根据当前操作系统创建缓存实现，Windows 不会再调用 Android Media3 方法通道。
MediaCacheService createMediaCacheService() {
  return Platform.isWindows
      ? WindowsMediaCacheService()
      : NativeMediaCacheService();
}

/// 记录当前进程中仍存活的 Windows 播放器，防止清理正在被 libmpv 使用的缓冲文件。
abstract final class WindowsMediaCacheRuntime {
  static int _activePlaybackSessions = 0;

  /// 在 Windows 播放服务创建后登记一个活跃会话。
  static void registerPlaybackSession() {
    _activePlaybackSessions += 1;
  }

  /// 在 Windows 播放服务释放后注销会话，并防止异常重复释放产生负数。
  static void unregisterPlaybackSession() {
    if (_activePlaybackSessions > 0) {
      _activePlaybackSessions -= 1;
    }
  }

  /// 返回当前是否仍有播放器可能占用 media_kit 缓冲目录。
  static bool get isPlaybackActive => _activePlaybackSessions > 0;
}

/// 定义 Windows 缓冲目录读取函数，单元测试可注入独立临时目录。
typedef WindowsMediaCacheDirectoryLoader = Future<Directory> Function();

/// 在应用专属缓存目录中统计和清理 media_kit 的磁盘播放缓冲。
class WindowsMediaCacheService implements MediaCacheService {
  /// 创建 Windows 缓冲服务；测试可替换目录、偏好设置和播放器占用状态。
  WindowsMediaCacheService({
    WindowsMediaCacheDirectoryLoader? directoryLoader,
    Future<SharedPreferences> Function()? preferencesLoader,
    bool Function()? playbackActiveLoader,
  }) : _directoryLoader = directoryLoader ?? _loadDefaultCacheDirectory,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _playbackActiveLoader =
           playbackActiveLoader ??
           (() => WindowsMediaCacheRuntime.isPlaybackActive);

  static const String cacheDirectoryName = 'media_kit_video_cache';
  static const String _capacityPreferenceKey =
      'windows_media_cache_capacity_bytes';

  final WindowsMediaCacheDirectoryLoader _directoryLoader;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final bool Function() _playbackActiveLoader;

  /// 读取应用专属缓冲目录的实际文件大小、容量设置和当前占用状态。
  @override
  Future<MediaCacheStatus> loadStatus() async {
    final Directory directory = await resolveCacheDirectory();
    final int capacityBytes = await loadCapacityBytes();
    final int usedBytes = await _calculateDirectorySize(directory);
    return MediaCacheStatus(
      usedBytes: usedBytes,
      capacityBytes: capacityBytes,
      isPlaybackActive: _playbackActiveLoader(),
      storageKind: MediaCacheStorageKind.windowsPlaybackBuffer,
    );
  }

  /// 保存受支持的新容量，并在播放器未占用目录时按最后修改时间清理超出容量的旧文件。
  @override
  Future<MediaCacheStatus> setCapacityBytes(int capacityBytes) async {
    if (!supportedMediaCacheBytes.contains(capacityBytes)) {
      throw const MediaCacheException(
        'invalid_cache_capacity',
        '请选择支持的视频缓存上限。',
      );
    }
    _ensurePlaybackIdle();
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.setInt(_capacityPreferenceKey, capacityBytes);
      final Directory directory = await resolveCacheDirectory();
      await _trimToCapacity(directory, capacityBytes);
      return loadStatus();
    } on MediaCacheException {
      rethrow;
    } catch (_) {
      throw const MediaCacheException(
        'cache_error',
        'Windows 视频缓冲上限暂时无法保存，请稍后重试。',
      );
    }
  }

  /// 删除应用专属 media_kit 缓冲目录内的内容，不触碰账号、笔记、截图或其他用户文件。
  @override
  Future<MediaCacheStatus> clearCache() async {
    _ensurePlaybackIdle();
    try {
      final Directory directory = await resolveCacheDirectory();
      await for (final FileSystemEntity entity in directory.list(
        followLinks: false,
      )) {
        await entity.delete(recursive: true);
      }
      return loadStatus();
    } on MediaCacheException {
      rethrow;
    } catch (_) {
      throw const MediaCacheException(
        'cache_error',
        'Windows 视频缓冲暂时无法清空，请稍后重试。',
      );
    }
  }

  /// 读取已保存容量，缺失或损坏时使用 512MB 安全默认值。
  Future<int> loadCapacityBytes() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final int? value = preferences.getInt(_capacityPreferenceKey);
      return supportedMediaCacheBytes.contains(value)
          ? value!
          : defaultMediaCacheBytes;
    } catch (_) {
      return defaultMediaCacheBytes;
    }
  }

  /// 解析并创建唯一允许管理的应用缓冲目录，同时拒绝文件系统根目录等宽泛目标。
  Future<Directory> resolveCacheDirectory() async {
    final Directory directory = (await _directoryLoader()).absolute;
    final String normalizedPath = directory.path.replaceAll('\\', '/');
    final List<String> segments = normalizedPath
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty ||
        segments.last.toLowerCase() != cacheDirectoryName.toLowerCase() ||
        directory.parent.path == directory.path) {
      throw const MediaCacheException(
        'unsafe_cache_path',
        'Windows 视频缓冲目录不安全，已停止操作。',
      );
    }
    await directory.create(recursive: true);
    return directory;
  }

  /// 在有播放器会话存活时阻止容量调整或清理，避免 libmpv 读取到一半的文件被删除。
  void _ensurePlaybackIdle() {
    if (_playbackActiveLoader()) {
      throw const MediaCacheException('cache_busy', '视频播放中，停止播放并退出播放页后才能管理缓存。');
    }
  }

  /// 递归统计目录中的普通文件，符号链接不会被跟随到应用目录之外。
  Future<int> _calculateDirectorySize(Directory directory) async {
    int total = 0;
    try {
      await for (final FileSystemEntity entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      throw const MediaCacheException('cache_error', 'Windows 视频缓冲用量暂时无法读取。');
    }
  }

  /// 按最后修改时间从旧到新删除超出新上限的缓冲文件，容量内文件保持不变。
  Future<void> _trimToCapacity(Directory directory, int capacityBytes) async {
    final List<File> files = <File>[];
    await for (final FileSystemEntity entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        files.add(entity);
      }
    }
    final List<({File file, int size, DateTime modified})> entries =
        <({File file, int size, DateTime modified})>[];
    int total = 0;
    for (final File file in files) {
      final FileStat stat = await file.stat();
      total += stat.size;
      entries.add((file: file, size: stat.size, modified: stat.modified));
    }
    entries.sort(
      (
        ({File file, DateTime modified, int size}) left,
        ({File file, DateTime modified, int size}) right,
      ) => left.modified.compareTo(right.modified),
    );
    for (final ({File file, int size, DateTime modified}) entry in entries) {
      if (total <= capacityBytes) {
        break;
      }
      await entry.file.delete();
      total -= entry.size;
    }
  }

  /// 在 path_provider 返回的应用缓存目录下追加固定子目录，确保卸载和系统清理边界明确。
  static Future<Directory> _loadDefaultCacheDirectory() async {
    final Directory applicationCache = await getApplicationCacheDirectory();
    return Directory(
      '${applicationCache.path}${Platform.pathSeparator}$cacheDirectoryName',
    );
  }
}

/// 通过既有原生播放通道管理 Media3 的边播边缓存。
class NativeMediaCacheService implements MediaCacheService {
  /// 创建使用 Android 原生播放器通道的缓存管理服务。
  NativeMediaCacheService({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.focubili.app/playback',
  );

  final MethodChannel _channel;

  /// 从 Android 读取当前缓存状态；非 Android 测试环境会返回明确错误而不是伪造数据。
  @override
  Future<MediaCacheStatus> loadStatus() async {
    return _readStatus('getMediaCacheStatus');
  }

  /// 校验容量档位后请求 Android 持久化新上限并重建空闲缓存策略。
  @override
  Future<MediaCacheStatus> setCapacityBytes(int capacityBytes) async {
    if (!supportedMediaCacheBytes.contains(capacityBytes)) {
      throw const MediaCacheException(
        'invalid_cache_capacity',
        '请选择支持的视频缓存上限。',
      );
    }
    return _readStatus('setMediaCacheCapacity', <String, Object?>{
      'capacityBytes': capacityBytes,
    });
  }

  /// 请求 Android 删除全部边播边缓存，播放中时由原生层返回 cache_busy。
  @override
  Future<MediaCacheStatus> clearCache() async {
    return _readStatus('clearMediaCache');
  }

  /// 调用返回缓存状态的原生方法，并把平台异常转换为页面可处理的异常类型。
  Future<MediaCacheStatus> _readStatus(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        method,
        arguments,
      );
      if (result is! Map) {
        throw const MediaCacheException('cache_error', '视频缓存返回了无效数据。');
      }
      return MediaCacheStatus.fromPlatformMap(
        Map<Object?, Object?>.from(result),
      );
    } on PlatformException catch (error) {
      throw MediaCacheException(
        error.code,
        error.message ?? '视频缓存暂时无法操作，请稍后重试。',
      );
    } on MissingPluginException {
      throw const MediaCacheException('cache_unavailable', '当前设备暂不支持视频缓存管理。');
    }
  }
}
