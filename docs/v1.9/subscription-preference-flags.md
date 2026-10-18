# 订阅偏好的只读快照 API

基线 `de735a1`，独立分支 `codex/v19-subscription-flags`。本提交不合入候选 1.8 文件，不修改工作流、版本或 integration 工作区。

## 接口与边界

```dart
Future<Map<String, bool>> SubscriptionService.exportPreferenceFlags()
```

返回不可变 Map，且仅有三个键：`enabled`、`notificationsEnabled`、`backgroundRefreshEnabled`。缺省字段为 false，显式 null 和其他非 bool 类型均拒绝；根必须是 JSON Map，版本必须为 int 1 或 2。

- 首先等待该 service 既有 `_writes`，随后检查 `storageError`。错误状态保留并报错，不尝试恢复。
- 先调用权威 `SubscriptionSnapshotStore.read()`；仅当没有快照时，才获取 legacy prefs、reload 并读取 `focubili_subscriptions_v1`。权威快照损坏时不回退到旧 prefs。
- 不调用 initialize、recover、transact、备份、迁移、去重、清理、调度或网络，也不读取 history page。不会将持久化值恢复到 service 的内存状态，不触发通知。
- 只校验根、版本与三个开关，未选中的源、feed 和 historyJobs 内容损坏不会阻碍独立偏好读取。
- `exportLocalData()` 复用相同的私有只读根读取 helper，继续执行原有完整 source/feed/checkpoint/history 严格检查。坏内容仍拒绝完整导出；新 helper 同时拒绝显式 null 开关与非 int 版本。

后续最终 1.8 基线合入后，`DeviceSettingsRuntimeAdapter.readSettings()` 可映射：

```dart
final flags = await _subscriptions.exportPreferenceFlags();
// enabledKey: flags['enabled']!
// notificationsKey: flags['notificationsEnabled']!
// backgroundKey: flags['backgroundRefreshEnabled']!
```

读取路径不再调用 `_prepareSubscriptions()`；写入路径仍保留其现有初始化和事务流程。本提交不修改尚未合入的 adapter。

## 验证

新增 `test/subscription_preference_flags_test.dart` 的 16 项合成测试。冷读取夹具的 initialize、历史读写、网络调用和 prefs 写入一旦发生即报错，另统计 `CountingSnapshots` 的 read / transact / save / recover、后台调度与通知次数。

覆盖 legacy v1/v2、全部开关组合、缺省值、DB 优先与空 DB 回退、损坏权威快照不回退、storageError、坏根 / 版本 / bool、坏 feed 与完整导出的边界，以及正在提交的成功 / 失败写入。延迟快照故意允许读取旧提交值，验证 API 本身等待 `_writes`，而非借测试存储的队列隐式等待。

执行命令（均使用合成 prefs、快照和临时导出夹具）：

```powershell
flutter test --no-pub test/unified_export_service_test.dart test/unified_export_page_test.dart test/video_note_export_service_test.dart test/subtitle_export_service_test.dart test/local_export_service_test.dart test/search_content_filter_validation_test.dart test/subscription_preference_flags_test.dart
dart analyze lib/services/subscription_service.dart test/subscription_preference_flags_test.dart
git diff --check
```

结果：73 项通过（当前基线已有回归 57 项 + 新增 16 项），退出码 0，`All tests passed!`；局部 analyze 退出码 0，`No issues found!`；diff 检查通过。未运行全量测试，未读取真实偏好、账号或历史内容。原生 DB 与设备上的最终 adapter 整合验收留给最终基线合入后执行。
