import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

/// 创建使用测试内存偏好设置、固定版本和固定设备信息的问题诊断服务。
ProblemDiagnosticsService _createDiagnosticsService(
  SharedPreferences preferences,
) {
  return ProblemDiagnosticsService(
    preferencesLoader: () async => preferences,
    appVersionLoader: () async => '1.1.0+9',
    deviceInfoLoader: () async => const DiagnosticDeviceInfo(
      androidRelease: '15',
      apiLevel: 35,
      model: 'Xiaomi 23127PN0CC',
    ),
    clock: () => DateTime(2026, 8, 2, 22, 40, 12),
  );
}

/// 注册问题诊断 MVP 的脱敏记录、复制文本和清空行为测试。
void main() {
  /// 每个测试前重置内存偏好设置，避免最近错误跨用例残留。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('播放412错误会生成脱敏风险控制诊断文本', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final ProblemDiagnosticsService service = _createDiagnosticsService(
      preferences,
    );

    await service.recordPlaybackFailure(
      message: '播放数据服务暂时不可用（HTTP 412）。Cookie=secret',
      playerState: 'preparing',
      multiPart: false,
    );

    final ProblemDiagnosticsSnapshot snapshot = await service.loadSnapshot();
    expect(snapshot.appVersion, '1.1.0+9');
    expect(snapshot.deviceInfo.androidLabel, '15 / API 35');
    expect(snapshot.recentErrors, hasLength(1));
    expect(snapshot.recentErrors.single.category, 'riskControl');
    expect(snapshot.recentErrors.single.operation, 'load_play_url');
    expect(snapshot.recentErrors.single.errorCode, 412);
    expect(snapshot.recentErrors.single.description, '平台暂时拒绝了本次请求。');
    expect(snapshot.recentErrors.single.additionalInfo, <String, String>{
      'player_state': 'preparing',
      'multi_part': 'false',
    });

    final String copyText = await service.buildCopyText();
    expect(copyText, contains('FocuBili 问题诊断'));
    expect(copyText, contains('应用版本：1.1.0+9'));
    expect(copyText, contains('Android：15 / API 35'));
    expect(copyText, contains('分类：riskControl'));
    expect(copyText, contains('操作：load_play_url'));
    expect(copyText, isNot(contains('secret')));
    expect(copyText, contains('不包含登录凭据、Cookie、搜索内容、笔记正文、专注目标或完整请求地址'));
  });

  test('闹钟安排恢复与触发事件会进入诊断文本且可单独清空', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    bool clearedReminderDiagnostics = false;
    final ProblemDiagnosticsService service = ProblemDiagnosticsService(
      preferencesLoader: () async => preferences,
      appVersionLoader: () async => '1.1.0+9',
      deviceInfoLoader: () async => const DiagnosticDeviceInfo(
        androidRelease: '15',
        apiLevel: 35,
        model: 'Xiaomi 23127PN0CC',
      ),
      clock: () => DateTime(2026, 8, 2, 22, 40, 12),
      // 假闹钟诊断函数模拟 Android 原生层已经安排并在重启后恢复了一条提醒。
      reminderDiagnosticsLoader: () async =>
          ReminderDiagnosticsSnapshot.fromPlatformMap(<Object?, Object?>{
            'pendingCount': 1,
            'lastScheduledAtMs': DateTime(
              2026,
              8,
              2,
              22,
              35,
            ).millisecondsSinceEpoch,
            'lastTriggeredAtMs': 0,
            'lastRestoredAtMs': DateTime(
              2026,
              8,
              2,
              22,
              36,
            ).millisecondsSinceEpoch,
            'lastTriggerResult': 'never',
            'lastScheduleMode': 'exact',
            'exactAlarmAllowed': true,
            'notificationsEnabled': true,
            'batteryOptimizationIgnored': true,
            'backgroundRestricted': false,
            'manufacturer': 'Xiaomi',
            'events': <Map<Object?, Object?>>[
              <Object?, Object?>{
                'timeMs': DateTime(2026, 8, 2, 22, 36).millisecondsSinceEpoch,
                'type': 'restore',
                'result': 'restored_1',
                'mode': 'boot',
              },
            ],
          }),
      // 假清理函数只记录调用，验证清除错误时也会清除原生闹钟诊断历史。
      reminderDiagnosticsClearer: () async {
        clearedReminderDiagnostics = true;
      },
    );

    final String copyText = await service.buildCopyText();
    expect(copyText, contains('提醒诊断：'));
    expect(copyText, contains('待触发提醒：1'));
    expect(copyText, contains('restore / restored_1 / boot'));
    expect(copyText, isNot(contains('继续看课程')));

    await service.clearRecentErrors();
    expect(clearedReminderDiagnostics, isTrue);
  });

  test('网络错误可清空且不会保留诊断存储键', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final ProblemDiagnosticsService service = _createDiagnosticsService(
      preferences,
    );

    await service.recordNetworkFailure(
      operation: 'search_video',
      message: '网络连接失败。',
    );
    expect((await service.loadRecentErrors()).single.category, 'network');
    expect((await service.loadRecentErrors()).single.operation, 'search_video');

    await service.clearRecentErrors();
    expect(await service.loadRecentErrors(), isEmpty);
    expect(preferences.containsKey('focubili_problem_diagnostics_v1'), isFalse);
  });

  test('诊断记录不会保存视频、搜索词或笔记模型字段', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final ProblemDiagnosticsService service = _createDiagnosticsService(
      preferences,
    );
    const VideoPreview video = VideoPreview(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      title: '不应进入诊断文本的视频标题',
      ownerName: '不应进入诊断文本的UP主',
      parts: <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 137649199,
          title: '第一P',
          duration: Duration(minutes: 3),
        ),
      ],
    );

    await service.recordPlaybackFailure(
      message: '播放器网络异常。',
      playerState: 'playing',
      multiPart: video.parts.length > 1,
    );
    await service.recordNetworkFailure(
      operation: 'search_video',
      message: '搜索请求失败：这是不应保存的私密搜索词。',
    );

    final String copyText = await service.buildCopyText();
    expect(copyText, isNot(contains(video.bvid)));
    expect(copyText, isNot(contains(video.title)));
    expect(copyText, isNot(contains(video.ownerName)));
    expect(copyText, isNot(contains('这是不应保存的私密搜索词')));
  });
}
