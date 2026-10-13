

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


## 2026-10-13：1.7.1 安装包交付恢复

- 两条 PR 已在最终 Codex 复核及七个 CI 全部成功后合并：dev da0946b（保留 1.8.0+22），master 83a9d70（1.7.1+21），标签 v1.7.1 指向 master 合并提交；源码树与已审查/构建的 208cff6 相同。最终完整 Flutter 发布 752 / dev 819 passed，各 1 原有 skipped；最新定向各 34 项通过。
- 六个安装包已核验实际内容和哈希，APK 公开证书与 v1.7.0 一致。macOS 正常应用盘内容/双架构/既有签名验证通过；iOS 模拟器原生解码、暂停/跳转/倍速、PiP、偏好、Cookie/WebView/通知桥检查通过，IPA 仍为需用户自行签名的 unsigned 包。
- Release 草稿 411328089 已创建，但云端直接访问 uploads.github.com 连续返回 401，管理 API 正常、草稿为空且未公开。采用独立交付分支上的 Actions 工作流，使用既有 Actions 授权，仅下载指定成功 run/artifact 的六个文件并核对固定哈希后上传；不重新编译、不读写签名秘密、不生成凭据、不移动标签、不发布或替换已有资产。
- 上传脚本校验发布 ID/草稿状态/标签/源码树、成功构建来源、文件大小和 SHA-256；意外文件、损坏/不完整资产、重复资产均拒绝。上传中断可保留正确资产并仅补传缺失项。3 项离线保护条件回归和 Python 编译检查通过。此交付分支不合入 dev/master，应用发布源码保持已审查版本。

- 最终交付完成：Actions 38354113925 成功，仅上传六个固定哈希资产；GitHub 服务端大小/digest 与已核验文件一致。2026-10-13 05:59:55 UTC 正式公开 https://github.com/L1Xu4n/FocuBili/releases/tag/v1.7.1 并设置为 Latest。随后无鉴权访问六个公开下载链接，逐个重新计算哈希均匹配。
- 最终 master/tag 提交为 83a9d70ad1bbb7c4c07a7292baca3439ecde7be3，dev 合并提交为 da0946b98994fea9020a58c870b0ddddcde72a42；审查/构建源码分别为 208cff6e139eb0f4d6362a592f6b5ca967ead6ad 和 1ad7552bc18e39d3275f6da75e15f77a2eed3dda，源码树均与合并结果一致。所有工作分支保留，没有整体合并 Beta 分支。
- 未发布 SHA256 文件或 Linux tar.gz。Android APK 证书/包名兼容基线已验证；受影响 Android 真机/账号、真机覆盖安装和 Windows 交互播放仍未验收。iOS 明确 unsigned 需自行签名，macOS 仍为 ad-hoc 未公证。共享更新/UI 变更覆盖五平台，非 Android 鉴权/选轨算法不变。
