import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/native_playback_service.dart';

/// 注册原生播放服务的倍速范围与方法通道参数回归测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('com.focubili.app/playback');
  final List<MethodCall> calls = <MethodCall>[];

  /// 每项测试都记录 Flutter 发给 Android 的调用，避免使用真实播放器或网络。
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  /// 每项测试结束后移除假原生通道，避免影响其余播放器测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 验证三倍速会穿过 Flutter 校验并被完整发送给 Android 原生播放器。
  test('原生播放服务允许并发送三倍速', () async {
    final NativePlaybackService service = NativePlaybackService();

    await service.setPlaybackSpeed(3);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setSpeed');
    expect(
      Map<Object?, Object?>.from(calls.single.arguments as Map)['speed'],
      3,
    );
    await service.dispose();
  });

  /// 验证超过三倍速仍会在 Flutter 层安全拦截，避免把非法速度交给 Android。
  test('原生播放服务拒绝超过三倍速', () async {
    final NativePlaybackService service = NativePlaybackService();

    expect(() => service.setPlaybackSpeed(3.01), throwsArgumentError);
    expect(calls, isEmpty);
    await service.dispose();
  });

  /// 验证下层播放器占用静态通道后，旧页面可通过重新初始化夺回状态回调。
  test('嵌套播放器退出后旧服务可以重新取得原生通道', () async {
    final NativePlaybackService first = NativePlaybackService();
    final NativePlaybackService second = NativePlaybackService();

    expect(first.ownsPlatformChannel, isFalse);
    expect(second.ownsPlatformChannel, isTrue);

    await second.dispose();
    expect(second.ownsPlatformChannel, isFalse);

    await first.initialize();
    expect(first.ownsPlatformChannel, isTrue);

    await first.dispose();
  });

  /// 验证恢复门控字段能从平台状态读取并在页面复制快照时保持，旧平台缺字段则安全关闭。
  test('播放快照兼容恢复位置门控字段', () {
    final PlaybackSnapshot restoring = PlaybackSnapshot.fromPlatformMap(
      <Object?, Object?>{'isRestoringPosition': true},
    );
    final PlaybackSnapshot legacy = PlaybackSnapshot.fromPlatformMap(
      const <Object?, Object?>{},
    );

    expect(restoring.isRestoringPosition, isTrue);
    expect(
      restoring
          .copyWith(position: const Duration(seconds: 8))
          .isRestoringPosition,
      isTrue,
    );
    expect(legacy.isRestoringPosition, isFalse);
  });
}
