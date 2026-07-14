import 'package:flutter/services.dart';

import '../models/player_overlay_data.dart';

/// 抽象 Flutter 到原生叠加数据通道，方便测试替换而不触及真实 Android 会话。
abstract interface class PlayerOverlayPlatformChannel {
  /// 调用不包含 Cookie、字幕临时地址或弹幕 Protobuf 的原生只读方法。
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]);
}

/// 生产环境使用固定播放通道调用 Android，Cookie 仍完全留在原生 WebView 容器。
class MethodChannelPlayerOverlayPlatformChannel
    implements PlayerOverlayPlatformChannel {
  /// 创建绑定 FocuBili 原生播放通道的叠加数据桥接器。
  const MethodChannelPlayerOverlayPlatformChannel();

  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/playback',
  );

  /// 转发只含 BV、CID、轨道编号或弹幕段号的安全请求到 Android。
  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    return _channel.invokeMethod<Object?>(method, arguments);
  }
}

/// 定义播放器叠加数据层对字幕轨道、字幕条目和弹幕分段的只读能力。
abstract interface class PlayerOverlayService {
  /// 请求当前 BV 与分P的字幕轨道元数据，结果不会包含临时字幕地址。
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  });

  /// 请求一个已经由原生确认可用的字幕轨道内容。
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  });

  /// 请求一段固定六分钟的真实弹幕；结果不包含 Cookie、请求地址或原始 Protobuf。
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  });
}

/// 通过受限 MethodChannel 获取字幕和弹幕数据，并把平台异常转换为可展示状态。
class NativePlayerOverlayService implements PlayerOverlayService {
  /// 创建叠加数据服务；测试可传入内存通道，生产环境使用 Android 原生通道。
  NativePlayerOverlayService({PlayerOverlayPlatformChannel? platformChannel})
      : _platformChannel = platformChannel ??
            const MethodChannelPlayerOverlayPlatformChannel();

  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  final PlayerOverlayPlatformChannel _platformChannel;

  /// 校验参数后请求原生轨道元数据，并将“无字幕/需登录/锁定”保留为正常展示状态。
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    final Map<String, Object?>? arguments = _createVideoArguments(bvid, cid);
    if (arguments == null) {
      return const SubtitleTrackLoadResult.unavailable(message: '字幕请求参数无效。');
    }
    try {
      final Object? result = await _platformChannel.invokeMethod(
        'loadSubtitleTracks',
        arguments,
      );
      if (result is! Map) {
        return const SubtitleTrackLoadResult.unavailable();
      }
      return SubtitleTrackLoadResult.fromPlatformMap(
        Map<Object?, Object?>.from(result),
      );
    } on PlatformException catch (error) {
      return _trackResultFromPlatformError(error);
    } on MissingPluginException {
      return const SubtitleTrackLoadResult.unavailable(
        message: '当前设备暂不支持读取字幕。',
      );
    } catch (_) {
      return const SubtitleTrackLoadResult.unavailable();
    }
  }

  /// 校验视频和轨道编号后请求原生字幕条目，避免把临时地址带到 Flutter。
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    final Map<String, Object?>? arguments = _createVideoArguments(bvid, cid);
    final String normalizedTrackId = trackId.trim();
    if (arguments == null || normalizedTrackId.isEmpty) {
      return const SubtitleCueLoadResult.unavailable(message: '字幕请求参数无效。');
    }
    try {
      final Object? result = await _platformChannel.invokeMethod(
        'loadSubtitleCues',
        <String, Object?>{
          ...arguments,
          'trackId': normalizedTrackId,
        },
      );
      if (result is! Map) {
        return const SubtitleCueLoadResult.unavailable();
      }
      return SubtitleCueLoadResult.fromPlatformMap(
        Map<Object?, Object?>.from(result),
      );
    } on PlatformException catch (error) {
      return _cueResultFromPlatformError(error);
    } on MissingPluginException {
      return const SubtitleCueLoadResult.unavailable(
        message: '当前设备暂不支持读取字幕。',
      );
    } catch (_) {
      return const SubtitleCueLoadResult.unavailable();
    }
  }

  /// 校验视频与段号后请求原生分段弹幕，不让页面拼接任意接口地址或读取登录会话。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    final Map<String, Object?>? arguments = _createVideoArguments(bvid, cid);
    if (arguments == null ||
        segmentIndex < 1 ||
        segmentIndex > DanmakuSegmentLoadResult.maximumSegmentIndex) {
      return const DanmakuSegmentLoadResult.unavailable(
        message: '弹幕请求参数无效。',
      );
    }
    try {
      final Object? result = await _platformChannel.invokeMethod(
        'loadDanmakuSegment',
        <String, Object?>{
          ...arguments,
          'segmentIndex': segmentIndex,
        },
      );
      if (result is! Map) {
        return DanmakuSegmentLoadResult.unavailable(
          segmentIndex: segmentIndex,
        );
      }
      return DanmakuSegmentLoadResult.fromPlatformMap(
        Map<Object?, Object?>.from(result),
      );
    } on PlatformException catch (error) {
      return _danmakuResultFromPlatformError(error, segmentIndex);
    } on MissingPluginException {
      return DanmakuSegmentLoadResult.unavailable(
        segmentIndex: segmentIndex,
        message: '当前设备暂不支持读取弹幕。',
      );
    } catch (_) {
      return DanmakuSegmentLoadResult.unavailable(segmentIndex: segmentIndex);
    }
  }

  /// 验证 BV 与 CID 后创建唯一允许传给原生的安全请求参数。
  Map<String, Object?>? _createVideoArguments(String bvid, int cid) {
    final String normalizedBvid = bvid.trim();
    if (!_bvidPattern.hasMatch(normalizedBvid) || cid <= 0) {
      return null;
    }
    return <String, Object?>{'bvid': normalizedBvid, 'cid': cid};
  }

  /// 把原生轨道错误转为页面可显示的状态，且不使用错误详情中的敏感内容。
  SubtitleTrackLoadResult _trackResultFromPlatformError(
      PlatformException error) {
    switch (error.code) {
      case 'subtitle_login_required':
        return const SubtitleTrackLoadResult.loginRequired();
      case 'subtitle_locked':
        return const SubtitleTrackLoadResult.locked();
      default:
        return const SubtitleTrackLoadResult.unavailable();
    }
  }

  /// 把原生字幕条目错误转为页面可显示的状态，锁定轨道不会被当成网络故障重试。
  SubtitleCueLoadResult _cueResultFromPlatformError(PlatformException error) {
    switch (error.code) {
      case 'subtitle_login_required':
        return const SubtitleCueLoadResult.loginRequired();
      case 'subtitle_locked':
      case 'subtitle_track_not_loaded':
        return const SubtitleCueLoadResult.locked();
      default:
        return const SubtitleCueLoadResult.unavailable();
    }
  }

  /// 将原生弹幕错误统一收敛为稳定提示，不把内部错误详情、地址或 Cookie 暴露给页面。
  DanmakuSegmentLoadResult _danmakuResultFromPlatformError(
    PlatformException error,
    int segmentIndex,
  ) {
    switch (error.code) {
      case 'danmaku_invalid_data':
        return DanmakuSegmentLoadResult.unavailable(
          segmentIndex: segmentIndex,
          message: '弹幕数据格式暂时无法读取，请稍后重试。',
        );
      case 'danmaku_too_large':
        return DanmakuSegmentLoadResult.unavailable(
          segmentIndex: segmentIndex,
          message: '当前片段弹幕过多，暂时无法读取。',
        );
      default:
        return DanmakuSegmentLoadResult.unavailable(segmentIndex: segmentIndex);
    }
  }
}
