import 'dart:async';

import 'package:flutter/services.dart';

import '../models/video_preview.dart';

/// 表示 Android 原生播放器当前所处的阶段，供页面决定显示加载、播放或错误提示。
enum PlaybackPhase { idle, loading, ready, ended, error }

/// 表示原生播放接口返回的一档清晰度编号和用户可读名称。
class PlaybackQuality {
  /// 创建一档稳定的清晰度选项。
  const PlaybackQuality({required this.id, required this.label});

  final int id;
  final String label;

  /// 从 Android 传回的字典读取清晰度，并在名称缺失时使用编号兜底。
  factory PlaybackQuality.fromPlatformMap(Map<Object?, Object?> values) {
    final int id = (values['id'] as num?)?.toInt() ?? 0;
    final String label = values['label'] as String? ?? '';
    return PlaybackQuality(
      id: id,
      label: label.trim().isEmpty ? '$id' : label.trim(),
    );
  }
}

/// 保存一支视频最后观看的分P和该分P可恢复的播放位置。
class SavedPlaybackState {
  /// 创建一条稳定的本地播放记忆。
  const SavedPlaybackState({
    required this.cid,
    required this.pageNumber,
    required this.position,
  });

  final int cid;
  final int pageNumber;
  final Duration position;

  /// 从 Android 本地存储结果读取分P和进度，非法编号会返回空值。
  factory SavedPlaybackState.fromPlatformMap(Map<Object?, Object?> values) {
    return SavedPlaybackState(
      cid: (values['cid'] as num?)?.toInt() ?? 0,
      pageNumber: (values['pageNumber'] as num?)?.toInt() ?? 0,
      position: Duration(
        milliseconds: (values['positionMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// 保存竖向手势开始时的屏幕亮度和媒体音量比例。
class SystemPlaybackLevels {
  /// 创建限制在 0 到 1 范围内的亮度和音量状态。
  const SystemPlaybackLevels({required this.brightness, required this.volume});

  final double brightness;
  final double volume;

  /// 从 Android 返回值读取亮度和音量，并限制异常数值。
  factory SystemPlaybackLevels.fromPlatformMap(Map<Object?, Object?> values) {
    return SystemPlaybackLevels(
      brightness: ((values['brightness'] as num?)?.toDouble() ?? 0.5)
          .clamp(0.01, 1)
          .toDouble(),
      volume: ((values['volume'] as num?)?.toDouble() ?? 0.5)
          .clamp(0, 1)
          .toDouble(),
    );
  }
}

/// 保存一次从 Android 原生播放器传回来的最小播放状态。
class PlaybackSnapshot {
  /// 创建一个可安全用于页面初始渲染的播放状态。
  const PlaybackSnapshot({
    this.phase = PlaybackPhase.idle,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1,
    this.currentQuality = 64,
    this.availableQualities = const <PlaybackQuality>[],
    this.videoAspectRatio = 16 / 9,
    this.restoredPosition = Duration.zero,
    this.isInPictureInPicture = false,
    this.message,
  });

  final PlaybackPhase phase;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double speed;
  final int currentQuality;
  final List<PlaybackQuality> availableQualities;
  final double videoAspectRatio;
  final Duration restoredPosition;
  final bool isInPictureInPicture;
  final String? message;

  /// 根据方法通道传回的字典创建播放状态，避免平台数据直接进入页面。
  factory PlaybackSnapshot.fromPlatformMap(Map<Object?, Object?> values) {
    final String phaseName = values['phase'] as String? ?? 'idle';
    final Object? rawQualities = values['qualities'];
    final List<PlaybackQuality> qualities = rawQualities is List
        ? rawQualities
            .whereType<Map>()
            .map(
              // 清晰度转换函数把平台 Map 隔离为稳定的 Dart 类型。
              (Map<Object?, Object?> item) => PlaybackQuality.fromPlatformMap(
                Map<Object?, Object?>.from(item),
              ),
            )
            .where((PlaybackQuality quality) => quality.id > 0)
            .toList(growable: false)
        : const <PlaybackQuality>[];
    return PlaybackSnapshot(
      phase: PlaybackPhase.values.firstWhere(
        (PlaybackPhase phase) => phase.name == phaseName,
        // 未知阶段名时回退到空闲状态，兼容未来 Android 端的新增状态。
        orElse: () => PlaybackPhase.idle,
      ),
      isPlaying: values['isPlaying'] as bool? ?? false,
      position: Duration(
        milliseconds: (values['positionMs'] as num?)?.toInt() ?? 0,
      ),
      duration: Duration(
        milliseconds: (values['durationMs'] as num?)?.toInt() ?? 0,
      ),
      speed: (values['speed'] as num?)?.toDouble() ?? 1,
      currentQuality: (values['quality'] as num?)?.toInt() ?? 64,
      availableQualities: qualities,
      videoAspectRatio: (values['aspectRatio'] as num?)?.toDouble() ?? 16 / 9,
      restoredPosition: Duration(
        milliseconds: (values['restoredPositionMs'] as num?)?.toInt() ?? 0,
      ),
      isInPictureInPicture: values['isInPictureInPicture'] == true,
      message: values['message'] as String?,
    );
  }

  /// 基于原状态替换指定字段，便于页面在拖动进度条时暂存显示进度。
  PlaybackSnapshot copyWith({
    PlaybackPhase? phase,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    double? speed,
    int? currentQuality,
    List<PlaybackQuality>? availableQualities,
    double? videoAspectRatio,
    Duration? restoredPosition,
    bool? isInPictureInPicture,
    String? message,
    bool clearMessage = false,
  }) {
    return PlaybackSnapshot(
      phase: phase ?? this.phase,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      speed: speed ?? this.speed,
      currentQuality: currentQuality ?? this.currentQuality,
      availableQualities: availableQualities ?? this.availableQualities,
      videoAspectRatio: videoAspectRatio ?? this.videoAspectRatio,
      restoredPosition: restoredPosition ?? this.restoredPosition,
      isInPictureInPicture: isInPictureInPicture ?? this.isInPictureInPicture,
      message: clearMessage ? null : (message ?? this.message),
    );
  }
}

/// 约束 Flutter 播放页需要的播放器能力，测试时可替换为无网络的假实现。
abstract interface class PlaybackService {
  /// 持续提供原生播放器状态变化。
  Stream<PlaybackSnapshot> get states;

  /// 创建原生播放器并返回 Flutter 用来绘制视频画面的纹理编号。
  Future<int?> initialize();

  /// 让原生层打开指定分P，并按所选清晰度直接请求播放数据。
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
  });

  /// 继续原生播放器播放。
  Future<void> play();

  /// 暂停原生播放器播放。
  Future<void> pause();

  /// 相对当前位置快进或快退指定时长。
  Future<void> seekBy(Duration offset);

  /// 跳转到指定的绝对播放位置。
  Future<void> seekTo(Duration position);

  /// 将原生播放器切换到指定倍速。
  Future<void> setPlaybackSpeed(double speed);

  /// 保留当前进度并重新请求指定清晰度的播放数据。
  Future<void> selectQuality(int quality);

  /// 读取该视频最后观看的分P和可恢复进度。
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid);

  /// 读取播放器竖向手势所需的当前亮度和媒体音量。
  Future<SystemPlaybackLevels> getSystemPlaybackLevels();

  /// 将当前窗口亮度设置为 0 到 1 的比例。
  Future<void> setScreenBrightness(double brightness);

  /// 将媒体音量设置为 0 到 1 的比例。
  Future<void> setMediaVolume(double volume);

  /// 请求 Android 将当前播放页面切换为系统画中画窗口。
  Future<bool> enterPictureInPicture(double aspectRatio);

  /// 释放 Android 播放器、后台播放数据请求和 Flutter 订阅需要的资源。
  Future<void> dispose();
}

/// 通过 Flutter MethodChannel 调用 Android Media3 原生播放器。
class NativePlaybackService implements PlaybackService {
  /// 注册 Android 到 Flutter 的状态回调，让此页面能接收原生播放状态。
  NativePlaybackService() {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/playback',
  );
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  final StreamController<PlaybackSnapshot> _stateController =
      StreamController<PlaybackSnapshot>.broadcast();
  bool _disposed = false;

  /// 暴露播放器状态流，但不允许页面直接向流中写数据。
  @override
  Stream<PlaybackSnapshot> get states => _stateController.stream;

  /// 请求 Android 创建 Media3 与视频纹理，并返回纹理编号给 Flutter 的 Texture 控件。
  @override
  Future<int?> initialize() async {
    final Object? result = await _channel.invokeMethod<Object?>('initialize');
    if (result is! Map) {
      return null;
    }
    final Map<Object?, Object?> values = Map<Object?, Object?>.from(result);
    return (values['textureId'] as num?)?.toInt();
  }

  /// 检查视频、分P和清晰度后，让 Android 层直接请求本次播放需要的 DASH 数据。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
  }) async {
    if (!_bvidPattern.hasMatch(video.bvid.trim())) {
      throw ArgumentError.value(video.bvid, 'video.bvid', '需要有效的 BV 号。');
    }
    final VideoPart targetPart = part ?? video.initialPart;
    if (targetPart.cid <= 0) {
      throw ArgumentError.value(targetPart.cid, 'part.cid', '需要有效的分P编号。');
    }
    if (quality <= 0) {
      throw ArgumentError.value(quality, 'quality', '需要有效的清晰度编号。');
    }
    await _invokeVoid(
      'open',
      <String, Object?>{
        'bvid': video.bvid.trim(),
        'cid': targetPart.cid,
        'pageNumber': targetPart.pageNumber,
        'quality': quality,
        'title': video.title,
        'partTitle': targetPart.title,
        'ownerName': video.ownerName,
      },
    );
  }

  /// 向 Android 原生播放器发送继续播放命令。
  @override
  Future<void> play() => _invokeVoid('play');

  /// 向 Android 原生播放器发送暂停命令。
  @override
  Future<void> pause() => _invokeVoid('pause');

  /// 向 Android 原生播放器发送相对快进或快退命令，并以毫秒传递时长。
  @override
  Future<void> seekBy(Duration offset) {
    return _invokeVoid('seekBy', <String, Object?>{
      'offsetMs': offset.inMilliseconds,
    });
  }

  /// 向 Android 原生播放器发送绝对跳转命令，并以毫秒传递时长。
  @override
  Future<void> seekTo(Duration position) {
    return _invokeVoid('seekTo', <String, Object?>{
      'positionMs': position.inMilliseconds,
    });
  }

  /// 检查倍速范围后，把新的播放速度发送给 Android Media3。
  @override
  Future<void> setPlaybackSpeed(double speed) {
    if (!speed.isFinite || speed < 0.5 || speed > 2) {
      throw ArgumentError.value(speed, 'speed', '倍速必须在 0.5 到 2.0 之间。');
    }
    return _invokeVoid('setSpeed', <String, Object?>{'speed': speed});
  }

  /// 检查清晰度编号后，请求 Android 在当前进度切换播放源。
  @override
  Future<void> selectQuality(int quality) {
    if (quality <= 0) {
      throw ArgumentError.value(quality, 'quality', '需要有效的清晰度编号。');
    }
    return _invokeVoid('selectQuality', <String, Object?>{'quality': quality});
  }

  /// 从 Android 本地偏好设置读取一支视频最后观看的分P状态。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async {
    final Object? result = await _invokeResult(
      'getSavedPlaybackState',
      <String, Object?>{'bvid': bvid.trim()},
    );
    if (result is! Map) {
      return null;
    }
    final SavedPlaybackState state = SavedPlaybackState.fromPlatformMap(
      Map<Object?, Object?>.from(result),
    );
    return state.cid > 0 && state.pageNumber > 0 ? state : null;
  }

  /// 请求 Android 返回当前窗口亮度和媒体音量比例。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async {
    final Object? result = await _invokeResult('getSystemPlaybackLevels');
    if (result is Map) {
      return SystemPlaybackLevels.fromPlatformMap(
        Map<Object?, Object?>.from(result),
      );
    }
    return const SystemPlaybackLevels(brightness: 0.5, volume: 0.5);
  }

  /// 检查亮度比例后交给 Android 当前播放窗口。
  @override
  Future<void> setScreenBrightness(double brightness) {
    return _invokeVoid(
      'setScreenBrightness',
      <String, Object?>{'value': brightness.clamp(0.01, 1)},
    );
  }

  /// 检查音量比例后交给 Android 媒体音量通道。
  @override
  Future<void> setMediaVolume(double volume) {
    return _invokeVoid(
      'setMediaVolume',
      <String, Object?>{'value': volume.clamp(0, 1)},
    );
  }

  /// 把当前视频宽高比发送给 Android，并返回系统是否成功进入画中画。
  @override
  Future<bool> enterPictureInPicture(double aspectRatio) async {
    final Object? result = await _invokeResult(
      'enterPictureInPicture',
      <String, Object?>{'aspectRatio': aspectRatio},
    );
    return result == true;
  }

  /// 调用需要返回值的 Android 方法，并在服务释放后返回空值。
  Future<Object?> _invokeResult(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (_disposed) {
      return null;
    }
    return _channel.invokeMethod<Object?>(method, arguments);
  }

  /// 调用不需要返回值的方法，并在服务已经释放时安全地忽略晚到的页面操作。
  Future<void> _invokeVoid(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (_disposed) {
      return;
    }
    await _channel.invokeMethod<void>(method, arguments);
  }

  /// 接收 Android 主动推送的播放状态，并转换为 Dart 中稳定的类型。
  Future<void> _handlePlatformCall(MethodCall call) async {
    if (_disposed || call.method != 'playbackEvent' || call.arguments is! Map) {
      return;
    }
    final Map<Object?, Object?> values = Map<Object?, Object?>.from(
      call.arguments as Map<Object?, Object?>,
    );
    _stateController.add(PlaybackSnapshot.fromPlatformMap(values));
  }

  /// 通知 Android 释放当前视频资源，并关闭本页使用的状态流。
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // 测试或非 Android 平台没有原生实现时，不影响页面正常销毁。
    } finally {
      await _stateController.close();
    }
  }
}
