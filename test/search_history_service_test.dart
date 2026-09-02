import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/search_history_service.dart';

/// 注册搜索记录服务对行为开关的回归测试。
void main() {
  /// 每项测试使用空白内存偏好，避免搜索词跨测试残留。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证关闭记录后不新增搜索词，但已保存记录仍可查看和清除。
  test('关闭搜索记录后不再写入新内容', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppBehaviorPreferencesService behaviorService =
        AppBehaviorPreferencesService(
          preferencesLoader: () async => preferences,
        );
    final SearchHistoryService service = SearchHistoryService(
      preferencesLoader: () async => preferences,
      behaviorPreferencesService: behaviorService,
    );
    await service.addHistory('已有记录');
    await behaviorService.saveSearchHistoryEnabled(false);

    final List<String> history = await service.addHistory('不应保存');

    expect(history, <String>['已有记录']);
    expect(await service.clearHistory(), isEmpty);
  });
}
