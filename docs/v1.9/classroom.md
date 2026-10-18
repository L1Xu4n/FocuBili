# v1.9 beta：已购 B站课堂（#58）

验证日期：2026-10-17 UTC。实现分支：`codex/v19-classroom`。
初始基线 `5a49fc6`，开始修改前已快进到提供的 v1.8 整合基线 `5e128bdd1952b3f619500f69aa7bc8c33a88d0b4`。未修改 dev/master，未创建 PR、发布包或签名材料。

## 逐项状态

状态含义：未做、实现、自动化通过、真机通过、阻塞。自动化通过只代表对应固定数据和平台编译验证，不代表真实已购课程可以播放。

| 项目 | 当前状态 | 证据 / 边界 |
| --- | --- | --- |
| 官方 `cheese/play/ss`、`cheese/play/ep` 链接及分享文字 | 自动化通过 | 严格域名、路径、正整数和 64 位范围；拒绝伪装域名、userinfo、自定义端口和番剧 ep |
| `b23.tv` 展开后的课堂链接、Android 分享及深链入口 | 自动化通过 | 复用现有短链解析；manifest 增加课堂路径；无真实系统分享/设备验证 |
| 搜索框课堂链接直达、已购页手动打开链接 | 实现 | 搜索走统一 lookup；复用课堂目录和原生播放器 |
| “我的 → 已购课程”入口、当前账号分页读取 | 自动化通过 | 官方只读已购接口；空列表、过期、下架、重复分页、会话变化测试 |
| ss 目录及章节分页完整性、ep 精确选章 | 自动化通过 | 目录不完整或指定 ep 不存在时失败，不静默改播其他章节 |
| Android 课堂 DASH / 单段复用音视频播放接入 | 自动化通过 | NativePlaybackController 编译通过；JVM 编号策略和 Dart 通道验证；实际解码待真机 |
| Windows / 桌面课堂 DASH / 单段复用音视频接入 | 自动化通过 | 播放源、可信 CDN、音轨计划、会话变化测试；实际桌面课程解码未做 |
| 服务端权限拒绝、过期登录、试看、DRM 处理 | 自动化通过 | 不请求 UGC 或匿名备用接口，不提供游客继续；收到 DRM/试看/内层拒绝码时停止 |
| 同一会话已购证明、桌面账号切换撤销播放 | 自动化通过 | lookup 及两端每次 playurl 前验证官方 my/paid 目标课程；账号变更撤销候选，迟到 open 完成后停流 |
| 现有播放器选集、章节身份与暂停旧章 | 自动化通过 | 真实 PlayerPage 控件合成测试验证第二章携带正确 ep/avid/cid |
| 本机进度、学习清单、时间点笔记及重新打开 | 自动化通过 | 独立 `cheese:ss<season_id>` 键；章节 CID 各自持久化；统一 lookup 可重读课堂目录 |
| 手机 / 平板大字体的已购列表和登录失败页面 | 自动化通过 | 三张合成截图已目检，无溢出；390×844、1280×800/130% 字体 |
| 真实已购账号、安卓平板、Windows 课程播放 | 未做 | 本轮没有读取真实 Cookie、购买记录或付费媒体；由账号所有者按下文检查 |
| DRM、多段 durl 拼接、课堂独立字幕与弹幕 | 未做 | 显示明确不支持说明；视频内嵌字幕不受影响；需要官方受保护能力时使用官方课堂 |
| 课堂离线下载、磁盘媒体缓存、官方学习进度同步 | 未做 | 本版不提供课堂离线下载；课堂仅内存缓冲；不写官方观看/学习状态 |

代码整合无已知阻塞。真实账号和真机验证未执行，不能标为“真机通过”。

## 参考 fork 评估

需求来源：[上游 issue #58](https://github.com/L1Xu4n/FocuBili/issues/58)。作者留言明确仅在自己的安卓平板测试通过，尚未全面验证且没有提交 PR；这是参考证据，不是本版本测试结论。

锁定评估的 fork head：[`5e59f1a7ee61bb4a54b3d067edd869b86c87a01d`](https://github.com/Zeeo2440/FocuBili/commit/5e59f1a7ee61bb4a54b3d067edd869b86c87a01d)。原生课程核心提交：[`e5c0cd11febc61056098be5964e69b6867c42cb7`](https://github.com/Zeeo2440/FocuBili/commit/e5c0cd11febc61056098be5964e69b6867c42cb7)。通过只读 GitHub connector 检查固定提交的源码、差异、目录树与测试，没有向 fork 写入。

参考并改写了课堂接口、分页模型、`cheese:ss` 命名空间、CoursePlaybackTarget 及基础固定数据测试。可取之处：真实 ep/avid/cid 独立传递，使用专用课堂 playurl，不将 ss/ep 伪装为 BV，权限交给服务端。

未直接合并 fork。其原生实现基于另一版播放器，缺少当前整合基线的缓存表示身份；课程页限 Android，缺少 Windows 完整播放接入。本实现保留当前基线的请求代次、会话门控与轨道策略，补充桌面课堂播放、复用音视频的音轨处理、整章身份校验、去重分页完整性、登录失败页面、跨尺寸 UI、缓存隔离及回归证据。

## 实现与账号边界

- 目录：`/pugv/view/web/season`；超过首批目录时从 `/pugv/view/web/ep/list` 第 1 页重新完整加载、按 ep 去重。课程编号不匹配、目录不完整或找不到指定章节时不播放。
- 已购：`/pugv/pay/web/my/paid`，仅在用户打开/刷新已购页后读取当前会话。使用单次内存会话快照，分页中及发布结果前复核；没有持久化购买清单。退后台清空页面列表，回前台或课程/登录页返回后重读。
- 播放：`/pugv/player/web/playurl`，传真实 `avid`、`ep_id`、`cid` 和所选清晰度；Referer 为该章节官方页面。lookup 和 Android/Desktop 每次请求 playurl 前，都用本次同一 Cookie 从官方 `my/paid` 确认目标 season 已购、未过期、未下架；不保存其他购买资料。未购或无法确认时不请求 playurl，免费整章也不能作为已购证明。`paid_access` 显式非 1/true 时拒绝；字段缺失时仍必须有上述购买证明、code 成功且非试看，不假设未知字段可以授权。课堂不使用 UGC WBI 或游客回退。每次选章、切清晰度、重新打开都重新请求播放授权。
- 身份：VideoPreview 存 season，VideoPart 存 ep/avid；本机进度、观看历史和笔记复用现有服务，用独立课程键 + CID。显式 ep 链接优先该章，ss 链接沿用现有续播策略。从学习清单、历史、笔记打开会重新读目录及授权。
- HTTP 只发送到固定官方 HTTPS API，禁重定向携带 Cookie；媒体仅允许现有可信 B站 HTTPS CDN；媒体请求头不向 CDN 带 Cookie。异常不回显课程接口正文、Cookie、临时媒体地址或任意远端 message。
- Android 保留原生 SessionGate 发布前校验；桌面播放源返回前复核当前 Cookie，并在整个打开/备线/播放期间绑定 CacheLifecycle 账号代次。账号变更立即使请求失效、清空课堂候选并停止流；若 open 已在执行，停流等待该 open 完成，新的打开等待旧 stop。切普通或本地 UGC 时清除课堂归属，避免误停无关媒体。这些竞态已用 Completer 和实际 fake 媒体调用验证，真实设备的停流时机仍待人工验证。
- 学习清单本来就要求精确 CID；课堂笔记与专注书签也增加缺 CID 拒绝和重新选择提示，目录重排不能让旧时间点落到另一章。普通 UGC 继续使用既有兼容策略。
- 不显示课堂 UGC 点赞/投币/收藏按钮，不做账号写操作。课堂离线按钮隐藏；Android 使用直连内存缓冲、Windows 禁用磁盘 packet 写入且采样器不能重新开启。既有进度、笔记属于本机记录，不会自动同步官方课堂。

## 自动化与平台证据

运行环境：Windows，Flutter 3.44.6 / Dart 3.12.2，使用 `C:\Users\L1XU4N\flutter\bin` 现有 SDK；Android 使用现有 SDK 和 Android Studio JBR。离线 `pub get` 因本机缺少 media_kit_libs_linux 缓存失败，随后普通 `flutter pub get` 成功，未升级 lock 中依赖。SDK/cache 操作使用正常构建授权，没有修改 ACL。

1. `flutter analyze --no-pub`：最后一次 **No issues found**。
2. 第一轮 `flutter test --no-pub test/bilibili_course_service_test.dart test/classroom_access_test.dart test/course_learning_records_test.dart test/desktop_playback_source_service_test.dart test/native_playback_service_test.dart test/windows_dash_media_plan_test.dart test/desktop_disk_cache_session_test.dart`：**41 tests passed**。
3. 第二轮（含截图）`flutter test --no-pub --dart-define=CLASSROOM_CAPTURE_DIR=docs/v1.9/classroom-evidence test/classroom_page_test.dart test/classroom_access_test.dart test/bilibili_course_service_test.dart test/course_learning_records_test.dart test/desktop_disk_cache_session_test.dart test/bilibili_deep_link_service_test.dart test/playback_resume_plan_test.dart test/profile_customization_test.dart test/windows_playback_audio_lifecycle_test.dart test/windows_playback_progress_store_test.dart`：**61 tests passed**。两轮存在重叠，不可相加为独立测试总数。
4. 补充实际选集组件和两章进度持久化后：`flutter test --no-pub test/classroom_page_test.dart test/course_learning_records_test.dart`：**4 tests passed**。
5. Android 目录中最终运行 `gradlew.bat :app:testDebugUnitTest --tests 'com.focubili.app.Course*Test' --no-daemon`：**BUILD SUCCESSFUL，5 tests，0 failures，0 errors**（Target 2，PurchaseGate 3）；包含 `:app:compileDebugKotlin` 和 `:app:compileDebugUnitTestKotlin`。仅编译/JVM 测试，无打包、安装、签名或发布。现有第三方插件的弃用/unchecked cast 警告未在本功能范围修改。
6. `git diff --check`：通过。
7. `flutter test --no-pub test/classroom_reopen_test.dart`：**2 tests passed**。真实学习任务序列化/重载后经统一 lookup 恢复课程 season/ep/avid，并由 LearningVideoLauncher 携带 CID/47 秒；笔记详情真实来源卡点击后经统一 lookup 打开正确课程章节和时间。
8. 审核后购买校验、账号栅栏和章节失效回归：`flutter test --no-pub test/classroom_access_test.dart test/classroom_reopen_test.dart test/classroom_account_race_test.dart test/classroom_page_test.dart test/course_learning_records_test.dart test/desktop_disk_cache_session_test.dart test/windows_local_source_resume_test.dart test/focus_video_launcher_test.dart test/video_notes_page_test.dart`：**47 tests passed**。
9. 最终桌面栅栏回归：`flutter test --no-pub test/classroom_access_test.dart test/classroom_account_race_test.dart test/windows_source_identity_race_test.dart test/windows_local_source_resume_test.dart test/listening_playback_test.dart test/windows_playback_audio_lifecycle_test.dart`：**34 tests passed**。覆盖已拿到地址但未 open、in-flight open 晚到、备线前切号、已播放时切号、课程转本地前后切号、排队 stop 不取消较新请求、普通 UGC 行为；购买测试覆盖后续页、未购/过期/下架时 0 次 playurl、lookup 空购买列表不发布、购买检查期间切号。
10. 最后将章节失效提示透传后：`flutter test --no-pub test/classroom_reopen_test.dart test/video_notes_page_test.dart test/focus_video_launcher_test.dart`：**15 tests passed**，课堂缺 CID 不按页码/首章兜底，笔记显示重新选择说明，普通笔记及专注恢复仍通过。

JVM XML 原始结果在本机构建目录 `build/app/test-results/testDebugUnitTest/TEST-com.focubili.app.CoursePlaybackTargetTest.xml` 和 `TEST-com.focubili.app.CoursePurchaseGateTest.xml`（构建产物不提交）。独立验证摘要见 [classroom-validation.json](classroom-evidence/classroom-validation.json)。

截图仅用合成课程和合成过期会话，未连接账号：

- [手机已购列表](classroom-evidence/classroom-purchased-mobile.png)
- [平板 130% 字体](classroom-evidence/classroom-purchased-tablet.png)
- [手机登录过期](classroom-evidence/classroom-login-mobile.png)

## 账号所有者人工测试步骤与预期

1. 在自己的设备正常登录已购买课程的 B站账号，进入“我的 → 已购课程”。预期课程来自当前账号，过期/下架条目明确禁用；未登录显示登录与重试，网络失败不会伪装为空列表。
2. 粘贴自己的 `ss` 链接、指定 `ep` 链接、分享文字和 `b23.tv` 短链。预期进入完整目录；ep 必须打开指定章，ss 根据本机既有续播恢复。普通 BV/AV、番剧及外站输入行为保持原有规则。
3. 在有权限的一章播放至少 45 秒，记一条时间点笔记；切下一章，再返回原章。预期旧章先暂停，新章使用独立进度和笔记；从观看记录/学习清单/笔记重新打开应重新授权并回到相应 CID/时间。
4. 快速连续切章、切清晰度，再尝试失败重试、旋转、全屏和暂停。预期迟到请求不覆盖最后一章；课程音视频同步且不会出现“有画面无声”假成功。单段课程不显示独立省流音轨支持承诺。
5. 使用本人无权限、已过期或已下架的课程链接。预期明确权限/过期/不存在提示，不请求普通视频接口、不游客回退、不改播第一章；试看数据不能冒充完整已购播放。
6. 若自己的课程返回 DRM 或多段 durl，预期明确提示不支持并使用官方课堂。不要修改接口参数、内容字段或凭据来尝试绕过该限制。
7. 退出后登录本人另一个账号（如有），返回已购页并重开课程。预期列表重新读取，新账号无权限时不能播放；无需向维护者提供 Cookie、token 或完整购买清单。
8. Android 手机/平板和 Windows 分别检查上述流程。记录设备、系统、课程媒体类型、非敏感错误码及步骤即可；截图避免暴露账号资料与课程隐私。将本表相应条目标为真机通过需附这些实际证据。

## 整合注意

本提交对 profile、router、app、search 只有入口和直接解析小改；与抽屉/导出/筛选分支合并时保留这些入口。notes/subtitles 分支可能同改 player_overlay_coordinator：保留 `_loadSubtitleTracks` 和 `_loadDanmakuSegment` 的课堂 guard，新增的字幕正文回调也应在课堂返回 unavailable，避免传课程存储键给 UGC 字幕接口。

核心播放文件包括 video_preview.dart、native_playback_service.dart、desktop_playback_source_service.dart、windows_playback_service.dart、NativePlaybackController.kt、CoursePurchaseGate.kt 和 DesktopDiskCacheSession。notes/focus launcher 的课堂缺 CID guard 也需保留。购买证明最多读取 100 页、每页 10 条；超过这个上限或响应结构变化会保守拒绝，不能将测试结果作为真实接口永远兼容的保证。整合后仍需跑统一静态分析/测试，真实平台发布前按上文补齐账号人工验证。
