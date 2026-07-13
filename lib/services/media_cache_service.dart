import 'package:flutter/services.dart';

/// 保存 Android 原生边播边缓存的可展示状态。
class MediaCacheStatus {
  /// 创建一个包含当前占用、容量上限和播放器占用状态的缓存快照。
  const MediaCacheStatus({
    required this.usedBytes,
    required this.capacityBytes,
    required this.isPlaybackActive,
  });

  final int usedBytes;
  final int capacityBytes;
  final bool isPlaybackActive;

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
    return _readStatus(
      'setMediaCacheCapacity',
      <String, Object?>{'capacityBytes': capacityBytes},
    );
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
      throw const MediaCacheException(
        'cache_unavailable',
        '当前设备暂不支持视频缓存管理。',
      );
    }
  }
}
