import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/search_content_filter_service.dart';
import 'package:focubili/models/search_content_filter.dart';

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

  /// New search rules default to learning content without a popularity threshold.
  test('搜索过滤默认开启学习内容而不限制播放量', () async {
    final filter = await const SearchContentFilterService().load();
    expect(filter.learningOnly, isTrue);
    expect(filter.minimumPlayCount, 0);
  });

  /// Arbitrary custom integer limits are now supported and saved with learning mode.
  test('自定义播放量与学习过滤一起持久化', () async {
    const service = SearchContentFilterService();
    await service.save(
      const SearchContentFilter(learningOnly: false, minimumPlayCount: 12345),
    );
    expect((await service.load()).learningOnly, isFalse);
    expect((await service.load()).minimumPlayCount, 12345);
  });

  /// Invalid thresholds are rejected before touching the last valid preferences.
  test('播放量过滤拒绝负数并保留原设置', () async {
    const service = SearchContentFilterService();
    await service.save(const SearchContentFilter(minimumPlayCount: 12345));
    await expectLater(
      service.save(const SearchContentFilter(minimumPlayCount: -1)),
      throwsArgumentError,
    );
    expect((await service.load()).minimumPlayCount, 12345);
  });
}
