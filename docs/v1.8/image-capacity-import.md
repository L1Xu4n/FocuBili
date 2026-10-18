# 1.8 设置导入图片容量边界修复

基线为 PR #63 head `01250806d954fa360061e41a0580b31d8ae5dbb9`，对应讨论 `discussion_r4305665818`。工作在独立 `codex/v18-image-capacity-import` 分支；没有修改发布副本、1.9 集成树或 Beta bootstrap 分支。

## 已核实的兼容范围

- `ImageResourceCache.capacities` 是 UI 使用的 64/128/256/512 MiB 预设，默认 256 MiB。
- 底层容量允许 0 和小于上限的自定义值。0 会清除已落盘对象，并继续在线获取图片而不再存入磁盘；既有测试及旧设置可能保存小容量。这些值必须继续支持 schema 1 导出、解析、重导入和索引重开，不能收紧为仅四个 UI 预设。
- 设置迁移现在接受 **整数 0..536870912 bytes（含两端）**。上界直接从 `ImageResourceCache.capacities` 的最大值乘 MiB 推导；超界、负值和错误类型拒绝，不 clamp。

生产改动仅 `SettingsTransferService._validateValue` 的图片容量上界和对应 import。`parseSettings` 与直接 `importSettings` 已共用这个验证入口，并在任何偏好/runtime 读取写入前验证完整 map；保留原串行化、失败回滚及 reset 行为。`focubili-settings` / `schemaVersion: 1`、搜索阈值最大值修复、底层缓存 API 和原 2000 个对象淘汰策略不变。本补丁不扫描或主动改写旧缓存索引。

## 先红后绿证据

新文件 `settings_transfer_image_capacity_test.dart` 共 26 项。在原基线生产代码上，用正确的独立临时缓存目录执行，结果 **20 通过、6 失败**。失败仅为以下三个超界值各自的 parse / 直接 import 两条路径：

| 超界值 | 原行为 | 修复后 |
| --- | --- | --- |
| 536870913（max+1） | 被接受 | FormatException |
| 1073741824（1 GiB） | 被接受 | FormatException |
| 9223372036854775807（int64 max） | 被接受 | FormatException |

同一测试文件随后未修改断言，与相邻回归一起全绿。正向通过真实 `DeviceSettingsRuntimeAdapter`、合成订阅服务和临时 `ImageResourceCache` 验证 0、1、128 bytes、四个 UI 预设的 direct import → export → parse → import → 重开索引；容量必须原样保留。0 还验证清除已有对象、两次在线请求不落盘。

负向对每个非法值把有效普通偏好和运行期开关放在非法项之前，比较完整 SharedPreferences 快照、完整 runtime 快照，并断言 preferences loader / runtime read / runtime write 次数均为 0。覆盖负值、上表超界值、double、字符串、bool、list、map，以及 JSON null。没有改旧的 128-byte mock，也没有用真实账号或真实用户目录。

## 本机实际执行

Windows / Flutter 3.44.6 / Dart 3.12.2；依赖通过 `flutter pub get --offline` 使用既有缓存，pubspec/lock 无变化。

```text
flutter test --no-pub test/settings_transfer_image_capacity_test.dart --reporter expanded
# 原生产代码：20 passed / 6 failed（超界值复现）。

flutter test --no-pub test/settings_transfer_image_capacity_test.dart test/settings_transfer_search_threshold_test.dart test/settings_transfer_test.dart test/settings_runtime_adapter_test.dart test/settings_native_subscription_integration_test.dart test/image_resource_cache_test.dart test/cache_management_page_test.dart test/personalization_settings_page_test.dart test/settings_search_section_test.dart --reporter expanded
# 修复后：9 文件，82 passed / 0 failed / 0 skipped，runner 00:13，exit 0。

flutter analyze --no-pub
# No issues found，19.3 秒，exit 0。

dart format --output=none --set-exit-if-changed lib/services/settings_transfer_service.dart test/settings_transfer_image_capacity_test.dart
# 2 文件，0 changed，exit 0。

git diff --check
# 通过。
```

offline pub get 产生的七个 native plugin registrant 变化已在测试后恢复，未纳入补丁。现有 settings/runtime/cache 和搜索阈值测试文件均未改。没有运行全量、原生构建、设备安装、真实账号操作或任何远端写入；这些本地自动化不替代最终组合提交的 CI 和设备验收。
