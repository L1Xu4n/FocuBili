import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_progress_store.dart';

/// 验证 Windows 进度仓库会持久化时长并在读取时执行共享完播规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const WindowsPlaybackProgressStore store = WindowsPlaybackProgressStore();

  /// 每项测试使用空白偏好，避免其他本机设置干扰恢复结果。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 普通中途进度应连同分P和总时长完整保存并读回。
  test('Windows 保存并读取中途进度', () async {
    await store.save(
      const WindowsPlaybackProgressSnapshot(
        bvid: 'BV1GJ411x7h7',
        cid: 202,
        pageNumber: 2,
        position: Duration(seconds: 47),
        duration: Duration(minutes: 2),
      ),
    );

    final SavedPlaybackState? state = await store.load('bv1gj411x7h7');

    expect(state?.cid, 202);
    expect(state?.pageNumber, 2);
    expect(state?.position, const Duration(seconds: 47));
  });

  /// 距结尾三秒的进度应归零，但最后分P仍需要保留。
  test('Windows 完播边界归零但保留最后分P', () async {
    await store.save(
      const WindowsPlaybackProgressSnapshot(
        bvid: 'BV1GJ411x7h7',
        cid: 202,
        pageNumber: 2,
        position: Duration(seconds: 117),
        duration: Duration(minutes: 2),
      ),
    );

    final SavedPlaybackState? state = await store.load('BV1GJ411x7h7');

    expect(state?.cid, 202);
    expect(state?.position, Duration.zero);
  });

  /// 旧版 JSON 没有总时长，无法安全判断是否接近结尾，因此只恢复分P。
  test('Windows 旧记录缺少时长时不恢复位置', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'windows_playback_state_BV1GJ411X7H7': jsonEncode(<String, int>{
        'cid': 202,
        'pageNumber': 2,
        'positionMs': 117000,
      }),
    });

    final SavedPlaybackState? state = await store.load('BV1GJ411x7h7');

    expect(state?.cid, 202);
    expect(state?.position, Duration.zero);
  });

  /// 字段类型损坏的本机 JSON 应安全忽略，不能让播放器初始化失败。
  test('Windows 损坏记录安全返回空值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'windows_playback_state_BV1GJ411X7H7': jsonEncode(<String, Object>{
        'cid': '错误编号',
        'pageNumber': 2,
        'positionMs': 47000,
        'durationMs': 120000,
      }),
    });

    final SavedPlaybackState? state = await store.load('BV1GJ411x7h7');

    expect(state, isNull);
  });
}
