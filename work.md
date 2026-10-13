

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
