# 设置与候选基线整合验证

工作树 `v19-settings-integration`，分支 `codex/v19-settings-integration`，从父任务指定的 `af282f5` 开发（其包含获准继续整合的 `95b2323` 候选）。本次没有修改其他工作树、版本、BuildTime、workflow、player、notes 或 focus 业务；Windows focus 通知 backend 只增加父任务授权的订阅投递检查，focus API 不变。没有发布 Beta。

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| search.content_filter_v2 共用严格验证 | 自动化通过 | 四字段、int 范围、关键词全 String 列表、null/未知字段拒绝、旧两字段兼容、大小写/词序往返 |
| 导入全量验证后再写 | 自动化通过 | 所有非法搜索设置在 prefs/runtime 读取与写入之前拒绝；异步打开存储时改 Map/List 不改变已确认输入 |
| 黑名单独立于普通设置 | 自动化通过 | import/reset 不动 content.blocklist_v1；普通设置包排除；统一资料包仍保留 |
| 冷导出不触发七天清理、迁移、缓存修复或调度 | 自动化通过（Windows 宿主、合成原生通道） | Windows/iOS/Android 分支各三种导出，实际 SqliteStore readonly、过期行保留、无 native scheduler 调用、坏 entries 索引原样 |
| 设置写入与 native generation | 自动化通过 | 禁用先、启用最后，保留 sources；reset/restore 使用权威存储代次，失去 native 支持仍可停用 |
| 桌面延迟通知 P2 | 自动化通过，待独立审查 | 原红转绿；Win/Linux 分支及并发/嵌套服务、focus、provider 失败共用例通过 |
| Android 原生进度导出 | 自动化通过 | 未修改既有 4f89257/80863e6 路径；native_playback_progress_export_test.dart 纳入回归 |
| 真机与最终整合全量 | 未做 | 本次只跑定向；父任务负责独立审查、最终全量和发布门禁 |

## 设置修正

SettingsTransferService 对搜索 JSON 调用 `SearchContentFilter.fromJsonStrict`，普通浏览容错读取没有改变。合法 1.9 关键词与旧两字段设置均可往返；文件中大小写和词序保留，模型正常化仍沿用 parseKeywords。非法关键词、未知字段和超范围 minimumPlayCount 在任何写入之前拒绝。

独立补测发现可变参数的实际异步边界：旧 importSettings 验证调用方 Map 后等待 preferencesLoader，再从原 Map 构造写入项。此时添加 content.blocklist_v1 可绕过白名单，或更改 speeds 列表可让未验证内容落盘。现在在调用时固定 Map 和列表快照，排队、验证、写入均使用这一份数据。初始七个用例中四条红例已转绿。

DeviceSettingsRuntimeAdapter 的读取保持既有纯 flags/readCapacity；写入初始化、总开关与子开关顺序保持候选契约。UnifiedExportService 的 runtime 四键、普通 prefs 白名单及 Android 进度分支没有生产修改。

冷导出组合测试用实际 SubscriptionService + SqliteSubscriptionSnapshotStore + DeviceSettingsRuntimeAdapter，整个 sqflite/native scheduler 通道由合成 handler 接管。快照为版本 1，含八天前已读条目：如果误用 initialize，就会触发备份或清理，测试会拒绝写 SQL/原生调度。实际导出不初始化服务、保留过期条目和原 prefs；图片容量读取不修复无关坏 entries。正常业务七天清理的边界和并发重放另外通过测试，未为导出停用原清理逻辑。

## 桌面通知 P2

独立 reviewer 的真实链路红例已在本树复现：实际 Service → SubscriptionNotificationService → WindowsFocusNotificationBackend，只有 WindowsNotificationClient 的异步初始化受夹具控制。通知 provider 等待期间关闭通知并完成提交，旧代码仍记录 `[opt-out-committed, show:new]`。修正后原 API/断言不变，仅记录 `[opt-out-committed]`。

Service 在一次通知 callback 的异步 Zone 中携带该请求的 guard，捕获 final generation/epoch，并同步检查当前启用状态、通知许可、运行状态、未 dispose、存储状态和 focus 抑制。请求上下文维持原 `notifyItems(List)` callback API，不需要修改 app.dart，也没有全局当前服务变量。

SubscriptionNotificationService 捕获调用时 guard，传给 Win/Linux 共用 backend 的可选 allowDelivery。backend 等待 provider 就绪后、真正 client.show 前立即重验；异常视为拒绝。共享 provider Future、两个服务并发、嵌套回调均不串用 guard。没有 guard 的直接调用仍保持兼容；focus 完成通知不受订阅 guard 影响；provider 不可用或异常仍返回失败。Android/iOS 的现有 generation/background 参数保留；此次桌面回归不代表已经验证 Apple 原生异步权限回调后的投递竞态。

## Windows 宿主自动化证据

所有数据均为合成 prefs/快照/临时缓存；所有 SQLite、系统调度与通知边界由合成通道或 client 接管。没有读取真实账号、DB、缓存，没有导出凭据，没有弹真实通知或修改系统权限。

离线依赖准备：`flutter.bat pub get --offline`，exit 0。相关回归命令：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/settings_transfer_test.dart test/settings_transfer_search_test.dart test/settings_runtime_adapter_test.dart test/settings_runtime_service_integration_test.dart test/settings_native_subscription_integration_test.dart test/settings_export_retention_integration_test.dart test/search_content_filter_validation_test.dart test/unified_export_service_test.dart test/unified_export_page_test.dart test/unified_export_runtime_settings_test.dart test/native_playback_progress_export_test.dart test/subscription_preference_flags_test.dart test/subscription_sqlite_export_test.dart test/subscription_snapshot_export_read_test.dart test/subscription_background_test.dart test/subscription_service_test.dart test/native_subscription_background_test.dart test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart test/windows_focus_notification_service_test.dart test/focus_notification_service_test.dart test/image_cache_capacity_read_test.dart test/cache_file_lock_test.dart
```

结果：**252 passed，exit 0**；本次新增 36 项测试。额外边界筛选：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/subscription_release_test.dart test/subscription_notification_generation_test.dart --name 'startup and periodic cleanup|cleanup replays|review:'
```

结果：**3 passed，exit 0**，包括已在前组跑过的原通知红例。

静态与格式检查：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' analyze lib/services/settings_transfer_service.dart lib/services/subscription_notification_delivery.dart lib/services/subscription_notification_service.dart lib/services/subscription_service.dart lib/services/windows_focus_notification_service.dart test/settings_transfer_search_test.dart test/settings_export_retention_integration_test.dart test/settings_native_subscription_integration_test.dart test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' format --output=none --set-exit-if-changed lib/services/settings_transfer_service.dart lib/services/subscription_notification_delivery.dart lib/services/subscription_notification_service.dart lib/services/subscription_service.dart lib/services/windows_focus_notification_service.dart test/settings_transfer_search_test.dart test/settings_export_retention_integration_test.dart test/settings_native_subscription_integration_test.dart test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart
```

结果：**No issues found，exit 0；10 files / 0 changed，exit 0**。git diff --check 通过。

## 人工步骤与剩余边界

1. 使用专用合成安装导入含两个关键词列表的设置包；预期大小写和词序保留。导入混合类型/null/未知字段包应在写入前失败，现有设置和黑名单原样保留。
2. 普通设置重置后，订阅源与黑名单应保留，总开关和后台开关关闭；恢复设置后 native 调度 generation 与权威存储一致。
3. 冷状态下执行普通设置、统一设置单选和全选导出；预期导出动作不清理旧已读数据、不建订阅表、不改缓存索引、不触发后台调度。真实平台的数据准备和验证仍需父任务最终门禁。
4. 桌面 provider 准备期间停用订阅通知、停用总开关、暂停/删除来源或进入抑制状态；提交完成后旧请求不投递，后续合法请求仍可投递。系统实际 provider、Linux native client、Apple 原生异步权限回调和最终打包尚未真机验证。

该提交仅提供候选基线的代码整合及合成回归证据，不宣称已完成最终全量、真机通过或发布。
