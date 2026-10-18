# 统一导出的运行时设置

本模块从 `49806fc` 独立开发，工作树 `v19-runtime-settings`，分支 `codex/v19-runtime-settings`。没有合入任何候选 1.8 提交，没有修改 SettingsTransferService、版本、BuildTime 或 workflow。等待独立只读审查和最终 1.8 基线整合；尚未发布。

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| SettingsRuntimeAdapter 类型契约与四键映射 | 自动化通过 | 冷服务/临时缓存接线及实际 SqliteStore 原生通道补测，见审查修正 |
| 只有选择 settings 才读取 runtime | 自动化通过 | 单选、全选、未选不读、未知键排除、陈旧 prefs 不覆盖 |
| 三个 bool 和非负 int 容量严格校验 | 自动化通过 | 缺键、字符串、列表、map、数值 bool、负数和 double 容量拒绝；读取错误阻断资料包 |
| 图片容量纯读取及已有锁等待 | 自动化通过（Windows） | 不建目录/锁/索引；不修复/清理坏 entries；共享读锁与独占写锁互斥；异常释放 |
| writeSettings 原事务顺序 | 自动化通过 | 关闭总开关在前、启用在后、最后图片容量；仅容量不初始化订阅 |
| 最终 1.8 SettingsTransferService 接入与全量 | 未做 | 由 root 在准确最终 SHA 到位后整合；本模块不修改该服务 |
| Android/Linux/macOS/iOS 锁运行时验证 | 未做 | 仅执行 Windows 宿主测试；不等同真机通过 |
| 真机 UI 与发布验证 | 未做 | 本模块无 UI 变更；最终整合后验证 |

## API 与边界

- `SettingsRuntimeAdapter.readSettings(): Future<Map<String, Object>>`。
- `DeviceSettingsRuntimeAdapter({SubscriptionService? subscriptions, ImageResourceCache? imageCache})` 使用现有默认单例，也允许注入合成实例。读取调用 `exportPreferenceFlags()` 与 `readCapacity()`，不会调用 initialize/status。写入保留原契约及其总开关、子开关、图片容量顺序。
- `ImageResourceCache.readCapacity(): Future<int>` 等待同目录进程内串行锁和已有 OS 锁。只读取 `index.json` 根 map 的非负 int `capacity`，不遍历对象或修改索引、目录、缓存对象、租约，不请求网络或发送通知。没有目录或索引时返回 defaultCapacity；坏 JSON/根/capacity 和 IO 错误向上抛出。其他损坏字段不会阻碍独立容量读取。
- `CacheFileLock.acquireExisting(path, {timeout}): Future<CacheFileLock?>` 不创建文件：不存在返回 null；Windows 以 FileMode.read 打开并取 shared lock；Linux/Android 及 Apple 平台复用现有 FFI 路径，以 O_RDONLY + O_NOFOLLOW 打开、flock LOCK_SH 等待。正常和异常都关闭 descriptor/handle。原 acquire 的独占写锁语义保留。以上为实现支持的平台分支，实际执行平台只有 Windows。
- `UnifiedExportService(settingsRuntimeAdapter: ...)` 默认 Device adapter。仅选中 settings 时调用一次，并且只保留以下运行时键；普通 prefs 的同名值完全忽略，adapter 的额外键也不会导出：
  - `subscriptions.enabled`: bool ← raw `enabled`
  - `subscriptions.notifications_enabled`: bool ← raw `notificationsEnabled`
  - `subscriptions.background_refresh_enabled`: bool ← raw `backgroundRefreshEnabled`
  - `resource_cache.image_capacity_bytes`: 非负 int
- 原普通设置白名单保持；`content.blocklist_v1` 继续作为用户规则包含在统一资料包中，本模块没有把它加入普通设置 reset/import schema。
- 未选择 subscriptions 时，其坏 feed/history 不阻碍独立 flags 读取；选择 subscriptions 时既有完整 strict 校验仍会拒绝坏内容。

## Windows 自动化证据

所有数据均为内存合成 prefs、CountingSnapshots、会抛出的网络/history 夹具、系统临时目录；没有读取真实账号、prefs 或缓存。旧导出测试显式注入 FixtureSettingsRuntimeAdapter，避免触碰设备目录。

离线依赖准备：`C:\Users\L1XU4N\flutter\bin\flutter.bat pub get --offline`，exit 0。

定向回归命令：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/unified_export_service_test.dart test/unified_export_page_test.dart test/video_note_export_service_test.dart test/subtitle_export_service_test.dart test/local_export_service_test.dart test/search_content_filter_validation_test.dart test/subscription_preference_flags_test.dart test/image_resource_cache_test.dart test/cache_file_lock_test.dart test/image_cache_capacity_read_test.dart test/settings_runtime_adapter_test.dart test/unified_export_runtime_settings_test.dart
```

结果：**116 passed，exit 0**。其中新用例 26 项，覆盖读写锁超时释放及原有跨 isolate 缓存回归。

局部静态分析：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' analyze lib/services/cache_file_lock.dart lib/services/image_resource_cache.dart lib/services/settings_runtime_adapter.dart lib/services/unified_export_service.dart test/fixtures/settings_runtime_fixture.dart test/image_cache_capacity_read_test.dart test/cache_file_lock_test.dart test/settings_runtime_adapter_test.dart test/unified_export_runtime_settings_test.dart test/unified_export_page_test.dart test/unified_export_service_test.dart
```

结果：**No issues found，exit 0**。`git diff --check`：exit 0。

## 最终整合后的人工步骤与风险

1. 在合成测试配置或专用空数据安装上设置三个订阅开关和图片容量，单选设置导出；预期 settings.json 保留四个权威值，未生成订阅数据或缓存对象。
2. 不选设置再导出；预期包内没有 settings.json，运行时设置读取计数为零。
3. 设置仅导入/重置经最终 SettingsTransferService 后验证事务顺序与失败回滚；黑名单等用户规则不因普通设置重置消失。
4. 在 Linux/macOS 和移动平台执行同组锁/缓存测试并做设备验证。当前 Windows 的验证不能替代这些平台的结果。没有修改系统开发者模式、ACL 或其他权限设置。

跨服务的设置读取是逐服务已提交快照，不提供跨多个存储的全局事务快照；各服务读取失败时整个资料包失败，不返回成功的部分资料包。最终基线尚未给定，所有最终整合与发布门禁仍由 root 执行。

## 独立审查 P2 修正：SQLite 冷读不能建库

`707462c` 的 CountingSnapshots 证据不足以证明 Android 实际存储路径无写入。独立审查发现默认 `SqliteSubscriptionSnapshotStore.read()` 冷打开仍执行可写 openDatabase 和 CREATE TABLE。在本工作树复制 reviewer 的两个合成原生通道夹具后，settings-only 与全选导出均复现红例（exit 1，观察到 openDatabase 无 readOnly:true 及 CREATE TABLE）；该提交没有因此被标记可合入。

修正增加显式 `SubscriptionSnapshotStore.readForExport(): Future<String?>` 契约。`SqliteSubscriptionSnapshotStore` 的实现先 databaseExists，缺库直接 null；现库以 `readOnly:true, singleInstance:false` 独立打开，仅查询 value，finally await close。没有使用可能建库的 `_db`，没有建表、迁移、恢复或修复。存在性检查/打开/查询失败直接传播，不能回退成 legacy 成功；查询成功但 raw 内容损坏仍由原 strict 校验拒绝。

两条 `exportPreferenceFlags/exportLocalData` 继续共用 `_readExportSnapshot`，原来的 await `_writes` 和 storageError 检查保留，然后使用 readForExport。普通 read/recover/transact 及业务 schema 创建保持原行为。唯一测试实现 AtomicSnapshots 显式实现新入口，转发原 read，维持 CountingSnapshots 和延迟提交夹具语义。

新增测试使用真实 SqliteSubscriptionSnapshotStore 和真实 sqflite Dart 包，整个 `com.tekartik.sqflite` 原生通道由合成 handler 接管。不会启动任何原生数据库、读取真实 DB、账号或修改平台权限。覆盖缺库不 open 且 legacy 值保留、现库权威值优先、每个导出句柄 readOnly/关闭、空快照回退、exists/open/query 失败阻断、坏 raw 拒绝后句柄已关闭、业务写库仍有 CREATE，以及 flags/content 两条导出都等待成功/失败的在途原生 UPDATE。

| 审查修正项目 | 状态 | 证据 |
| --- | --- | --- |
| settings-only/full 原生通道冷建库红例 | 自动化通过（修正后） | 两条从红转绿，缺库没有 open/execute，导出使用 legacy flags |
| 现库只读、异常阻断和 finally 关闭 | 自动化通过（Windows mock native 通道） | 17 项 SQLite 定向回归通过 |
| 正常业务读写及延迟写入隔离 | 自动化通过 | 原 read 仍初始化 schema；两条导出等待成功/失败提交；既有订阅业务回归通过 |
| Android 原生设备运行与独立复核 | 未做 | 等 reviewer 在准确修复 SHA 重跑；mock 通道不等同 Android 真机通过 |

SQLite 定向命令：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/subscription_sqlite_export_test.dart test/subscription_snapshot_export_read_test.dart
```

结果：**17 passed，exit 0**。扩大相关回归命令：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/unified_export_service_test.dart test/unified_export_page_test.dart test/video_note_export_service_test.dart test/subtitle_export_service_test.dart test/local_export_service_test.dart test/search_content_filter_validation_test.dart test/subscription_preference_flags_test.dart test/image_resource_cache_test.dart test/cache_file_lock_test.dart test/image_cache_capacity_read_test.dart test/settings_runtime_adapter_test.dart test/unified_export_runtime_settings_test.dart test/subscription_sqlite_export_test.dart test/subscription_snapshot_export_read_test.dart test/subscription_background_test.dart test/subscription_service_test.dart
```

结果：**167 passed，exit 0**，没有跑全量。局部 analyze 与格式检查：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' analyze lib/services/subscription_snapshot_store.dart lib/services/subscription_service.dart test/subscription_background_test.dart test/subscription_sqlite_export_test.dart test/subscription_snapshot_export_read_test.dart
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' format --output=none --set-exit-if-changed lib/services/subscription_snapshot_store.dart lib/services/subscription_service.dart test/subscription_background_test.dart test/subscription_sqlite_export_test.dart test/subscription_snapshot_export_read_test.dart
```

结果：**No issues found，exit 0；5 files / 0 changed，exit 0**。diff check 通过。

句柄清理使用 sqflite 公开 Database.close()，已验证查询异常也会发送 closeDatabase。依赖的 sqflite_common 2.5.11 内部会吞掉原生 closeDatabase 故障，因此没有宣称可以通过公开 API 捕获此类关闭故障，也没有绕过 SDK 内部句柄调用。打开/查询/内容校验失败的阻断有独立测试证据。最终 1.8 基线和平台验证边界保持不变。
