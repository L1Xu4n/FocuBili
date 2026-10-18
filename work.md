

## 2026-10-13：Android v1.7 360P 问题隔离调查与修补（24a95b1 阶段记录）

> 本节保留首次修补的历史证据。后续边界审查发现会话合并和解码支持问题；24a95b1 不作为用户测试版本。当前结果以文末本地复核修正记录为准。

- 用户确认 Android / v1.7 正式版，尚未确认是否所有视频。修补分支 `codex/fix-v170-playback-auth` 从原始 v1.7.0 标签提交 `4a99e44efeb2ad2b374e3cb6c3d296b61558eed6` 创建；正式 Android APK 于 2026-10-02 上传，发布说明确认后续 Apple/Linux 更新没有替换它。未将 Beta5 合入修补分支。
- 比较 dev `dcb9368f7cb905b6d2723eb72a2912081d2775df`、Beta5 `a6c83343a6bfbeb5378e89558617414fa1935823`：同样存在登录合并 www/api/passport Cookie、Android 播放只读 www 且读失败静默使用空字符串的不一致。以合成域容器编译原有 CookieController 和提取的原生播放方法，复现登录有会话、播放无会话；修补后两端复用同一策略，读取异常明确失败，不再伪装成匿名请求。
- 原生轨道评分可让 360P AVC 压过请求的 1080P HEVC，且仍上报接口 `quality=80`。原方法合成复现：requested=80 / returned=80 / selected=16 / reported=80；修补后 selected=80。现在先满足目标上限内最高档位，同档继续优先 AVC；上报实际选中轨道编号。清晰度回退不再一律提示大会员问题。
- 使用新媒体缓存键命名空间和实际选中档位，避免误标旧缓存继续污染播放；不清除用户会话、笔记、观看记录或离线文件。旧媒体字节交给既有 LRU 回收。
- 新增每次 playurl 请求独立诊断：request_id、wbi_enabled、wbi_signed、wbi_fallback、playurl_attempted、session_read、auth_state、requested_quality、returned_quality、selected_quality、stage、outcome、api_code、http_status。WBI 开关来自本次请求快照；从未自动回退无签名接口。仅实际 nav 验证成功时标记 authenticated，Cookie 存在本身为 session_present_unverified，游客/过期/未知分别记录。成功但低清的响应也记录。
- 诊断入口采用类型、范围、固定枚举白名单；未知键及动态内容被丢弃，不接收 Cookie/token/签名 URL/响应正文。记录最多 20 条；扩充单条安全字段上限至 16。同一 Dart isolate 的多服务实例写入及清空串行化，防止紧邻的请求和播放错误记录互相覆盖。导出脱敏回归通过。
- 网络边界隔离测试使用真实提取的请求/解析/轨道方法和原 WBI 签名器，替换 CookieManager、Android Uri 与网络/JSON 输入。WBI 关闭 1 次 playurl；开启首次 1 次 nav + 1 次 playurl，缓存后额外 1 次 playurl、0 次 nav。覆盖匿名签名、会话过期、已认证但服务端仍返回低清，以及签名失败/Cookie 读取失败不回退、不发送 playurl。没有访问真实 B 站账号。
- 最终验证：Flutter 全套 673 passed / 1 skipped；Dart 定向（请求诊断、诊断页面、诊断存储、原生通道、WBI）30 passed；Android JVM 27 passed / 0 failures / 0 errors；flutter analyze 无问题；git diff --check 通过。测试在 Linux 云端完成，不是 Android 真机验收。
- 尚不能把已复现缺陷认定为这位用户的根因。若界面确实显示 360P，优先排查播放请求会话和服务端实际返回；轨道评分缺陷通常表现为画面低清但显示更高档位。还需公开视频 BV/链接、手动选择 720P 后的结果、同账号同视频在官方客户端的结果；不索取 Cookie、密码或 token。
- 安装交付限制：本地无正式签名配置；GitHub 集成无权列出仓库 secret 名称（HTTP 403），未读取凭据、生成新凭据或改动签名/应用 ID/版本。未运行正式发布。dev 后续移植需适配 CookieController 已迁入 `packages/focubili_android` 的模块边界，不能把本修补当成 Beta5 整体合并。
- 云端复现脚本及原始日志：`/workspace/scratch/focubili-360p-investigation/`。`reproduce.py`（原版）与 `reproduce.py --fixed`（修补版）、`request_harness.py` 均只使用合成输入；`cross-version-code-check.json` 记录跨版本代码核对。


## 2026-10-13：会话边界与设备解码复核修正（仅本地）

- 按后续授权只进行本地修复、回归、独立审查和本地 commit；不推送、不触发 CI、不交付安装包、不创建 PR、不合并 dev/master、不发布。工作树 `/workspace/FocuBili-v170-playback-fix`，分支 `codex/fix-v170-playback-auth`，本轮基线 `24a95b1bca2bb7b4b394a14be30d722036601121`。Beta5 和 dev 均未改动。
- 先添加会话边界回归，在旧实现运行 7 项，其中 5 项失败，证实跨账号逐字段覆盖、冲突会话后写覆盖、缺失身份字段从其他域借用、单域失败丢弃完整快照及单头重复会话问题。日志 `boundary-red.log`。复核后进一步收紧部分失败策略，回归断言按最终策略调整。
- 读取现在区分完整会话、确认匿名、读取未知、身份冲突和切换中。只采用单个域完整快照，不跨域补齐身份字段；可读域存在不同会话或身份值时拒绝采用。全部读取正常时优先 API 域，之后为 www/passport。部分域失败时仅允许 API 域自身的完整会话，其他域残留不能代替不可读/空的 API 域；诊断标为 partial。枚举全部 7 种非空失败域组合，覆盖单域/双域/全域失败。
- 确认匿名照常播放。UNKNOWN 不自动降为游客：页面显示“仅以游客播放本次视频”，只有明确点击才发起不带 Cookie 的请求；此选择不写磁盘，重新打开或重试视频回到默认会话流程。冲突/切换不显示游客按钮。离线打开也清理旧游客选择和入口。诊断新增 `guest_selected`、`codec_fallback` 两个布尔字段，共 16 个受白名单约束的字段，不持久化会话代次或身份值。
- Cookie 写入期间的代次门控拒绝半写入快照并作废旧请求/游客选择。HTTP 返回后重新观察 WebView，解决网页端切换账号未经过控制器、旧响应仍可能生效的问题；上主线程及重新 prepare 时继续检查代次。此检查每次完成播放请求增加最多 3 次本地 Cookie 读取，不增加 HTTP 请求。
- 退出时逐域容错收集 Cookie 名称，即使部分/全部读失败，仍尝试过期固定的 4 个关键身份 Cookie。批量写入/删除采用完成协调器：某项同步抛错后，仍等待已经提交的回调完成，再 flush 和结束 Gate；覆盖回调倒序、重复回调、写入拒绝及 flush 异常，避免晚到写入越过账号切换边界。
- 视频候选先经 Media3 1.10.1 的设备 decoder/codec profile、尺寸、帧率能力检查，再在目标清晰度上限内排序。同档优先 AVC；开启解码器初始化备用实现。视频解码错误才逐项尝试有限兼容轨道，保持播放位置/状态；失败轨道在本视频内记忆，后续 playurl 自动刷新不会重新选择该轨道。不把 HTTP、音频或容器错误混入此路径。无可支持视频轨道时明确报错；听视频仍可使用独立音轨。实际选中档位继续用于状态与媒体缓存键。
- 独立只读复核：`/root/review_v170_auth_boundaries`（GPT-6 Luna / medium）。三次复核指出的旧响应会话复查、清理读取容错、部分提交异常下等待在途回调问题均已修正；最后复核未发现新的相关问题。审查本身没有运行测试，不将其当作运行验证。
- 最终验证：`flutter test --no-pub` **676 passed / 1 原有 skipped**；定向 Dart 服务/请求诊断/WBI **23 passed**，窄屏 360×800 游客入口交互 **1 passed**；`:app:testDebugUnitTest --offline` **48 passed / 0 failures / 0 errors / 0 skipped**；`flutter analyze --no-pub` 无问题，`git diff --check` 通过。Flutter 全套后仅改动原生离线状态清理及 JVM 的失败域组合测试，随后再次完整运行 Android JVM 套件。
- 生产方法提取隔离验证 `boundary_harness.py`（替换平台 CookieManager、JSON/网络和设备能力探测；不是设备实测）：关闭 WBI 为 1 playurl/0 nav；开启首次为 1 playurl+1 nav，缓存后新增 1 playurl/0 nav。未知会话自动请求 0，显式游客后 1，且无会话 Header；身份冲突为 0；模拟不支持 HD 时 selected=16 / reported=16，支持时 selected=80。保留匿名、过期、已认证但服务端降清，以及签名失败不回退的覆盖。
- 本轮证据位于 `/workspace/scratch/focubili-360p-investigation/`：`boundary-full.log`、`boundary-targeted.log`、`boundary-guest-widget.log`、`boundary-jvm-final.log`、`boundary-analyze.log`、`boundary-harness-results.txt`。此前不带 boundary 前缀的 final/harness 记录仅对应 24a95b1 阶段，不能作为本次最终测试证据。
- 限制：所有自动验证在 Linux 云端进行，无受影响 Android 真机验收，也没有真实账号/服务端返回验证；仍未确定用户视频范围或个案根因。未改包名、版本、签名配置或用户数据；未读取/生成/上传秘密或新凭据。正式签名状态沿用前节限制，本轮不构建交付安装包。dev 的模块迁移适配和后续用户试包需另行授权。


## 2026-10-13：1.7.1 发布准备（用户已授权）

- 后续用户授权覆盖前节“仅本地”限制：推送 dev、请求 @codex 审查、有效反馈修正、CI 后再合入 master 并发布 1.7.1。以最终本地补丁 `200077e4423fc172381c951d929392b26c27e800` 为来源，旧中间补丁不得单独发布。
- 已重新 fetch：master=`9156ad90060d156095bc5484d5fe372fac26fa94`，dev=`dcb9368f7cb905b6d2723eb72a2912081d2775df`。dev 已含 1.8 Beta1/2，Beta3/4/5 分别为未合入草稿 PR #49/#51/#52。采用独立发布分支从最新 master 拣选两段完整补丁；dev 单独适配模块迁移，不整体合并 dev 到 master，也不覆盖 dev 的 1.8 版本和历史。
- 发布版本为 1.7.1+21；Windows 版本元数据同步为 1.7.1.21。正式包名、Windows 安装器 AppId、Apple Bundle ID、签名配置保持不变。Flutter build number 自动进入 Android/iOS/macOS 产物。
- master 相对最初 v1.7.0 标签已包含 1.7 Apple/Linux 支持及既有维护更新；本次 diff 以最新 master 为基线，仅增加高清切换、会话边界、设备解码回退、必要诊断及发布元数据，不引入 1.8 开发功能。
- 平台影响：Kotlin Cookie/会话代次、Media3 解码探测和回退、媒体轨道缓存身份仅在 Android 执行。其他四个平台使用既有 media_kit 后端，本次不修改其 playurl、签名、Cookie 或轨道算法。共用 Flutter 画质失败提示和诊断存储/页面会执行；原生请求记录及显式游客入口只由 Android NativePlaybackService 提供。新增四平台组件回归，确保非 Android 不出现不可用的游客入口或 Android 请求记录指引。
- 签名预检：下载现有 v1.7.0 Android 资产，公开证书 SHA-256=`65EF1FB301FB1121C1803E752F5B1EB24E55846502D8B5478F0FC11F58E9A8A9`，包名 `com.focubili.app`、versionCode=20、versionName=1.7.0，与 CI 固定证书一致。证书 DN 含 Android Debug，判断覆盖兼容性依赖证书字节一致而非名称。已有签名构建 run 37186425095 的恢复密钥及证书验证步骤成功；当前新包仍需实际签名验证。只查看配置/公开证书，没有读取签名秘密。
- GitHub secret 名称和分支保护详情查询返回 HTTP 403，不能以此断言签名未配置。iOS workflow 明确 `--no-codesign`；现有 v1.7.0 IPA 无 embedded.mobileprovision，不能宣称存在正式可安装签名。macOS 沿用既有 ad-hoc/无公证方式。发布前继续验证各平台实际资产。

- 用户随后明确扩展 1.7.1 范围，新增“忽略本次收到的更新”。本轮仅增加这项已授权功能，不扩展到 Beta 功能。忽略身份绑定仓库、平台、stable/prerelease 通道与版本，不是全局关闭提醒；独立保存检查结果和红点状态。主界面/设置入口红点隐藏，关于页下载与详情保留；自动检查和重新启用启动检查不取消，主动检查立即取消且网络失败不恢复。
- 新增忽略状态并发存储协调，覆盖迟到的忽略保存不能覆盖之后的手动检查，以及手动检查撞上自动请求仍取消忽略但不重复请求。保存失败明确提示，不假装持久化成功。四平台共用画质提示定向 4 项通过；更新服务/页面初步定向 29 项通过。最终全套结果在后续验证阶段追加。
- 实际 UI 布局检查证据见 `docs/reviews/v1.7.1/`：真实 AboutPage / 应用主题、合成更新响应的 Linux Flutter 渲染截图，另覆盖 320 宽深色大字体。明确不称为移动端真机验收。

- dev 移植保留 `PlaybackCacheRepresentation` / `PlaybackCacheIdentity` 和 BV/CID 来源校验；新会话策略与写入协调器移入既有 focubili_android 模块，两个跨模块使用对象提供公开 API，模块测试移到对应插件。dev 版本仍为 1.8.0+22，不降级或覆盖开发元数据。发布分支不包含这些 dev 已有的缓存实现。

## 2026-10-13：PR 审查与手动更新检查修正

- 草稿 PR #54（dev）和 #55（master 发布候选）均已显式请求 @codex 审查；#55 对 039cf0f 的审查指出手动检查等待本地偏好写入会导致存储失败/阻塞时无法联网，属于有效反馈。保留偏好队列顺序，改为与网络检查同时执行；内存忽略立即取消，持久化错误继续提示，网络结果独立更新。
- 回归先在旧实现运行：存储失败后期望累计 2 次请求、实际仅 1 次，测试失败；修正后新增存储失败和慢写入两条路径均能返回新的版本。更新服务及真实页面定向 18 项通过。
- 前一提交完整本地验证：发布候选 Flutter 746 passed / 1 原有 skipped、Android JVM 48 全部通过；dev Flutter 813 passed / 1 原有 skipped、Android app 33 + plugin 32 JVM 全部通过；两分支 analyze 无问题。当前补丁只改共享更新控制器与其回归，不改平台播放代码。最终构建、审查、公开签名证书比对及发布状态以 PR / Actions 和 Release 的实际记录为准，尚未合并或发布。
- dev 审查另指出游客请求在 HTTP 返回后跳过 Cookie 重新读取。现已让所有实际发出的 playurl 请求（包括显式游客）重新验证会话代次；未知状态持续时继续允许游客响应，网页端登录/切换后拒绝旧响应。不增加 HTTP 请求，每次最多 3 次本地 Cookie 读取。新增 JVM 回归覆盖两种状态。
- 审查修正后的验证：发布分支 Flutter 全套 747 passed / 1 原有 skipped，更新与 UI 定向两分支各 18 passed，发布 JVM 50 / dev JVM 67 全部通过，analyze 无问题。JVM 首次离线执行因动态依赖 runner:1.2+ 缺少缓存失败，正常联网重试通过。
- 另提取生产 requestPlaybackSources 方法、替换线程调度/CookieManager/HTTP 的隔离回归：旧实现会在游客请求期间网页登录后仍 prepare，修正后丢弃；仍未知时照常允许。该验证不是真机测试。首轮 039cf0f 的 CI APK 已下载实际比对证书，与 v1.7.0 完全一致（SHA-256 65EF1FB301FB1121C1803E752F5B1EB24E55846502D8B5478F0FC11F58E9A8A9），包名 com.focubili.app、版本 1.7.1 / 21；最终修正提交仍需重新构建及验证。

- 最终提交复审请求受到 GitHub Codex 代码审查额度限制，#54/#55 机器人均明确拒绝执行；这不是审查通过。按用户“审查后再合并发布”门槛，两 PR 保持草稿，尚未合并 dev/master、创建标签或正式发布。
- 等待构建时继续自查发现首次初始化之前手动检查的竞争：慢清除写入与读取并发时，初始化可能读回旧忽略身份。新增回归在 6f7778e 上复现红点错误消失；初始化现在仅在尚未接受手动意图时载入磁盘忽略记录，防止覆写用户最新操作。该修正同步 dev，平台原生播放代码不变。
- 6f7778e 候选已完成 Android/Windows/Linux/macOS 构建和产物核验，Android 公开证书、包名及 ABI 与 v1.7.0 一致，Windows 1.7.1.21，macOS 正常应用盘与产物清单一致且包含 x86_64/arm64；该批产物作为中间验证证据，最终修正提交需重新构建，不混用旧包。
- 初始化竞争修正后，两分支更新服务/真实页面定向各 19 项通过，analyze 无问题；旧实现对应回归明确失败。完整 CI 与正式签名候选构建在新提交上重新执行。

## 2026-10-13：恢复 Codex 审查后的发布时序修正

- 用户在 04:38 UTC 明确授权“再试试”；对 #54/#55 各重试一次，04:40 Codex 已正常启动，分别审查 0151cd7 / e9e2ef8。此前额度限制不再作为当前阻碍，仍未猜测具体 reset 时间。
- 两个最终审查均指出后台 Cookie 验证完成到主线程执行之间的调度窗口。现将带 Cookie 读取的验证移到主线程实际发布点，先丢弃已过期的播放请求，再核对当前会话。成功和失败结果都验证，避免 Cookie 读取失败后网页登录已完成却仍显示旧游客入口。不增加 HTTP 请求，正常播放的本地 Cookie 读取次数不增加；失败结果最多追加 3 次本地读取。
- 生产 requestPlaybackSources 方法提取隔离回归（替换调度器、CookieManager、HTTP）：旧实现在后台完成后、主线程执行前切换账号仍会 prepare，已明确复现失败；修正后的游客/登录态 × 无变化/HTTP 中变化/排队时变化，加两项 Cookie 失败发布，共 8 场景通过。脚本及红绿日志在 /workspace/scratch/focubili-v171-release/publication_response_harness.py 和 publication-before/after-result.log；不是设备实测。
- 本次只改 Android 返回结果的验证位置，Flutter 更新逻辑不变；此前最终 Dart CI 为发布 748 passed / dev 815 passed，各 1 原有 skipped。新提交继续走最终审查和 CI，产物必须与实际待发布代码对应。
- 发布时序修正后再次运行 Android JVM：发布 50 项、dev 67 项全部通过；git diff --check 通过。

## 2026-10-13：可选偏好损坏和诊断备用版本修正

- Codex 对 dev 0993aa6 返回未发现主要问题；对发布 0b7573a 指出可选忽略记录读取失败会阻止版本初始化，以及诊断备用版本未随发布更新。两项有效反馈均修正，并同步适用的 dev 变更。
- 忽略偏好读取独立容错，异常或类型损坏时按未忽略处理，仍加载真实安装版本并允许自动/手动检查。新增两个真实 SharedPreferences 类型损坏/注入读取错误回归，旧实现均会得到空安装版本，修正后各自能发起自动和手动请求。
- 诊断插件返回空值或抛错时，发布分支使用 1.7.1+21、dev 使用其现有 1.8.0+22；没有把 dev 的产品版本降为 1.7。新增两个诊断快照/导出回归直接比对 pubspec 版本，避免下次版本升级再次遗漏。旧实现两项均明确失败。
- 四项新增回归先在旧生产代码运行并失败；修正后两分支更新、真实页面和诊断定向各 29 项通过，analyze 无问题。原生代码未改，保留上轮 JVM 发布 50 / dev 67 和调度夹具 8 场景通过证据；新 head 重新审查、执行完整 CI 和构建最终候选。


## 2026-10-13：保留设置入口更新摘要

- 汇总审查线程时发现旧提交 0b7573a 上迟到的有效 P3 反馈（#55 discussion_r4254953334）：后续网络检查失败时，更新控制器保留了可用版本，但设置入口仍读取失败结果，导致已知摘要消失。两个分支统一从 availableUpdate 读取摘要，保留下载详情与手动检查恢复红点的原有行为。
- 扩展既有真实设置页测试，覆盖发现更新 → 忽略 → 网络失败的手动检查。旧实现最后的摘要断言明确失败，修正后更新/页面/诊断定向两分支各 34 项通过，analyze 和 diff 检查通过；没有新增轮询或请求。
- 上一轮最终 head（发布 7f47cff / dev f9e8591）Codex 返回未发现主要问题，七个 CI 工作流全部成功；完整 Flutter 发布 752 / dev 819 passed，各 1 原有 skipped。旧审查的这条有效意见仍按要求修正，新的 head 将重新审查、构建，不把旧安装包当作最终产物。Android 原生代码未变，JVM 50/67 和发布队列 8 场景证据继续适用。

# FocuBili 本轮工作记录

## 2026-10-10 · Beta3

按本轮模型要求：主任务 GPT-6 Astra / xhigh；两个只读代码探查子代理 GPT-6 Luna / medium。代码修改、验证和审查由主任务执行。

### 基线核验

- 环境原默认分支 `work` 没有本轮修改。普通 fetch 只更新 master 后，显式 fetch 全部分支。
- 最新 dev `dcb9368f`，master `9156ad9`；dev 包含 Beta1 `99839fa`、Beta2 `1fdf145` 及合并 `77d6f2b`。
- GitHub 工具与 gh 查询开放 PR 均为空。未发现 AGENTS.md 或项目 .agents/skills；已读 CONTRIBUTING.md、CI、后台说明和 Beta2 核验记录。
- 新建独立分支 `codex/beta3-focus-performance`；基线比较放在独立 detached worktree `/workspace/FocuBili-baseline`，未改 dev/master。

### 实现与审查

- 缓存只跳过相同快照的解析，跨引擎边界仍读取；每个 mutation 仍通过原 CAS。应用 action 前清除快照标识，部分 restore 失败前也清除标识，确保回放/回滚不误用缓存。
- 首屏惰性构建、稳定键、紧凑左右排布、响应式按钮；首页卡片复用服务，不新增轮询，保留已读与学习进度独立。
- 复现宽屏动画偏移 293.5px；从提示列分离方向反馈，保留触摸透传和原动画重入逻辑。并非听视频进度问题。
- 自检移除了构建工具产生的 gradlew 权限变化；无凭据、产物或用户数据提交到代码树。

### 验证结果

- 基线定向服务/后台/动画测试 43 通过；本轮最终定向 68 通过。
- 本轮完整 Flutter：799 通过、1 项原字体依赖跳过，0 失败。
- Android JVM：35 通过 / 9 suite，0 失败/错误/跳过。
- Dart analyze、全目录 format、diff check 通过。生产 APK 已构建并核验包名、版本与公开证书。
- 性能：1000次 feed读取的排序列表1000→1；100次无变化重读通知100→0；100次小时内自动刷新通知300→0；首屏卡片预创建500→4（实际挂载4→4）；20个同时刷新调用仍只有20来源请求，并发上限2。
- 真实 Flutter 夹具渲染覆盖390px、320px/180%字号、1280px深色；播放器1600px窗口及缩放/方向切换回归通过。截图、性能原始计数、复现命令见 docs/beta3/README.md。

### 交付边界

- 版本共享 `1.8.0+23`，Android debug `-beta.3`，preview 包名与签名配置保持。
- ARM64 versionCode 2023，公开证书 `5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0`，与记录的本地Beta2一致。
- Library 保存返回授权失败；本地同签名 APK 保留。远端使用既有 Actions artifacts，不发布 release。CI 临时签名与通用包23的覆盖限制已写明。
- 本轮无 Windows 真机、Android 真机/模拟器和真实 B站接口验收；CAS/后台回归采用存储与网络替身。Windows CI 中新增 widget 检查，原生编译与真实播放验收分开报告。
- 首次推送被 GitHub 邮箱隐私保护拒绝，改用已核验账号的公开 noreply 身份重新记录本轮提交，未更改账号隐私设置。
- 仅独立分支和 draft PR；不合并、不正式发布、不删除分支。最终提交、PR和实际CI产物链接由任务交付回复提供。

## 2026-10-11 · Beta4 订阅任务拆分

- 按用户后续“做”的授权实现 P0/P1；主任务继续 GPT-6 Astra / xhigh，只读代码探查 GPT-6 Luna / medium。重新 fetch 后 dev/master 未变，确认 draft #49 尚未合并；从其 8341bd9 创建独立 `codex/beta4-subscription-jobs`，不覆盖原分支。
- 定位本地 page<=50 钳制、每页获取 WBI 材料、首次全量初始化、单个已知 BV 提前结束与跨实例重复请求问题。引入两页实时基线、整页覆盖边界、持久网络租约、取消/节流、独立历史任务和原子页存储。
- 保留 Beta3 紧凑 UI/首页卡片/Windows 方向反馈修复；新增历史页面、暂停恢复、数量上限和受限范围提示。
- 模拟接口组合验证经过第 51 至第 500 页、1,000 条新增与置顶旧稿、补抓中再次突增、重复/错页、失败退避、前后台租约、历史与实时事件分离。旧 v1 pending/已读/通知声明、未来 schema 保护、损坏备份、页落盘后游标中断重放及并发不可变写入均有回归。
- 审查修复：备份失败不回退合法当前数据；历史页非空目录原子发布防过期写覆盖；首页变化清除过时页签名并安排再覆盖；旧 owner 未过期时页面显示可继续时间。
- 环境曾短暂断开，原路径、独立分支、所有改动与测试日志保留，恢复后继续原任务。
- dev 与当前分支相同 HTTP 适配器夹具计数：1000/10000 条首轮 40→3 HTTP；10000 条四轮 166→9。优化后两页只是实时基线；全量历史单独选择，不能把该降幅解释为全量同步加速。真实 B站深分页未验收。
- 最终本地：Flutter 完整821通过/1原有跳过/0失败；定向84通过；截图与性能8通过；analyze/全目录format/diff check通过。完整首轮只有旧Beta3版本断言失败，更新Beta4期望后重跑全量通过。
- Android JVM 35项/9suite通过（未变任务使用缓存），三ABI debug构建成功。ARM64 2024公开证书仍为5bd1fc4…00b0，与本环境Beta2/3一致；不保证用户设备或CI临时签名兼容。APK核验详见docs/beta4/apk-verification.json。
- 13张真实Flutter夹具截图已目视检查，含紧凑列表、来源、卡片、历史及宽屏双击反馈。请求计数原始JSON和复现命令见docs/beta4/README.md；不是设计稿或真机截图。
- 只读复核未发现可证明的数据丢失/重复通知；旧任务释放最多等待租约90秒，UI提示并在截止更新可继续按钮。Windows既有CI增加历史文件恢复/取消回归，真实Windows视频播放仍未验收。
- 交付仍为独立分支/draft PR/既有CI artifacts，不合并、不正式发布、不删除分支。提交及实际CI链接由PR和任务交付回复记录。

## 2026-10-12 · Beta5 缓存优化（实施检查点，尚未交付）

- 已重新 fetch：dev dcb9368、master 9156ad9；draft #49/#51 仍开放，从 Beta4 5a49fc6 创建 codex/beta5-image-cache。
- 已定位：五处 Image.network 不使用持久文件缓存；现有 flutter_cache_manager 按对象数而非字节限额；同 BV/CID 刷新字幕轨道后旧正文请求可晚到；mpv 磁盘 packet 文件只追加，demuxer 字节预算不限制磁盘增长。
- 正在实现统一图片路径、完整 URL/头身份、公开 MID 分区、请求合并/六并发、字节 LRU/清空代次屏障；字幕保持 8 MiB/64 轨道/5 分钟的内存缓存，增加轨道代次绑定及账号/清空撤销；Android 缓存增加当前媒体保护和写入预约，桌面改有界内存缓冲并清理旧磁盘残留。
- 初轮定向 37 项通过；新增字幕竞态、复用和 LRU 7 项通过。其余新一轮测试尚有旧平台类型/容量断言和缓存页面注入夹具适配失败，正在修正；尚未进行完整回归、最终 analyze、Android 编译、CI、截图和 APK 交付。
- 收到断连提醒后实际命令验证：/workspace/FocuBili 可访问，独立分支及 43 个改动/新增文件保留。此提交只用于保存实施检查点，不代表已验收。未读取凭据、未改签名或包名。

### Beta5 已完成本地实现与验证，进入 draft 审查

- 统一全部远程图片入口；256 MiB 字节 LRU，完整 URL/头与公开账号分区，跨 isolate/process 文件锁及六个持久下载租约。清空和移除撤销迟到写入，解码缓存同步清理；公共图账号变化重载，旧凭据不重发。账号写入使用跨服务实例串行事务和代次检查。
- 基线复现同 BV/CID 成功刷新轨道后旧正文仍被接受；桌面、原生与 UI 增加会话/代次检查。新增过期 URL 重取时语言变化拒绝用例，缓存复用、账号清除、失败刷新保留及 LRU 回归通过。不能据此宣称所有现场串字幕已解决。
- Android 当前音视频及写入预约受保护，听视频仅 pin 音轨，失败 writer 释放自身范围预约；可选写盘失败不阻断网络播放。42 项 / 10 JVM suite 通过。
- 本地全量最终 855 通过 / 1 原有跳过 / 0 失败；缓存定向 64 通过；截图/图片 HTTP 4 通过；订阅性能 3 通过；analyze、format、diff check 及三 ABI debug 构建通过。全量中途改截图测试导致一次加载失败后已固定文件重跑通过。
- 图片 HTTP 本机真实服务：旧 Image.network 路径模拟解码内存淘汰后 10 次重开 10 请求，新缓存 10 次重开加服务重建 1 请求；两实例并发 1 请求。订阅复测保持 1000 feed 读取 1 份排序结果、未变化重读 0 通知、首屏预创建 4 项。
- 桌面有明确待审取舍：mpv 临时磁盘文件仅追加、关闭即删，本来不支持跨重启复用；当前有界内存草案会缩短同会话长距离回看范围，可能增加网络重读并改变 RAM 占用。已向用户说明并询问方向，不能把策略改动当作无代价优化。依据、影响和限制见 docs/beta5/README.md。
- 12 张实际 Flutter 夹具截图已生成并目视检查，非真实设备验收。原订阅紧凑布局、首页卡片和 Windows 反馈修复均保留。
- 本地 ARM64 code 2025，公开证书 5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0，与本环境 Beta2/3/4 一致。Library 再次返回 401；未上传成功，APK 保留。CI 和用户设备签名不能据此保证覆盖。
- dev/master 重新 fetch 未变，#49/#51 仍 draft 开放；继续独立分支，不合并或发布，后续 CI/产物终态另记录。
- 首轮 CI 在新字幕测试的单行 if 缺花括号处停止（lint，非运行失败）；已按仓库规则补齐，重新 analyze 通过。后续提交将触发新的完整 CI，旧运行终态保留在 Actions。

### Beta5 最终桌面方案：保留磁盘回看

- 父线程明确要求保留现有磁盘回看能力，无需再次询问用户；撤回前述默认纯内存方案。图片、字幕、Android 的改动全部保留。
- 桌面继续 `cache-on-disk=yes`，恢复原磁盘容量偏好键，默认 512 MiB 软阈值。使用正确的 demuxer-cache-dir 和 whendone 文件生命周期；500 ms 统计真实文件长度，达到阈值后关闭新增磁盘写入并保留活跃文件，后续新数据前后各 64 MiB/独立 demuxer。此为软阈值，采样/线程传播可能超出，没有伪称磁盘硬限额；RAM 元数据预算与磁盘占用分开呈现。
- 每个播放器单独目录持有 OS 生命周期锁，创建/清理由根目录锁串行保护；播放器关闭后才释放锁。跨 isolate/进程活跃文件受保护，自动回收已结束/崩溃残留会话，离线下载不参与。设置回读验证绕过 media_kit setter 丢弃 mpv 状态码的问题，失败有明确提示。
- 新增 10 个桌面/存储用例；第一轮新全量发现状态读取失败未转换成 MediaCacheException 的两项旧回归，修复后定向 78 项通过，重新全量验证。Linux/macOS 原生探针增加本机 HTTP 合成媒体、独立音轨、实际 packet 文件和缓存回看验证；以标记的 256 KiB 测试填充文件触发软阈值，不冒充真实B站流量测量。
- 旧 2515af3 的主 CI、Linux、Apple 已全部成功终态，但该提交仍含内存草案，不能作为最终桌面交付。最终新提交将重新触发全部平台工作流，待全部终态并验证产物后交付。
- 最终本地固定源码：Flutter 全量 865 通过 / 1 原有跳过 / 0 失败，缓存定向 78 通过，截图/图片 HTTP 4 通过；12 张当前 UI 图已更新，旧内存草案三张删除。analyze/format/diff check 与 Apple 源码/图标/打包检查通过。三 ABI debug APK 已重新构建，ARM64 code 2025 的公开证书仍为 5bd1fc4…00b0，完整 SHA256/大小见 docs/beta5/apk-verification.json。
- 最后审查补强：若 mpv 释放失败，生命周期租约用强引用保留 Windows 锁句柄，不能因页面对象回收而提前失去保护。受影响定向 20 通过，全量再次 865 通过 / 1 原有跳过；analyze/format 与三 ABI APK 重建通过。此提交是后续全部平台 CI 的统一验证基准。
- 按父线程进一步验收要求强化原生探针：达到阈值并关闭新增写盘后，关闭唯一的本机 HTTP 媒体源，先到 2.5 秒再回看 0.5 秒，恢复播放并要求实际进度超过 1.25 秒；同时保留真实 packet 文件/请求计数检查。只有该流程在原生 CI 通过，才报告磁盘回看实测通过，属性回读不单独算作验收。
- 原生 CI 发现并修复 Apple 兼容问题：捆绑的 libmpv-darwin-build v0.6.0 使用 mpv 0.36，磁盘目录/文件生命周期选项仍叫 cache-dir/cache-unlink-files；统一使用 0.37 新前缀会被拒绝并回退到内存。现按实际选项支持回退旧名称，两项必须回读成功才启用磁盘，新增旧版本用例，并保留初始化错误供原生探针定位。依据已核验上游 downloads.lock 与 0.36/0.37 源码；未靠取消回读或跳过探针掩盖问题。
- a26eb36 Linux 原生断网回看已通过：mpv0.37、2个packet文件/36490bytes，262144byte明确测试填充触发后测得298634bytes；禁写并关闭HTTP源后从2500ms回到500ms，再播放到1301ms；初始2次HTTP、回看新增0次。Apple 失败在初始化阶段，修复后会再次运行完整原生验证；旧包不用于最终交付。
- mpv 0.36 兼容修复后本地最终全量 866 通过 / 1 原有跳过 / 0 失败，定向79通过，analyze/format及三ABI debug APK重建通过；本地公开证书保持不变。环境断开通知后实际命令验证工作区和运行中的测试均可用，GitHub/连接器也可继续读取，未丢失修改。

## 2026-10-18：1.8整合基线

- 合并 origin/dev da0946b（1.7.1认证/画质/忽略更新）与 Beta5 a6c8334（含Beta3/4及缓存修复）；仅 work.md add/add 冲突，两段历史完整保留。
- 基线合并不代表运行验证；保留既有安全会话、轨道选择与缓存逻辑，后续执行完整回归。

### 1.8 设置、诊断和迁移第一阶段

- 编写条目20、21、22、24–27、29：PlaybackPreferences.longPressPlaybackSpeed及服务保存（默认3，1–5，步长0.25）；首页标题点击关于；AppLayoutPreferencesService启动布局快照与大屏协议后一次性选择；关于/诊断显示BuildTime及版本构建号；设置和登录独立导入导出、白名单重置；关于三处指定描述。
- SettingsTransferService.exportSettings/parseSettings/importSettings/resetSettings只处理明确设置键；导入前完整检查格式、键、类型与JSON结构，缺失键保持旧值，写入失败恢复触及的旧值。账号、协议、订阅源、笔记、清单、历史及离线文件不清除。
- DataTransferPage通过系统文件选择器提供操作，登录导出明确警告敏感明文；导入复用loginWithCookie官方验证及既有会话事务。readCookieForExport等待协调写入并拒绝读取期间的账号切换。开发和测试未导出真实登录信息，测试仅合成存储。
- 新诊断只增加运行模式、Dart、后端能力、屏幕尺寸/密度、进程内存、CPU核心、公开ABI/安全补丁/电量/网络类型/内存状态及两个布尔开关。不包含账号、Cookie、设备ID、主机名、IP/SSID、地址或用户内容。详细环境折叠展示，复制仍包含完整脱敏字段。
- 官方PiliPlus参考已核对为bggRGjQaUbCoE/PiliPlus（GPLv3），仅参考设置与登录分离、验证后切换的交互原则，没有复制源码。独立诊断/登录导出参考未核实，不作存在性断言。
- tool/write_build_metadata.dart在CI构建前生成真实UTC构建时间、精确源码提交和版本；源码默认值明确标为本地开发构建。pubspec正式准备版本1.8.0+26；现有正式签名配置和包名保持一致。debug仍为独立preview包。
- 发布流程改为等待同一GITHUB_SHA的CI、Release Build、Apple、Linux全部成功，只取同提交的APK/Windows安装器/macOS DMG/Linux DEB；不附加sha256、tar.gz或portable ZIP。iOS现有无签名档案不作为可直接安装的正式包。
- 本机Flutter原缓存锁只读，使用允许Temp内的SDK与公共包缓存副本；Flutter3.44.6/Dart3.12.2运行成功。未更改权限、读取签名秘密或新建签名。adb当前没有设备。
- 验证：设置/布局/账号边界/更新及页面64项通过；首页与导航20项通过；诊断页与平板10项通过；合计94项定向通过。analyze无问题，format与diff check通过。实际Flutter组件渲染3张图在docs/reviews/v1.8；不是Android真机验收。
- 首轮全量894通过/8失败/1原有跳过，8项源于首页点击组件Material依赖及诊断卡片过高；现已分别修复，受影响30项定向通过。修复后的全量将重新运行，不能把首轮记为通过。
- 独立只读复核未确认P1/P2，范围限设置迁移/登录快照/布局/构建与发布门禁；未替代测试、未完成全部字段逐项核对或原生运行验证。
- 普通SSH22超时，SSH443读取现有known_hosts被拒绝；没有关闭主机验证或绕过权限。GitHub连接器Primary读仓库已确认push/admin能力，必要时可按用户AGENTS已报告SSH失败后的例外传输同一源码树。尚未创建PR/merge/tag/release，也没有删除分支。
- 跨任务send_message_to_thread完整等待后返回MCP -32000错误，因此父线程进度通知需通过本轮最终报告交付。其他任务可从task-2/focubili-repo本地读取5e128bdd基线，不要并发修改release-v180。

## 2026-10-18 · v1.8 焦点订阅正式版任务

- 独立目录 `C:\Users\L1XU4N\Documents\Codex\2026-10-18\task-3\focubili-subscriptions`、分支 `codex/v1.8-subscriptions`。只读检查原仓库后，在本任务可写目录建立独立克隆和 worktree。未改变原工作树、凭据、签名或安全权限。
- 从本机 beta5 a6c8334 实施，已成功重放到统一基线 5e128bdd1952b3f619500f69aa7bc8c33a88d0b4，保留 1.7.1 安全修复。没有合并/发布、删除公共分支或导出登录信息。
- 覆盖用户 part1 1–14、16、28：封面略放大、简化消息卡、消息与来源多选/全选/批量、完整首次中文引导及接受/拒绝行为、首尾轻量基线、原生通知、平台前台降级、到达日期分组/已读底部及 readAt 满七天清理、来源图片筛选和滚动收起/展开、UP/合集页取消订阅、我的页默认顺序。
- 合集并非固定按发布日期排列，不能假定一个 reverse 参数就是最新排序。实时只覆盖默认/反向首两页（最多四次 HTTP）；不全扫描，中间位置任意新增/重排有明确覆盖边界，全量历史独立导入。旧全扫描游标迁至算法3，保留去重、已读、pending 和历史导入。
- 首次引导先落盘 pending choice，再启用、置顶单个卡片并完成 choice；接受/拒绝、重复接受、重启中断恢复和真实首页接入均有回归。已开启 beta 用户保留已有布局与开关，不覆盖手动顺序。
- 统一基线完整订阅定向 105 项通过；Android 插件原生编译 + 34 项 JVM/6 suite 通过。最后保护条件定向复核 60 项通过，最终 analyze/format/diff check 通过。12 张本机 Flutter 夹具图已生成并检查；不冒充真机/真实接口验收。Dart analyze 通过。详见 `docs/reviews/v180-subscriptions/README.md` 与 validation.json。
- 未跑全仓 Flutter 全量或构建安装包；Apple Swift 原生构建、真实各平台通知、Android 厂商后台策略与正式包覆盖安装交由平台 CI/真机确认。Windows/Linux/Apple 未提供关闭/挂起进程后的原生网络调度，仅前台检查。
- 两次通过 Codex app 跨线程发进度均返回 MCP 请求失败；本机 shell、代码、测试和独立 Git 正常。最终交付附可直接 fetch 的本机路径/commit，平台结束通知交给父线程。

### 1.8 整合回归与桌面设置导出补强

- 设置阶段修复后的全量结果为902通过/1原有环境跳过/0失败（日志 task-2/logs/v180-settings-final-fulltest.log），替代前文正在运行状态。
- 焦点订阅两笔交付已整合为a0a384c、1df2f39；订阅/首页/迁移/生命周期整合定向47通过，整合后analyze通过。跨平台原生后台追加由订阅任务继续，未并发修改其模块。
- 复核当前file_picker 11.0.3官方插件源码，桌面saveFile只返回路径，不会写入bytes。新增DataTransferFileService在桌面真正写入UTF-8文件，取消返回false，存储失败传递给既有固定错误提示。5项真实临时文件/取消/失败验证加4项设置迁移测试通过；未导出真实登录数据。
- 设置迁移增加现有“忽略本次更新”偏好，保留1.7.1行为；导入校验四段JSON身份，重置也清除此偏好。
- 发现相同插件用法也存在于旧软件收藏夹导出及Linux笔记分享分支，交父任务供1.9导出排查时核对；本任务先修自身设置/登录导出功能，不把旧路径记作已修复。

## 2026-10-18 · 播放器与通用卡片布局（独立任务）

- 原 Documents/FocuBili checkout 没有修改；在 task-4/FocuBili-player 独立克隆和 `codex/v18-player-layout` 分支工作。读取 CONTRIBUTING.md、本机 memory_summary；仓库没有 AGENTS.md 或 .agents/skills。先对齐统一基线 5e128bd，再 fast-forward 到 0abe1ac，保留认证、画质、字幕会话及 Beta5 磁盘回看修复。
- 实现 part1 15/17/18/19/23/30：卡片间隙按真实指针插入和短位移动画，放手到保存成功期间保持预览避免闪回；顶部状态/中央手势/底部字幕分开，短消息 160ms 独立淡出收拢；原生 seek 进入 loading 时避让方向动画；双击播放暂停及侧滑保持控制栏原状态；笔记原比例预览；两种进度条绘制 Media3/mpv 的真实缓冲段。
- 接入集成者的 `PlaybackPreferences.longPressPlaybackSpeed`；临时速度数值和文案读取同一配置，松手恢复先前速度；迟到异步回包按请求代次失效。
- 定向最终 42 项通过，涵盖间隙/反向拖拽、延迟保存不闪回、两种屏幕的实际 PlayerPage 双击和侧滑、缓冲/动画重叠、独立短提示淡出和 2.5 倍速读取/恢复。最终全量 Flutter 918 通过 / 1 环境跳过 / 0 失败；跳过原因是 Windows 创建符号链接需要开发者模式，未为此修改系统设置。最终图像回归 4 通过、5 张 PNG 已目视检查；静态分析 0 问题，format/diff check 通过。数据与日志 SHA256 见 docs/reviews/v180-player/validation.json。
- 本机真实 libmpv/loopback 合成 MP4 探针返回 4023ms 总时长、推进 490ms、实际缓冲区间 0–3994ms。探针不含 UI；PlayerPage/笔记 PNG 是真实 Flutter 渲染、替身解码器/合成图片，不冒充真机播放。
- Windows 整页实播测试代码已提供；当前 Debug 构建先遇到受限账户 MSBuild FileTracker E_ACCESSDENIED，任务局部关闭可选增量追踪并使用已校验哈希的既有 MPV/ANGLE 归档后，仍出现现有 Windows 插件 Debug CRT 链接错误，出现错误后中断了该失败构建。没有扩大权限或修改系统工具链。adb 无设备；Android、Apple、Linux 原生 UI 和真实 B站播放待人工/CI 验证，Android Kotlin 编译需在最终集成构建确认。
- 跨线程 MCP 连续失败后停止重试，普通进度消息和任务目录 player-handoff.json 提供路径/接口/验证状态。没有导出真实登录信息，没有创建签名，没有合并发布或清理他人分支。

### 播放器整合与首轮完整回归

- 播放器交付2e1a958已整合为8242dbc，代码自动合并，仅工作记录保留双方历史。长按倍速直接消费既有PlaybackPreferences接口。
- 首轮整合全量941通过/1环境跳过/5失败。两项旧按钮tooltip断言更新为可取消订阅，并实际点击确认取消；矮屏测试检出新提示的100像素保留高度永久存在，改为由提示实际可见性通知首页，只在显示期间预留空间，拒绝后恢复原高度。
- 上述修复与Windows媒体规划加载中断复测、设置导出验证，定向55通过/0失败。加载中断独立运行通过，未改媒体规划代码。
- 另一项真实回归仍未解决：subscription_service.dart通知事务只保留仍在500条展示feed的候选，1000条新视频测试通知数仅500。已通过父线程可读进度转交仍修改该模块的原生后台负责人，保留1000条断言，不用降低期望掩盖回归。
- 用户追加发布后优化README并更新GitHub，已列为正式包下载验证后的收尾；不得提前把1.9功能写入。

### 设置迁移完整性补齐

- 新增SettingsRuntimeAdapter，把存于订阅事务库的启用/通知/后台检查三个开关和图片缓存索引容量纳入设置导入导出/重置，通过公开服务接口写入，不直接复制数据库。重置关闭三个开关、撤销后台调度，保留订阅源/去重/笔记/清单/历史/账号；图片容量恢复默认。
- 设置写入失败会同时恢复普通偏好和本次触及的运行期偏好。新增合成适配器故障回滚测试及真实合成订阅+临时图片索引往返测试，实际重新打开索引校验容量，11项通过。
- 导入和重置确认文案说明订阅与后台开关影响。实际登录文件未导出。临时图片测试遵守专用focubili_images_v1目录边界，未放宽缓存安全检查。
- 主体提交 2e1a958 的 918 通过 / 1 跳过记录已保留。追加修复系统取消侧滑时的提示清理与自动隐藏收尾，并新增隐藏/显示控制栏两种取消回归；最终同一源码重新全量 920 通过 / 1 环境跳过 / 0 失败，定向 44 通过，图像 4 通过，静态分析 0 问题。最终记录覆盖主体提交及取消修复，未用旧通过结果代替新源码验证。

## 2026-10-18 · 1.8 订阅原生后台追加

- 继续基于已交付的 0782579，在独立 worktree `focubili-native-subscriptions` / 分支 `codex/v1.8-native-subscription-background` 追加，不改原提交或公共工作树。
- Windows Win32 timer、Linux GLib timeout、macOS DispatchSourceTimer 支持进程运行时失焦/最小化检查；iOS 启动注册 BGAppRefresh，系统机会执行独立无界面 Flutter 引擎。取消/代次变更先使原生旧运行失效，iOS 校验 generation + run token；Dart 20 秒预算、原生 25 秒 watchdog 与系统到时中止，保留可回传的最后结果。
- iOS 订阅快照改用既有 SQLite CAS，与前台安全共享；保留旧偏好快照。桌面关闭/休眠/挂起后不保证；iOS 不承诺每小时，系统不允许时仍前台检查。没有实际安装 OS 启动任务、运行原生探针或访问用户账号。
- 修复集成发现的 1000 条新增仅 500 条通知候选：每页提交返回完整候选元数据，不由展示缓存重建；read 抑制持久保留。新增单轮 1000/500、扫描中已读后淘汰仍分发其余 999、七天后不重复等验收。
- 更新老入口测试以覆盖真正的取消订阅及确认，首页高度按新文字测量边界断言；Android 省电提示用例明确注入 Android 平台。手动检查不再被自动 no-op 轮次吞掉。
- Windows 原生与探针编译通过；新增平台 CI 包含桌面真实回调/取消、Swift run gate、iOS 注册/取消及无界面引擎真实握手。Apple/Linux 未在本机编译或执行，不冒充已验收。详见 `docs/reviews/v180-subscriptions/native-background/`。
- 最终本地结果：通知/后台/入口定向 79 项通过；全量 Flutter 935 通过 / 1 原有跳过 / 2 失败，失败均为未改动的诊断版本回退（+22 与 +25 不一致）。analyze 无问题，398 个 Dart 文件格式检查通过；Apple 源码/元数据与工作流 YAML 检查通过。记录保留失败，不声称全量全绿。


## 2026-10-18 · 独立恢复集成验证

- 父任务授权从 task-2/release-v180 的 f4828c9 建立 task-4/release-v180-recovery / codex/release-v180-recovery；原目录只读，所有既有提交保持为祖先。订阅追加 fab4c972 接入为 9147139，播放器增量 79844da 已由原集成者接入为 0c48370，未重复 cherry-pick。冲突仅为等价断言次序与工作记录，保留双方内容。
- 初次整合全量 971 通过 / 1 环境跳过 / 1 失败：大字体矮屏首页提示出现后父级下一帧才预留高度，瞬时 RenderFlex 溢出 34px。改为存储异步操作返回时同一轮更新父子可见性；标题高度测量也扣除实际两个快捷按钮宽度。保留失败日志并新增首帧、已启用订阅的 2/2.5 倍字体回归。
- 新增 Windows/iOS 服务与原生通道合成联动验证：权威原子快照优先于旧偏好；设置导出不含订阅内容；导入/重置同步原生 generation，旧回调失效，保留来源；系统能力暂不可用仍可重置。不是实际 Apple SQLite/系统调度验收。诊断回退版本与 +26 pubspec 一致，并补齐 BuildTime/源码提交的复制断言。定向 76 项通过；最终全量/分析/构建结果另记。
- 独立原生只读审查未发现 Windows/Linux/macOS 计时器明显编译缺陷。iOS 探针未提交请求，不能证明 OS 队列取消；已更正检查名和文档为取消方法桥接完成。生产 worker libraryURI/SQLite 初始化与销毁仍需 Apple 平台验证。过期回调未绑定任务身份属于低概率生命周期风险，尚未证明系统可触发旧任务终止新任务的顺序；未伪称已复现。
- 本阶段不 push/merge/tag/release/issue，不创建签名、不导出真实登录数据，不扩大系统权限；所有构建/测试使用独立副本和现有环境。


### 恢复验证最终结果与交接准备

- 恢复修复d95b1bd的Dart/产品源码不再改动：最终全量976通过/1原有环境跳过/0失败；定向76通过，生成真实BuildTime/源码SHA后诊断8通过；整个仓库analyze无问题，414个Dart文件格式无改动。保留初次971通过/1跳过/1失败及修复记录。
- 正常Windows Release构建成功（119.7s），先保存正常应用再编译原生调度探针（78.2s）。探针实际运行验证真实定时回调、generation替换、取消后原始回调停止，全部通过，不访问账号、网络订阅或系统通知。正常应用未签名，数字版本1.8.0.26，AOT含真实BuildTime、+26版本和d95b1bd源码SHA；SHA因中文诊断文本常量折叠为UTF16LE，不能只按UTF8搜索。
- 外部首页截图夹具最终2通过，4张320×430、2/2.5倍字体PNG已目视检查；使用本机已有微软雅黑与Material Icons。最初截图辅助用例因fake async里的真实文件I/O等待被中断，已更正runAsync后重跑，不把中断用例算通过；不改产品逻辑来绕过截图问题。
- Android Gradle批处理退出5，Java进程在编译前被拒绝启动。短暂连接恢复后确认仍在DESKTOP-4QI4B5C，Dart与本机文件/Windows构建可用；直接/显式启动现有jbr java -version仍拒绝。未更改系统安全权限、连接、签名或安装其他JDK，未声称Kotlin/JVM或APK通过。Apple/Linux原生与真实系统机会待CI/设备。
- Apple源码/元数据、5个工作流YAML和相关Python语法检查通过。补齐完整30项覆盖与平台边界，修正iOS探针取消证明范围，准备PR正文与独立恢复交接。当前远端dev/master仍为10月13日提交，最近PR/Actions未见今晚新发布，未发现v1.8标签；6个旧版本一次性工作流记录仅列审计候选，不清理远端。
- 原f4828c9及全部祖先提交完整保留；原task-2目录仍只读。临时Directory.Build.targets已移除，生成元数据恢复为源码开发占位，原SDK/安全设置未改。没有push、PR创建、merge、tag、Release、issue写入或分支/工作流清理，等待父线程指定唯一发布者。


### 获唯一发布权后的公开分支范围

- 父线程随后明确指定本任务为1.8唯一发布执行者，授权推送恢复候选、dev PR、Codex审查及CI。每次外部写入前核查远端dev/master、原任务发布分支及1.8标签，发现并发则停止晋级。
- 本机Git CLI认证不可用且Schannel初始化失败，不读取或创建凭据，改用已有GitHub连接。原始9c4c36b提交链和bundle完整留存，服务端汇总提交使用独立SHA并校验文件树。
- 自动审批拒绝了本机审查截图导出；24张均已逐张查看并校验Git blob且仅含合成UI/公开产品信息，但再次审批仍拒绝。停止图像上传，公开分支排除全部24张新审查PNG，图片本机另存，原恢复分支9c4c36b不改。不以其他格式/接口绕过拒绝，也不引用已拒绝图片的远端Git对象。仅发布产品源码、既有公开资源和文字证据。


## v1.8 publication continuation: local integration and PR gate

- Sole continuation copy: task-5/v18-publication-resume. Candidate95b2323 plus notification f845a65 and home61f11c0 cherry-picked as506ee3f/0b57053; no v1.9 feature code. Original worktrees retained.
- Actual combined verification at0b57053: targeted133 passed; full999 passed/1 skipped/0 failed in01:37; analyze No issues7.5s;417 Dart files0 format changes;diffcheck passed. The skip requires Windows developer-mode symlinks; no system setting was changed. Logs remain in the local outer workspace.
- Ordinary Git initially failed Schannel SEC_E_NO_CREDENTIALS under restricted execution; the same ordinary read-only Git command succeeded with normal network execution approval. Existing authentication only; no credentials read/generated/changed, no TLS or security change. Remote devda0946b; target publication branch absent at preflight.
- Publication history audit found24 removed review-image paths/26 historical PNG objects still reachable from candidate ancestry. Preserve the full local history; publish an equivalent final-tree snapshot parented on remote dev, and verify none of those26 objects is reachable in the push range. This excludes rejected images rather than retrying their upload.
- This round stops at dev PR, Codex review request and existing CI. No merge/tag/release, no final artifact or device acceptance claim. See docs/v1.8/publication-stage.md.
