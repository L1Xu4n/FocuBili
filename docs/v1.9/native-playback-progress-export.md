# Android 原生逐 P 进度的统一导出

基线 `dad5d2dbb716c2b284a92e632e6293309b1761d2`，独立分支 `codex/v19-native-progress-export`。这项补齐 Android 独立原生进度存储；Windows 原有 preferences 进度导出保持原逻辑。没有修改播放、续播、跨 P 或课堂鉴权/恢复路径。

## 内容与调用范围

仅在真实平台为 Android 且用户选中“观看与搜索历史”时，统一包附加 `native_playback_progress.json`。未选历史及所有非 Android 平台不调用该通道。独立可注入 loader 不要求现有 PlaybackService/Fake 增加方法。

窄接口为现有 playback channel 的无参数 `exportSavedPlaybackProgress`。固定读取本应用 `shared_prefs/focubili_playback_progress.xml` 和同名 `.bak`，没有可由 Dart 指定的文件路径，不访问其他偏好、账号、安全存储或网络。

结构：`format=focubili.native-playback-progress`、`version=1`，以及以下两个数组：

| 数组 | 严格允许的字段 | 说明 |
| --- | --- | --- |
| `lastParts` | `bvid`、`cid`、`pageNumber` | 每支视频最后选中的分 P；CID 为正 long、页码为正 int |
| `parts` | `bvid`、`cid`、可选 `positionMs`/`durationMs`、可选 `savedAtMs` | 保留全部已存 CID，位置与时长必须成对；仅更新时间的清除记录也保留 |

身份只接受合法 BV 或课堂 season 身份；BV 前缀严格限定 `BV`/`Bv`/`bV`/`bv`，完整保留原始 BVID，不改变主体大小写或归并不同前缀的历史键。原生 `cheese:ss...` 在文件中规范为 `CHEESE:SS...`，季号不溢出 native long。没有把末次页码复制到其他 CID，也不把缺失位置/时长伪造为 0。没有 URL、请求头、Cookie、token、账号或 session 字段。普通未识别偏好键不导出；`progress:`/`last-part:` 命名空间中的未知格式、字段或坏值会阻断整包，避免部分成功。

## 纯读和故障边界

原有 `loadSavedPlaybackPosition`/`loadSavedVideoState` 会清理部分记录，导出没有调用它们。也没有调用 `edit`、`apply`、`commit`、恢复、rename、删除或强制 flush。读取的是已提交文件快照，不包含尚未落盘的异步 apply 内存状态，不是实时播放位置；各服务读取时点不同，并非全局事务快照。包内 README 同样说明此边界。不承诺完整恢复或新增导入。

`.bak` 存在时只读优先快照，符合原生正在写入时保留旧提交的语义；不把备份恢复成主文件。仅检查主文件和备份都不存在时允许空文档；空文件、截断、目录冒充文件、已选中文件消失、坏备份或读失败均报错，不回退成空或跳过损坏记录。主文件/备份切换、首次 apply 落盘竞争可能导致本次失败，稍后重试；不为提高成功率修改存储。

XML 在解析前做严格 UTF-8 解码并拒绝 DOCTYPE、ENTITY 声明及所有 `&` 实体引用（含预定义转义；当前数字进度与合法身份不需要它们），拒绝非 UTF-8 声明。使用基础 SAX 接口，不设置 Android API 24 与 JDK 支持不同的可选 factory 安全 feature；实体解析回调另行一律拒绝。XML 中的外部资源不会被加载。结构、数字类型、重复键、未知存储标签及嵌套错误会失败。

原生失败固定为 `progress_export_failed` / `Android playback progress is unavailable.`，details 为 null，不记录或返回 XML、偏好键值、路径、底层异常。Dart 对原生错误使用静态消息，对版本、字段、类型、身份和重复记录再次严格校验；注入 loader 也不能绕过白名单。

## 历史兼容证据

- `acbdd7e`（v0.2.0）引入相同 `progress:<bvid>:<cid>:position/duration` 和 `last-part:<bvid>:cid/page` 格式。写入即拒 CID≤0、页码≤0、duration≤0；TIME_UNSET 和 0 时长不会保存。没有发现合法 CID=0 或另一套旧 key 写入。
- 旧写入可能保存 position=0，且早期没有更新时间；导出保留 0/正时长的合法 pair，并允许无时间戳。不会套用续播时的“过短/近片尾清理”规则。
- `be988f8` 加入 `updated_at` 及清除位置后的仅时间戳记录；这些记录保留为 `savedAtMs`，不制造位置。

## 状态与验证

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| Android 平台和 history 范围、实际 ZIP 内容、跨 P/课堂/清除记录 | 实现；自动化通过 | 合成 MethodChannel 与真实 UnifiedExportService 包内容测试 |
| 未知字段、坏值、重复/缺失数据、通道错误阻断 | 实现；自动化通过 | 有效记录与坏记录混合仍整包失败，错误不含合成私密标记 |
| XML/备份纯读、截断/消失/实体拒绝、旧格式兼容 | 实现；主机 JVM 自动化通过 | 15 项合成 map/XML/临时文件测试，未读取真实进度文件 |
| Android API 24+ 真机、实际 SAX/文件系统及写入并发 | 未验收 | 当前仅 Windows 主机编译、JBR JVM 和 mock Android channel |
| 真实账号/真实课堂导出 | 未执行 | 未启动 App，未读取真实用户数据 |

命令（Flutter 3.44.6 / Dart 3.12.2；现有 Android Studio JBR）：

```powershell
& C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
& C:\Users\L1XU4N\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/services/native_playback_progress_export.dart lib/services/unified_export_service.dart test/native_playback_progress_export_test.dart
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/native_playback_progress_export_test.dart test/unified_export_service_test.dart test/unified_export_page_test.dart test/settings_runtime_adapter_test.dart test/classroom_integration_test.dart test/classroom_account_race_test.dart test/windows_playback_progress_store_test.dart
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
# android/ 下执行，只编译与主机单测，不打包 APK
.\gradlew.bat :app:compileDebugKotlin :app:testDebugUnitTest --tests com.focubili.app.NativePlaybackProgressExportTest --tests com.focubili.app.NativePlaybackProgressStorageTest --no-daemon
git diff --check
```

初次交付 `23249a6` 的结果：Dart 定向兼容 80 项全部通过，其中 Android channel/ZIP/故障/范围/旧格式测试 39 项；静态分析 0 问题，3 个修改过的 Dart 文件格式检查 0 变化。Kotlin 编译通过，JVM 导出 helper 7 项与 XML 存储读取 6 项（共 13 项）全部通过、无失败/跳过；正常 Gradle 命令成功，44 秒，编译任务命中前轮成功缓存。`git diff --check` 通过。

早期记录：Dart 首轮 38/兼容 79 项与最终轮次重叠，不相加。离线 Gradle 因项目已有 `androidx.test:runner:1.2+` 缺离线版本列表失败，是依赖解析失败；未据此判断源码测试。正常解析既有 Maven 依赖后 Kotlin 编译通过。首轮 JVM 12 项中 1 项夹具的 page 被 Kotlin mapOf 推断为 Long，修为真实 putInt 类型并追加旧版用例后最终 13 项通过。没有安装工具/SDK、接受新 license、生成签名或 APK。

## 人工验收步骤与预期

1. 使用可丢弃的测试安装/测试资料，打开至少两个分 P 的公开视频，分别播放、暂停并等待原生落盘；勾选 history 导出。预期 ZIP 同时有原 history 文件与 native 进度文件，各 CID 独立，lastParts 仅记最后一 P，位置与时长没有串章。
2. 只在本人已经拥有权限的课堂测试资料中重复前一步；预期季号命名空间和章节 CID 保留，导出没有鉴权、流地址或请求头。此步骤不能用于获取未购内容。
3. 取消 history、改为导出其他分类；预期没有 native 进度文件或该通道调用。Windows 导出仍包含原 Windows preference 进度，没有 Android 文件。
4. 仅在隔离测试安装中注入合成主 XML/备份：两文件不存在、只有主文件、只有备份、两者并存、坏备份、截断、实体及选中文件后消失。预期仅真正无文件可为空；备份优先不改文件，其余故障整包失败且不出现部分 ZIP或原始错误内容。
5. API 24 与较新 Android 上核对 UTF-8 SAX、课堂/跨 P 正常续播、异步 apply 与导出竞争；竞争可失败后重试，不得为导出修改原生存储。导出前后正常续播行为应相同。

## 独立审查后的 BV 前缀兼容修复

独立 reviewer 发现一个确定 P2：`acbdd7e` 起原生 `BVID_PATTERN` 为 `(?i)^BV...`，当前 Dart NativePlaybackService 也以 `caseSensitive:false` 验证，`openVideo`/`openLocal` 只 trim，原生 `currentBvid=bvid` 后直接拼入进度键。合法小写/混合前缀因此可以持久化，而初次导出仅认大写 BV。独立合成 JVM 复现为原 13 项通过、追加前缀用例在 projection 处失败；未读取真实文件。

追加修复只把 Kotlin 与 Dart 的前两字母限定为 `[bB][vV]`。不把整个 BVID upper、不改正常续播写入、不合并同主体的不同前缀存储键。新增实际 NativePlaybackService 打开合约（mock channel）、真实 Unified ZIP 多别名同 CID 共存与主体大小写保持，以及非 BV 前缀拒绝回归；JVM 同时检查 projection 与 XML 路径。

最终追加验证仍使用上面的准确命令：Dart 定向兼容 **84 项全部通过**，其中本模块 **43 项**；analyze **0 问题**，3 个 Dart 文件 format **0 变化**。Android 正常 Gradle 在作者独立树成功，**1 分 2 秒**，`:app:compileDebugKotlin` 和单测编译实际执行；JVM helper **8 项**、XML **7 项**，共 **15 项通过、0 失败/跳过**。不同轮次不相加。此主机编译/JVM 证据不等于 Android 设备验收；reviewer 的独立 Android 构建被既有 file_picker namespace 配置阻塞，不能据其纯 JVM 通过宣称平台编译成功。作者未修改 Pub cache、SDK、根工作树或正常播放恢复。
