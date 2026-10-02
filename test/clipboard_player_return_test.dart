import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/player_route_session.dart';

/// 使用真实通道所有权和播放命令，模拟初始化时原生推送空状态。
class ReturningPlayback extends NativePlaybackService {
  final events = StreamController<PlaybackSnapshot>.broadcast(sync: true);
  PlaybackSnapshot snapshot = const PlaybackSnapshot();

  /// 提供受测试控制的状态流，原生资源命令仍使用真实服务实现。
  @override
  Stream<PlaybackSnapshot> get states => events.stream;

  /// 同步推送状态，复现初始化空状态覆盖原视频位置与倍速的情况。
  void emit(PlaybackSnapshot value) {
    snapshot = value;
    events.add(value);
  }

  /// 创建真实通道所有权后推送空状态。
  @override
  Future<int?> initialize() async {
    final texture = await super.initialize();
    emit(const PlaybackSnapshot());
    return texture;
  }

  /// 保留实际打开命令，同时模拟成功的媒体准备状态。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    await super.openVideo(
      video,
      part: part,
      quality: quality,
      initialPosition: initialPosition,
    );
    emit(
      PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        position: initialPosition ?? Duration.zero,
        duration: const Duration(minutes: 3),
        currentQuality: quality,
      ),
    );
  }

  /// 记录真实倍速调用，并更新页面所见的状态。
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    await super.setPlaybackSpeed(speed);
    emit(snapshot.copyWith(speed: speed));
  }

  /// 模拟原生暂停状态，保持当前位置与倍速。
  @override
  Future<void> pause() async {
    await super.pause();
    emit(snapshot.copyWith(isPlaying: false));
  }

  /// 使用固定系统音量和亮度，避免访问实机设置。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async =>
      const SystemPlaybackLevels(brightness: 0.5, volume: 0.5);

  /// 测试不读取真实续播记录。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async => null;

  /// 执行真实原生释放门控后关闭测试事件流。
  @override
  Future<void> dispose() async {
    await super.dispose();
    await events.close();
  }
}

/// 验证真实路由退出顺序及 PlayerPage 恢复后的进度、清晰度、倍速和播放命令。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('剪贴板视频退出完成后原视频可继续播放并保留播放设置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.focubili.app/playback');
    final calls = <MethodCall>[];
    String? loadedBvid;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'initialize') {
            loadedBvid = null;
            return {'textureId': 1};
          }
          if (call.method == 'open') {
            loadedBvid = (call.arguments as Map)['bvid'] as String;
          }
          if (call.method == 'dispose') loadedBvid = null;
          if (call.method == 'play' && loadedBvid == null) {
            throw PlatformException(code: 'released');
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final navigator = GlobalKey<NavigatorState>();
    final original = ReturningPlayback();
    final firstVideo = VideoPreview.placeholder();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: PlayerPage(
          video: firstVideo,
          playbackService: original,
          appPlatform: AppPlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();
    original.emit(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        position: Duration(seconds: 47),
        duration: Duration(minutes: 3),
        speed: 2,
        currentQuality: 80,
      ),
    );
    await tester.pump();
    final previous = await PlayerRouteSession.suspendCurrent();
    final nextVideo = VideoPreview(
      bvid: 'BV1xx411c7mD',
      cid: firstVideo.cid,
      title: '剪贴板视频',
      ownerName: '',
      parts: firstVideo.parts,
    );
    late ReturningPlayback clipboard;
    final route = MaterialPageRoute<void>(
      builder: (_) {
        clipboard = ReturningPlayback();
        return PlayerPage(
          video: nextVideo,
          playbackService: clipboard,
          appPlatform: AppPlatform.android,
        );
      },
    );
    unawaited(
      navigator.currentState!
          .push(route)
          .then((_) => previous!.restoreAfterRoute(route)),
    );
    await tester.pumpAndSettle();
    expect(loadedBvid, nextVideo.bvid);
    navigator.currentState!.pop();
    await tester.pump();
    // 弹出通知到达时，下层路由还在做退出动画，原服务不能提前抢回通道。
    expect(original.ownsPlatformChannel, isFalse);
    await tester.pumpAndSettle();
    expect(original.ownsPlatformChannel, isTrue);
    expect(loadedBvid, firstVideo.bvid);
    final lastOpen =
        calls.lastWhere((call) => call.method == 'open').arguments as Map;
    expect(lastOpen['initialPositionMs'], 47000);
    expect(lastOpen['quality'], 80);
    expect(original.snapshot.speed, 2);
    expect(original.snapshot.isPlaying, isFalse);
    await original.play();
    expect(calls.last.method, 'play');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
