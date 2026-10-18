# 1.8 订阅原生后台追加补丁

基于 `07825790e4173ba0ca014b6e64e4af734dd29bf9`，独立分支 `codex/v1.8-native-subscription-background`。原已交付的 `13bf631`、`0782579` 不重写。本目录补充原始 part1 第 10 条，并修复整合验收发现的通知候选与 500 张展示上限耦合。

## 平台能力

| 平台 | 已实现的原生调度 | 明确边界 |
| --- | --- | --- |
| Android | 既有 WorkManager 周期任务 | 系统可能延后；保留原有实现和省电提示 |
| Windows | 当前窗口进程的 Win32 SetTimer / WM_TIMER | 失焦、最小化继续；进程退出、休眠、挂起后不保证 |
| Linux | 当前 GTK 进程的 GLib timeout | 失焦、最小化继续；退出、休眠、挂起后不保证 |
| macOS | 当前进程 main queue 的 DispatchSourceTimer | 失焦、最小化继续；退出、App Nap/挂起、休眠时不保证 |
| iOS | 启动时注册 BGAppRefreshTask；系统机会到来后启动无界面 Flutter 引擎 | earliestBeginDate 为一小时以后，**不是每小时保证**；禁止后台刷新时降为前台；用户强退后需重新打开 |

所有后台开关仍默认关闭。桌面不安装计划任务、开机启动或辅助常驻进程；不保持音频来规避系统策略。系统/原生桥不可用时保留前台检查；保留已存开启意愿并允许关闭，系统能力恢复、回到前台时重新协调。

## 生命周期与迁移

- 桌面失焦/最小化仅在明确启用原生后台检查时保留当前检查；关闭后仍停止前台轮询之外的检查。原生定时回调与前台检查共享同一服务和防重入轮次。
- 原生配置串行执行。关闭功能/通知、暂停/删除来源等操作先使原生旧任务失效，再提交新策略，最后重新协调。Dart 拒绝已关闭或旧 generation 的迟到回调；iOS 通知还核验该引擎捕获的独立 run token，避免旧引擎误用新轮次权限。
- iOS Dart 工作预算最多 20 秒，原生 watchdog 25 秒，系统 expirationHandler 可更早中止；取消请求并单次结束系统任务，销毁无界面引擎。结果独立保存在原生 lastRunStatus，下一次安排不会覆盖上次到时/失败状态。
- 无界面入口不运行主界面、播放器、剪贴板监视或专注计时器；只读专注状态，活跃专注时抑制通知。插件注册跳过 UI 的通知代理、远程媒体命令、应用代理和网络监视接入。
- iOS 从旧 SharedPreferences 订阅快照无损迁至 `subscriptions_v2.db`，与前台共用既有 SQLite CAS、短原生提交和可过期租约。旧快照/备份保留，数据库成为权威源；历史导入及学习数据独立保留。Android 存储方式不变，桌面保持当前进程单实例存储。
- **整合边界**：统一导出/重置若包含订阅，应读取/操作服务的当前 SQLite 快照，不能只回写或导出旧偏好快照；这个限制 Android 已存在，本补丁使 iOS 同样适用。未实际导出用户登录或订阅数据。

## 通知事务与展示缓存

扫描每页成功提交 CAS 后，返回该页完整新增项元数据，汇总到本轮临时通知候选；不从 500 张展示缓存反向重建候选。认领/去重仍先持久提交，再按最新已读状态分发；系统消息继续聚合为一次标题/来源提示，计数来自完整候选。

已读操作同时持久记录该事件的通知抑制，避免卡片随后被展示上限淘汰而丢失抑制。七天清理不删除 announced / notificationClaims 去重信息；独立历史导入不会成为实时通知候选。元数据只在当前轮次保留，不写入旧快照或引入第二套历史记录。

新增真实适配器夹具验收：单轮 1000 条新增，展示仍为 500，notifyItems 收到 1000 个不同 BV 和来源、持久认领 1000，重复检查不再分发；扫描中将一条标已读并让后续页面淘汰它，另外 999 条完整分发，七天后清理及再检查仍不重复。也保留既有跨多轮突发、历史导入不推送回归。

顺带修复自动 no-op 检查与紧接的手动检查竞争：手动请求会在当前自动轮次后完成一次手动核对，不被共享 Future 吞掉。

## 验证与 CI

本机实际结果和命令见 `validation.json`。Windows 原生代码与独立探针已编译；没有在用户电脑启动原生探针、发送真实通知、读取账号或创建计划任务。Dart 协议/服务/界面测试使用合成数据与模拟通道。

平台工作流新增：

- Windows / Linux / macOS：编译独立原生入口，验证真实定时回调、generation 替换和取消；取消检查统计原始通道消息，不会被 Dart 层过滤掩盖。先打包/上传正常应用，再编译探针，避免分发探针包。
- Apple：编译运行纯 Swift run gate，覆盖重复启动、取消、过期/完成单次归属、旧 token 不借用新轮次。
- iOS 模拟器：验证启动注册、取消方法桥接完成及**真实无界面引擎 bootstrap/ready/complete**。没有先提交待处理请求，因此不将取消方法成功返回当作 OS 队列删除验证。它复用生产引擎初始化顺序，使用独立探针入口；未覆盖生产 worker 的 libraryURI、SQLite 初始化/迁移或中途销毁。对应诊断方法仅编入 DEBUG 模拟器，设备/发布构建排除。探针没有订阅存储、网络或通知操作。该流程不声称模拟器获得了真实 BGAppRefresh 机会。

Apple / Linux 原生编译、上述平台探针及真实系统机会均须等对应 CI/真机结果；本机 Windows 不能替代这些验收。全仓测试若仍有诊断版本回退失败，属于当前隔离基线的 `1.8.0+22` 对 `pubspec 1.8.0+25` 不一致，由全局元数据负责人整合修正；不隐去失败、不改本任务之外的版本逻辑。

## 人工/平台待验

1. 桌面明确开启后最小化/切到其他程序，检查一小时后真实更新与通知；退出、休眠及重开行为符合界面描述。
2. iOS 签名真机包检查系统分配的后台机会、系统终止本轮、前台回读新数据及状态；禁止后台刷新仍可前台检查和关闭开关；强退后重开恢复。
3. iOS 前台与无界面工作重叠时修改开关、暂停/删除来源、标已读，确认无旧源消息复活和重复通知；旧数据首次迁移后重启继续可见。
4. 各平台真实通知标题是视频标题、来源副标题准确；活跃专注期间不发提示。Android 厂商电池策略仍需真机确认。

## 官方依据

- [Apple：Using background tasks to update your app](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)
- [Apple DTS：iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525)
- [FlutterEngine 嵌入 API](https://api.flutter.dev/ios-embedder/interface_flutter_engine.html)
- [Flutter 引擎源码：run 之前禁止安装原生消息处理器](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine.mm)
