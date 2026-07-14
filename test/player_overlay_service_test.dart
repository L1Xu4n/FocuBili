import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/player_overlay_service.dart';

/// 用内存回调代替 Android MethodChannel，验证字幕服务不会依赖真实 Cookie 或网络。
class _FakePlayerOverlayPlatformChannel
    implements PlayerOverlayPlatformChannel {
  /// 创建记录调用参数并返回测试预设结果的假原生通道。
  _FakePlayerOverlayPlatformChannel(this._handler);

  final Future<Object?> Function(
    String method,
    Map<String, Object?>? arguments,
  ) _handler;
  final List<String> methods = <String>[];
  final List<Map<String, Object?>?> arguments = <Map<String, Object?>?>[];

  /// 记录字幕调用后交给测试预设回调，模拟 Android 返回值或平台异常。
  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    methods.add(method);
    this.arguments.add(arguments);
    return _handler(method, arguments);
  }
}

/// 运行字幕、弹幕通道、状态转换与数据上限的纯 Dart 回归测试。
void main() {
  test('字幕轨道只接收安全元数据并保留可选择状态', () async {
    final _FakePlayerOverlayPlatformChannel channel =
        _FakePlayerOverlayPlatformChannel(
      (String method, Map<String, Object?>? arguments) async {
        expect(method, 'loadSubtitleTracks');
        expect(arguments, <String, Object?>{
          'bvid': 'BV1GJ411x7h7',
          'cid': 137649199,
        });
        return <String, Object?>{
          'status': 'available',
          'message': '',
          'tracks': <Object?>[
            <String, Object?>{
              'id': '101',
              'language': 'zh-Hans',
              'label': '中文（简体）',
              'isLocked': false,
            },
            <String, Object?>{
              'id': '102',
              'language': 'en-US',
              'label': '英语（美国）',
              'isLocked': true,
            },
            <String, Object?>{
              'language': 'broken',
              'label': '无编号字幕',
              'isLocked': false,
            },
          ],
        };
      },
    );
    final NativePlayerOverlayService service =
        NativePlayerOverlayService(platformChannel: channel);

    final SubtitleTrackLoadResult result = await service.loadSubtitleTracks(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
    );

    expect(result.status, SubtitleLoadStatus.available);
    expect(result.hasSelectableTrack, isTrue);
    expect(result.tracks, hasLength(2));
    expect(result.tracks.first.label, '中文（简体）');
    expect(result.tracks.last.isLocked, isTrue);
    expect(channel.methods, <String>['loadSubtitleTracks']);
  });

  test('字幕服务把登录限制保持为页面可显示状态而不是抛出异常', () async {
    final NativePlayerOverlayService service = NativePlayerOverlayService(
      platformChannel: _FakePlayerOverlayPlatformChannel(
        (String method, Map<String, Object?>? arguments) async {
          return <String, Object?>{
            'status': 'login_required',
            'message': '登录后可尝试读取字幕。',
            'tracks': const <Object?>[],
          };
        },
      ),
    );

    final SubtitleTrackLoadResult result = await service.loadSubtitleTracks(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
    );

    expect(result.status, SubtitleLoadStatus.loginRequired);
    expect(result.message, contains('登录'));
    expect(result.tracks, isEmpty);
  });

  test('字幕条目会过滤无效时间并裁剪异常长文本', () async {
    final String longText = List<String>.filled(500, '字').join();
    final _FakePlayerOverlayPlatformChannel channel =
        _FakePlayerOverlayPlatformChannel(
      (String method, Map<String, Object?>? arguments) async {
        expect(method, 'loadSubtitleCues');
        expect(arguments?['trackId'], '101');
        return <String, Object?>{
          'status': 'available',
          'message': '',
          'cues': <Object?>[
            <String, Object?>{
              'fromMs': 1200,
              'toMs': 2400,
              'content': longText,
            },
            <String, Object?>{
              'fromMs': 3000,
              'toMs': 3000,
              'content': '无效区间',
            },
            <String, Object?>{
              'fromMs': -100,
              'toMs': 1000,
              'content': '负数起点',
            },
          ],
        };
      },
    );
    final NativePlayerOverlayService service =
        NativePlayerOverlayService(platformChannel: channel);

    final SubtitleCueLoadResult result = await service.loadSubtitleCues(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      trackId: '101',
    );

    expect(result.status, SubtitleLoadStatus.available);
    expect(result.cues, hasLength(2));
    expect(result.cues.first.from, const Duration(milliseconds: 1200));
    expect(
        result.cues.first.content.runes.length, SubtitleCue.maxContentLength);
    expect(result.cues.last.from, Duration.zero);
  });

  test('锁定字幕平台错误会转成锁定状态且不会泄露原生错误内容', () async {
    final NativePlayerOverlayService service = NativePlayerOverlayService(
      platformChannel: _FakePlayerOverlayPlatformChannel(
        (String method, Map<String, Object?>? arguments) {
          throw PlatformException(
            code: 'subtitle_locked',
            message: '不应显示的内部错误内容',
          );
        },
      ),
    );

    final SubtitleCueLoadResult result = await service.loadSubtitleCues(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      trackId: '101',
    );

    expect(result.status, SubtitleLoadStatus.locked);
    expect(result.message, isNot(contains('内部错误内容')));
  });

  test('无效 BV 不会触发原生字幕通道', () async {
    final _FakePlayerOverlayPlatformChannel channel =
        _FakePlayerOverlayPlatformChannel(
      (String method, Map<String, Object?>? arguments) async =>
          <String, Object?>{},
    );
    final NativePlayerOverlayService service =
        NativePlayerOverlayService(platformChannel: channel);

    final SubtitleTrackLoadResult result = await service.loadSubtitleTracks(
      bvid: 'not-a-bvid',
      cid: 137649199,
    );

    expect(result.status, SubtitleLoadStatus.unavailable);
    expect(channel.methods, isEmpty);
  });

  test('弹幕按六分钟段号请求并过滤损坏或超长条目', () async {
    final String longText = List<String>.filled(250, '弹').join();
    final _FakePlayerOverlayPlatformChannel channel =
        _FakePlayerOverlayPlatformChannel(
      (String method, Map<String, Object?>? arguments) async {
        expect(method, 'loadDanmakuSegment');
        expect(arguments, <String, Object?>{
          'bvid': 'BV1GJ411x7h7',
          'cid': 137649199,
          'segmentIndex': 3,
        });
        return <String, Object?>{
          'status': 'available',
          'message': '',
          'segmentIndex': 3,
          'entries': <Object?>[
            <String, Object?>{
              'progressMs': 721000,
              'content': longText,
              'color': 0x12ab34,
              'mode': 1,
            },
            <String, Object?>{
              'progressMs': 722000,
              'content': '无效模式',
              'color': 0xffffff,
              'mode': 99,
            },
            <String, Object?>{
              'progressMs': 723000,
              'content': '第二条',
              'color': 0,
              'mode': 5,
            },
          ],
        };
      },
    );
    final NativePlayerOverlayService service =
        NativePlayerOverlayService(platformChannel: channel);

    final DanmakuSegmentLoadResult result = await service.loadDanmakuSegment(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      segmentIndex: 3,
    );

    expect(result.status, DanmakuLoadStatus.available);
    expect(result.segmentIndex, 3);
    expect(result.entries, hasLength(2));
    expect(result.entries.first.position, const Duration(milliseconds: 721000));
    expect(result.entries.first.content.runes.length,
        DanmakuEntry.maxContentLength);
    expect(result.entries.last.color, 0);
    expect(channel.methods, <String>['loadDanmakuSegment']);
  });

  test('弹幕段号会按六分钟时间轴分页并限制在安全范围', () {
    expect(
      DanmakuSegmentLoadResult.segmentIndexForPosition(Duration.zero),
      1,
    );
    expect(
      DanmakuSegmentLoadResult.segmentIndexForPosition(
        const Duration(minutes: 6),
      ),
      2,
    );
    expect(
      DanmakuSegmentLoadResult.segmentIndexForPosition(
        const Duration(days: 1000),
      ),
      DanmakuSegmentLoadResult.maximumSegmentIndex,
    );
  });

  /// 验证弹幕经过时间会跟随播放器倍速，二倍速一秒等于视频时间两秒。
  test('弹幕时间轴跟随播放倍速', () {
    final Duration position = DanmakuTimeline.advance(
      positionAnchor: const Duration(seconds: 10),
      realElapsed: const Duration(seconds: 1),
      playbackSpeed: 2,
    );

    expect(position, const Duration(seconds: 12));
  });

  /// 验证宽屏弹幕在固定视频时长内从最右完整穿过到最左，不依赖固定像素速度。
  test('弹幕在全屏宽度内完整穿越', () {
    const double canvasWidth = 1920;
    const double textWidth = 180;

    expect(
      DanmakuTimeline.horizontalOffset(
        elapsed: Duration.zero,
        canvasWidth: canvasWidth,
        textWidth: textWidth,
      ),
      canvasWidth,
    );
    expect(
      DanmakuTimeline.horizontalOffset(
        elapsed: const Duration(milliseconds: 4500),
        canvasWidth: canvasWidth,
        textWidth: textWidth,
      ),
      (canvasWidth - textWidth) / 2,
    );
    expect(
      DanmakuTimeline.horizontalOffset(
        elapsed: DanmakuTimeline.scrollingTravelDuration,
        canvasWidth: canvasWidth,
        textWidth: textWidth,
      ),
      -textWidth,
    );
  });

  test('空弹幕片段会保留正常空状态而不会被误判为网络失败', () async {
    final NativePlayerOverlayService service = NativePlayerOverlayService(
      platformChannel: _FakePlayerOverlayPlatformChannel(
        (String method, Map<String, Object?>? arguments) async {
          return <String, Object?>{
            'status': 'none',
            'message': '',
            'segmentIndex': 4,
            'entries': const <Object?>[],
          };
        },
      ),
    );

    final DanmakuSegmentLoadResult result = await service.loadDanmakuSegment(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      segmentIndex: 4,
    );

    expect(result.status, DanmakuLoadStatus.empty);
    expect(result.segmentIndex, 4);
    expect(result.entries, isEmpty);
  });

  test('无效段号不会触发原生通道且平台异常不会泄露内部内容', () async {
    final _FakePlayerOverlayPlatformChannel channel =
        _FakePlayerOverlayPlatformChannel(
      (String method, Map<String, Object?>? arguments) {
        throw PlatformException(
          code: 'danmaku_invalid_data',
          message: '不应显示的内部网络地址或会话内容',
        );
      },
    );
    final NativePlayerOverlayService service =
        NativePlayerOverlayService(platformChannel: channel);

    final DanmakuSegmentLoadResult invalidResult =
        await service.loadDanmakuSegment(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      segmentIndex: 0,
    );
    final DanmakuSegmentLoadResult failureResult =
        await service.loadDanmakuSegment(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      segmentIndex: 5,
    );

    expect(invalidResult.status, DanmakuLoadStatus.unavailable);
    expect(failureResult.status, DanmakuLoadStatus.unavailable);
    expect(failureResult.segmentIndex, 5);
    expect(failureResult.message, isNot(contains('内部网络地址')));
    expect(channel.methods, <String>['loadDanmakuSegment']);
  });
}
