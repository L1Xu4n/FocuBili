# 1.8 迟到订阅通知最小回移

精确基线：`95b23239f933f38d61c05c2c6b0cd958ffb74902`。独立分支 `codex/v18-notification-backport`，工作树 `v18-notification-backport`。没有修改实际 1.8 分支，没有 push、发布、版本/BuildTime/workflow 或平台权限变更。由唯一 1.8 发布者决定最终整合。

## 原候选已存在的缺陷

在没有修改任何生产文件的上述精确基线上，复制独立 reviewer 的真实迟到通知夹具并运行：

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/subscription_notification_generation_test.dart
```

结果 **exit 1，0 passed / 1 failed**。真实 Service → NotificationService → WindowsFocusNotificationBackend 链中，只有通知 client 的 provider 初始化由合成门控延迟；通知关闭提交完成后，实际记录仍为 `[opt-out-committed, show:new]`，预期仅 `[opt-out-committed]`。

精确源位置（95b23239）：`subscription_service.dart:918` 调用 notifyItems；`subscription_notification_service.dart:78` 进入桌面 backend；`windows_focus_notification_service.dart:154` 等待 provider 后没有重验，随后直接调用 client.show。因此这是原候选已有缺陷，不依赖 1.9 搜索、导出或其他功能。

## 最小修复范围

仅抽取 `080d505` 相对其父提交的四个通知生产文件差异，不复制完整 1.9 service 文件：

- `subscription_service.dart`：在通知 callback 的异步 Zone 中携带请求 guard，捕获 final generation/epoch，检查当前启用、通知许可、运行、未 dispose、存储和 focus 抑制状态。
- `subscription_notification_delivery.dart`：新建请求上下文，兼容原 notifyItems(List) API，并发与嵌套请求各自隔离。
- `subscription_notification_service.dart`：捕获调用时 guard，传给 Win/Linux 共用 backend；原 Android/iOS generation/background 参数保留。
- `windows_focus_notification_service.dart`：provider 就绪后、真正 client.show 前立即重验 guard；异常按拒绝处理。缺 guard 的直接调用和 focus 通知 API 保持原行为。

没有带入 SettingsTransfer 严格 1.9 搜索字段、文件夹/AB、统一导出、只读 SQLite 导出 API 或其他 1.9 代码。两个新增测试只导入原版 1.8 已有服务/模型、原版 Content fixture 和这次新增的通知 guard。

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 95b23239 原候选红例 | 已复现 | 原红 exit 1，提交 opt-out 后仍 show:new |
| 原红转绿 | 自动化通过 | 原 callback/断言保持，关闭提交后不投递 |
| Windows/Linux 分支与并发/focus | 自动化通过（Windows 宿主合成 client） | 总开关/通知/暂停/删除/focus/dispose、正常投递、两服务共享 provider、嵌套 guard、provider 错误和 focus API 兼容 |
| 原版订阅业务与 native generation | 自动化通过 | 既有 service/background/native background 测试全部通过 |
| 真机与发布 | 未做 | 不宣称 Linux native client、Apple 异步权限回调或设备验证已完成；由 1.8 发布者执行最终门禁 |

## 回归与交付证据

所有测试仅用合成数据、临时内存偏好和 fake notification client，不读取真实账号/用户存储，不弹真实通知。离线依赖准备 `flutter.bat pub get --offline` exit 0。

```powershell
& 'C:\Users\L1XU4N\flutter\bin\flutter.bat' test --no-pub test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart test/windows_focus_notification_service_test.dart test/focus_notification_service_test.dart test/subscription_service_test.dart test/subscription_background_test.dart test/native_subscription_background_test.dart
```

结果：**82 passed，exit 0**，含 20 项新增通知回归。

```powershell
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' analyze lib/services/subscription_service.dart lib/services/subscription_notification_service.dart lib/services/windows_focus_notification_service.dart lib/services/subscription_notification_delivery.dart test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart
& 'C:\Users\L1XU4N\flutter\bin\cache\dart-sdk\bin\dart.exe' format --output=none --set-exit-if-changed lib/services/subscription_service.dart lib/services/subscription_notification_service.dart lib/services/windows_focus_notification_service.dart lib/services/subscription_notification_delivery.dart test/subscription_notification_generation_test.dart test/subscription_notification_delivery_test.dart
```

结果：**No issues found，exit 0；6 files / 0 changed，exit 0**；git diff --check 通过。生产增删行与 `080d505` 四文件差异逐行比较，防止夹带其他整合改动。

交付 bundle 只选 `refs/heads/codex/v18-notification-backport`，不使用 --all，不排除祖先，完整包含精确 95b23239 及以前的历史。提交完整 SHA、bundle 路径、verify/list-heads、SHA256 与祖先校验结果由交付消息给出。接收者应先核对该 SHA 和祖先，再由唯一发布者决定是否合入；本分支不会自行改动实际 1.8 发布分支。
