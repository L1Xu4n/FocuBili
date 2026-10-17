# v1.8 焦点订阅验收

本任务覆盖用户 part1 的 1–14、16、28。工作分支 `codex/v1.8-subscriptions`，从 beta5 `a6c8334` 开发后，已重放到统一发布基线 `5e128bdd1952b3f619500f69aa7bc8c33a88d0b4`，保留 1.7.1 的认证、清晰度和更新忽略修复。没有合并或发布版本、读取真实登录数据、生成签名或修改系统权限。

## 逐项验收

| 原条目 | 实现 | 自动化证据 |
| --- | --- | --- |
| 1 | 消息封面宽度由行宽 28% 增至 32%，普通上限 152→172，首页紧凑上限 100→112 | 三种尺寸的 compact UI 用例与截图 |
| 2、3 | 消息内移除“收到日期”“未读”标签和重复播放按钮，卡片整体点击播放 | release UI / compact UI |
| 4 | 长按进入多选；顶栏替换为全选、标为已读、加入学习清单；全选仅作用于当前筛选结果 | release 多选、批量学习和已读用例 |
| 5 | 开启后台每小时检查后提示省电无限制、多任务加锁、自启动，并提供系统省电/自启动入口 | updates page 开关用例 |
| 6 | 首页“焦点订阅”下呼吸色“新增焦点订阅”；完整中文解释和两个指定选择；接受启用并跳设置、将首页卡片放第一且显示指定确认文案；拒绝不启用、不导航、不改布局 | release 的接受、拒绝、中断恢复、并发接受、真实首页重启用例；introduction 三张截图 |
| 7 | 点击来源打开 UP 主页或合集页，传递当前订阅服务及公开资料 | release 来源导航用例 |
| 8 | 长按来源多选，支持全选、批量暂停/恢复和确认批量删除，系统返回先退出多选 | release 来源批量用例；服务单事务、迟到结果用例 |
| 9 | 合集只检查默认/反向顺序的首两页，首尾各两页最多四次内容请求；首次静默基线；全量历史单独导入 | migration 首尾 80/100 条覆盖、尾部新增、中间未覆盖与历史导入用例；release 500 页预算用例 |
| 10 | Android 保留原生 WorkManager。Windows/Linux/Apple 只在启动、回前台及前台每小时检查；不宣称关闭/挂起后继续检查。系统通知使用各平台原生后端 | background/lifecycle/worker、平台通知通道用例；Android 原生编译与 JVM |
| 11 | 已读整体排在未读下面，以“已读”分隔；底部七天保留说明；按第一次 readAt 满 7×24 小时清理消息缓存 | release 精确边界、启动重开、CAS、批量已读；服务回归 |
| 12 | 按消息到达时间从新到旧排序，以本地日期“--20xx年xx月xx日--”分组；未读/已读分别分组。卡片仍显示视频发布日期；“今日发布”筛选仍按发布日期 | release 旧视频新到达顺序用例；截图 |
| 13 | 已订阅的 UP/合集按钮可再次点击，经确认取消焦点订阅；保留已有消息和学习记录 | updates page 订阅/取消用例；release 两类来源路由 |
| 14 | “我的”默认登记顺序中焦点订阅位于设置前。保留用户已有手动布局 | home customization 及默认登记表 |
| 16 | 合并通知标题为本轮最新消息的视频标题，副标题/正文首行为“来自UP或合集名”，多条时正文显示其他更新数量 | release Android/iOS/macOS 参数用例、Windows 通知用例；Android 编译 |
| 28 | 去掉播放/已读/学习进度说明，加入来源头像/合集缩略图横向筛选；仅未读到来源筛选区域上滑收起、下滑快速展开 | release 筛选与浮动吸附用例；窄屏/大字号/深色截图 |

批量加入学习清单沿用现有 `addBatch` 容量保护和去重，不重写已有学习进度。每个所选视频加入默认的第一个分 P；其他分 P 仍可在学习清单继续选择。读取详情失败或容量不足会显示结果，不会标为已读。

## 数据与迁移边界

- 保留快照 schema v2。合集 checkpoint 算法号升至 3，只重置旧自动全扫描的游标/覆盖标记；保留 seen、pending、消息 readAt、通知声明及独立历史任务。首次首尾基线不把旧内容推为新消息。
- 七天清理只删除消息展示记录，不删除去重索引、源、历史导入文件、笔记或学习任务。因此清除的旧消息不会重新推送。清理在启动、后续写入及进程运行时每小时执行；存储失败保持旧快照并报告错误。
- 已开启 beta 用户保留开关、来源、卡片顺序和隐藏状态，直接记作已有选择。未开启用户看到一次引导；接受先持久化 `enabling`，重启可重放未完成步骤；完成后不重复置顶，也不覆盖后续用户自定义顺序。
- 来源批量暂停/删除只提交一次事务与一代 generation，取消在途请求；旧响应不能恢复已删除来源。已有消息保留来源名称。来源被删后不会被不可见筛选条件困住。
- 合集支持自定义顺序，因此首尾检查不能保证捕获任意中间位置插入/任意重排。设置页明确说明；完整历史仍由用户主动导入。没有把四次请求冒充全量核对。
- 通知沿用一轮一条合并提示，避免大量更新造成系统通知洪泛。Android generation 和通知权限的原生事务校验保留。Apple/桌面本轮没有新增关闭进程后唤醒网络检查的机制。

## 验证与复现

最终结果见 [validation.json](validation.json)。本机 Windows 上完整订阅定向集合 105 项通过；Android 插件原生编译及 34 项 JVM 测试通过。之后对通知/生命周期保护条件做了 60 项定向复验，全部通过。静态分析、格式及 diff 检查通过。没有运行本仓库全量 Flutter 回归，也没有生成安装包；全量集成与发布交由发布负责人。

主要命令：

```text
flutter analyze --no-pub
flutter test --no-pub test/subscription_release_test.dart test/subscription_migration_test.dart test/subscription_updates_page_test.dart test/subscription_optimization_test.dart test/subscription_service_test.dart test/subscription_background_test.dart test/subscription_request_scope_test.dart test/subscription_worker_channel_test.dart test/app_subscription_lifecycle_test.dart test/subscription_history_page_test.dart test/subscription_http_integration_test.dart test/subscription_paging_probe_test.dart test/subscription_performance_probe_test.dart test/subscription_compact_ui_test.dart test/home_customization_test.dart test/windows_focus_notification_service_test.dart
flutter test --no-pub --dart-define=BETA3_CAPTURE_DIR=docs/reviews/v180-subscriptions test/subscription_compact_ui_test.dart test/subscription_release_test.dart
android/gradlew.bat :focubili_android:testDebugUnitTest --console=plain
```

12 张 PNG 是本机真实 Flutter 组件的虚构数据夹具截图，非设备实测或设计稿。包含 390px 常规、320px/180% 字号、1280px 深色的消息/来源/首页卡片，以及 390px 首次引导首页、弹窗和置顶卡片。缺少实际图片时展示占位图；这些截图不证明真实网络头像/封面已加载。已检查可读性和溢出。

## 尚需人工或平台 CI 验证

| 场景 | 操作与预期 |
| --- | --- |
| Android 覆盖安装 | 用发布负责人确认同签名的正式包覆盖 beta4/5，保留现有来源、暂停状态和已读；已有开启用户不被反复引导，不重置手动卡片布局 |
| 新版首次选择 | 在备用测试安装分别验证接受/拒绝；接受出现指定中文确认、跳设置、第一张订阅卡及快捷按钮，拒绝保持简洁首页；重启均无重复提示。不要为此清除用户真实数据 |
| Android OEM 后台 | 开启每小时检查，观察省电/自启动提示；按手机厂商设置后等待后台任务。真实通知标题为视频标题，来源副标题正确；强行停止后不承诺检查，重新打开恢复 |
| 合集与真实接口 | 大合集初次检查不持续全量核对；在正常/反向排序和首尾新增时确认可看到更新。任意中间新增不作保证，可主动导入历史；确认真实头像/缩略图显示 |
| 真机手势 | 窄屏及大字号长按消息/来源、全选、加入学习清单、批量暂停/删除；上滑筛选收起、下滑展开；单击卡片播放，单击来源跳转后可取消订阅 |
| Apple CI 与系统通知 | 在 macOS/iOS CI 编译更新后的 Swift 插件，并在真机/系统中确认权限、通知副标题、通知点击进入更新页。Windows 不能证明 Apple 原生编译成功 |
| Windows/Linux 桌面 | 在前台检查到更新时确认原生通知、禁用通知时列表继续工作；关闭或系统挂起后仅恢复前台检查，不承诺后台轮询 |

七天精确边界和跨实例写入冲突已经由注入时钟/存储用例覆盖，未通过更改用户电脑时间或真实数据进行测试。


原生后台追加实现及通知候选完整性验收见 [native-background/README.md](native-background/README.md)。原验证 JSON 保留交付时快照，不覆盖原来的验证结果。


## 公开分支的截图范围

本地生成的审查截图不随本公开分支上传。它们只保留在本机原始恢复分支和证据目录；文中的PNG文件名用于本地复现。应用代码和原有公开资源不受影响。自动审批拒绝了本地图像导出，未通过其他编码或引用方式公开被拒绝的图片。
