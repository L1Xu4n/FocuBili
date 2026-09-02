import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/app_behavior_preferences_service.dart';

/// 注册全局应用行为偏好的默认值和持久化测试。
void main() {
  /// 每项测试使用空白内存偏好，避免行为开关互相影响。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证首次安装默认保护账号，同时保留搜索和观看记录功能。
  test('行为偏好使用安全默认值', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppBehaviorPreferencesService service = AppBehaviorPreferencesService(
      preferencesLoader: () async => preferences,
    );

    expect(await service.loadAccountReadOnly(), isTrue);
    expect(await service.loadSearchHistoryEnabled(), isTrue);
    expect(await service.loadWatchHistoryEnabled(), isTrue);
  });

  /// 验证三个行为开关均可独立写入并由同一服务重新读取。
  test('行为偏好可以独立持久化', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppBehaviorPreferencesService service = AppBehaviorPreferencesService(
      preferencesLoader: () async => preferences,
    );

    expect(await service.saveAccountReadOnly(false), isTrue);
    expect(await service.saveSearchHistoryEnabled(false), isTrue);
    expect(await service.saveWatchHistoryEnabled(false), isTrue);
    expect(await service.loadAccountReadOnly(), isFalse);
    expect(await service.loadSearchHistoryEnabled(), isFalse);
    expect(await service.loadWatchHistoryEnabled(), isFalse);
  });
}
