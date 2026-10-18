# macOS 普通视频播放地址 412 调查

> 本文保留最初调查及诊断补丁的历史结果；“未推送”“原生源码未改”等描述指该调查阶段。后续经授权实施的 Apple 会话修复、验证范围与限制见 [实现及验证记录](macos-playurl-412-implementation.md)。

调查日期：2026-10-18。范围：准确 1.8 源码、当前 master/dev、PiliPlus 上游；云端静态分析、合成会话与无网络 HTTP 回归。**尚未在真实 Mac 复现平台拒绝，不能宣称已找到并修复用户这次 412 的唯一根因。**

## 可直接使用的结论

1. 现有证据更指向 **playurl 请求被拒绝**。在原版 Mac 链路中，nav 的 HTTP 412 被包装并丢失状态，最终显示通用播放器错误；playurl 的 HTTP 412 和 JSON 业务 ±412 则都能进入用户提供的诊断。现有记录不能进一步区分这两者。
2. 优先核对客户端实际发出的会话/设备 Cookie 上下文，以及 PiliPlus 是否确实使用相同设备、网络和播放账号。FocuBili 与 PiliPlus 在这些方面有实质差异，详见对照表；**差异存在不等于已证明该字段导致 412**。
3. 已证明四个可独立修复的问题：Mac 缺少逐请求事实、HTTP/业务状态混淆、nav 状态被吞、业务错误正文可进入异常。隔离补丁处理这些问题，便于下一次设备复现直接定位；它不是“保证恢复播放”的补丁。
4. 已用合成会话证明两个独立的桌面边界：同一视频三个并发调用发出三次 playurl；请求期间会话改变后仍可返回旧会话结果。前者可能放大请求量，后者可能影响切换期间的播放；均不能单独解释长期稳定的“所有视频”失败。
5. `windowsMediaKit` / `androidWebView` 是共用能力枚举。Mac 实际会话通道由 Apple 插件读取 WKWebView，不能据这些名称断言平台选择错误。账号只读开关仅约束账号写操作，播放源链路不读取它；通知和精确闹钟权限也不在获取播放地址的依赖链上。
6. 用户已反馈旧版也失败，故不归因于“已证实的 1.8 新回归”。1.7.1 说明本身明确：当次播放鉴权/高清修复集中在 Android，Mac 等平台未调整。

## 版本、来源与隔离

| 对象 | 固定版本/状态 |
| --- | --- |
| 用户诊断 | 1.8.0+26；BuildTime `2026-10-18T06:43:49.665171Z`；macOS 26.1（25B78）；Dart 3.12.2；WBI 设置开启；账号只读开启 |
| 精确调查基线 | `5a76dbba192660f652fbd09d38c78eea6a10ffb5`，`release: publish v1.8.0`；pubspec 与诊断版本一致 |
| FocuBili origin | `https://github.com/L1Xu4n/FocuBili.git` |
| master 快照 | `f868ef67d92f3504ea5b6f445864141b804e61f4` |
| dev 快照 | `5cc5c770bf2465aa9a2ca5b6935a5c34d3449613` |
| PiliPlus 官方项目来源 | [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)，与 FocuBili README 致谢及上游 `Constants.sourceCodeUrl` 一致；未使用镜像/fork |
| PiliPlus 对照快照 | `6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4`，main；这是源码对照版本，不代表用户安装版本 |
| 原工作区 | `/workspace/FocuBili`，`work`，仍为 `f868ef6`，保持干净 |
| 调查工作树 | `/workspace/FocuBili-412`，`investigate/macos-playurl-412-20261018`，从精确基线建立 |
| 工具链 | Linux；Flutter 3.44.6 / Dart 3.12.2 |

已搜索仓库和父目录，没有 AGENTS.md 或本地 `.agents/skills`；`/workspace/.agents` 为空。已读取 README、CONTRIBUTING、Apple 平台说明、1.7.1 修复说明及现有播放/WBI/诊断测试。没有推送、合并、发布，没有修改原工作区和其他发布分支。仅从远端读取 Git 对象并创建调查工作树。

master 相对精确基线在 `lib/`、macOS、Apple 插件中无相关变更。dev 的 `desktop_playback_source_service.dart` 主要增加课堂鉴权及 durl 支持，普通 UGC `load()`、WBI 算法和 Apple Cookie 读写核心与基线相同；不是现成的普通视频 412 修复。dev 播放器另有播放意图/缓存等修改，不能整体搬回替代调查。

## 原版请求链路及证据

以下行号均指 **5a76dbb 基线**；本地验证补丁会使行号移动。可用固定提交链接核对。

```text
PlatformServices(mediaKit) → WindowsPlaybackService（Mac 共用）
 → BilibiliDesktopPlaybackSourceService.load(bvid, cid, quality)
 → PlatformBilibiliCookieStore / com.focubili.app/auth / readCookies
 → Apple 插件 WKWebsiteDataStore.default().httpCookieStore
 → [WBI 开启且材料未缓存] nav → WBI 签名
 → /x/player/wbi/playurl 或 /x/player/playurl
 → HTTP 检查 → JSON code 检查 → DASH 轨道解析 → media_kit
```

* 平台装配：`lib/platform/platform_services.dart:39,82`；`platform_capabilities.dart:107` 明确 iOS/macOS 使用 mediaKit 与平台 Cookie 通道。`test/apple_platform_test.dart` 有装配测试，云端已通过；这不等于运行过 WKWebView。
* 请求：[`desktop_playback_source_service.dart:106–140`](https://github.com/L1Xu4n/FocuBili/blob/5a76dbba192660f652fbd09d38c78eea6a10ffb5/lib/services/desktop_playback_source_service.dart#L106)。Cookie 读取一次；nav 与 playurl 使用同一 headers。WBI 开启时加入 `fnver=0`、`web_location=1315873`，发送签名端点；关闭时使用旧端点。`fnval=16`、`fourk=1`。
* API headers 为 JSON Accept、精确 BV 视频页 Referer、固定 Windows Chrome/126 UA、非空 Cookie；**API 请求没有 Origin**。媒体 CDN headers 另有 Origin，不能把两者混为一谈。CDN 不转发登录 Cookie（该文件 `mediaHeaders`）。
* 传输：该文件 `416–445`，每次新建 Dart HttpClient、关闭重定向、15 秒连接/20 秒等待响应头超时；非 2xx 抛出带 HTTP 数字的安全说明。没有内部 412 重试、匿名重试或端点切换。原版在检查状态前读取正文。
* 业务 code：该文件 `160–175`，业务非零错误与 HTTP 状态分开判断，但异常只剩字符串；除 -351 特殊提示外会拼入服务端 `message`。仅用正常说明的既有测试没覆盖服务端正文含敏感内容的情况。
* WBI：[`bilibili_wbi_signing_service.dart:70–115`](https://github.com/L1Xu4n/FocuBili/blob/5a76dbba192660f652fbd09d38c78eea6a10ffb5/lib/services/bilibili_wbi_signing_service.dart#L70)，内存一小时缓存、并发共享 nav、新请求使用本机 epoch 秒；任何 nav 异常被统一换成 `WbiSigningException()`，丢失 HTTP 状态。混合键、排序、过滤、百分号编码与已知 MD5 向量一致，未发现可据此认定的签名算法错误。
* UI：`windows_playback_service.dart:858,896–909` 将播放源异常显示到 error snapshot，其余异常显示通用 Windows 播放器错误（Mac 共用文案）。`player_playback_session.dart:490,692–710` 根据错误状态/文本变化记录诊断；`preparing`/`error` 表示上一状态，不能据两个记录就认定两次 HTTP 请求。
* 诊断：[`problem_diagnostics_service.dart:498–539`](https://github.com/L1Xu4n/FocuBili/blob/5a76dbba192660f652fbd09d38c78eea6a10ffb5/lib/services/problem_diagnostics_service.dart#L498)，旧路径从 message 正则提取一个数字，`HTTP 412` 与 `错误码 -412` 均被归为 riskControl；operation 固定为 load_play_url。逐请求 `PlaybackRequestDiagnostic` 已存在，但由 Android 原生事件进入，Mac 源服务没有发送。环境页显示的是当前偏好，不能证明历史失败请求实际启用了 WBI。

这也解释了为什么仅凭现有诊断无法确定是 HTTP 风险拦截、业务拒绝还是实际使用旧端点。原版 nav 412 被吞这一点，反而让本次保留下来的 412 更指向 playurl 阶段；这是源码推断，不是设备抓包证据。

### Apple 会话细节

[`packages/focubili_apple/macos/Classes/FocuBiliApplePlugin.swift:114–152`](https://github.com/L1Xu4n/FocuBili/blob/5a76dbba192660f652fbd09d38c78eea6a10ffb5/packages/focubili_apple/macos/Classes/FocuBiliApplePlugin.swift#L114)：

* `getAllCookies` 后保留 bilibili.com 及所有子域，以域名长度排序、同名逐字段覆盖，优先根域。没有按目标 API URI 过滤 domain/path，也没有完整身份组冲突状态；不同子域的不同身份字段可能被拼成一个 header。排序在同长度域之间也没有明确优先规则。
* 无法从这段代码证明用户存在冲突，但可以证明它没有 Android 1.7.1 的整组会话边界。根域优先不等于整组账号一致。
* replace 操作先删全部 B 站 Cookie，再逐项写入 `.bilibili.com`、`/`、secure、180 天过期。它有完成回调，但读 API 未串行等待整次写入；中间空/部分状态存在窗口。
* Dart `BilibiliAuthService.readCookieHeader():330` 直接读容器，不像用于验证/导出的路径等待 `_accountWrites` 并检查 generation。桌面播放源也没有发布前会话代次校验。合成回归证实会话变化后旧源仍返回。
* Dart 播放 HTTP 不处理响应 Set-Cookie，也不写回 WK 容器；无论 nav 返回什么新设备 Cookie，当前 playurl 仍使用第一次读取的快照。测试用合成响应 Cookie 验证未写入容器。
* `OfficialWebLoginPage:75–89` 为包括 Mac 在内的登录视图调用 `ensureMobileWebUserAgent`，而播放使用固定 Windows Chrome UA。其与会话/设备上下文的一致性需真机核验，不能只改成某个 UA 就宣称解决。
* 使用的是 `WKWebsiteDataStore.default()`；锁定的 webview_flutter_wkwebview 3.26.0 也创建标准 WKWebViewConfiguration，未见应用显式切入 nonPersistent 容器。因此 **没有静态证据证明读错容器或 Mac 必然不持久化**。跨重启 Cookie 是否保留、实际登录 UA、同名冲突及写入窗口只可在 Mac 验证。

## 与 PiliPlus 的关键差异

对照的是当前上游源码，未运行 PiliPlus、未接触用户账号。以下均为具体代码行为，不是要完整照搬上游。

| 项目 | FocuBili 1.8 Mac 共用链路 | PiliPlus 固定快照 | 判断 |
| --- | --- | --- | --- |
| 入口 | Dart `load()`，显式偏好决定 WBI/旧接口 | `VideoHttp.videoUrl()` UGC 使用 `Api.ugcUrl=/x/player/wbi/playurl`，先 WBI 签名 | 用户的 WBI 实际启用状态需逐请求记录 |
| UGC 参数 | bvid/cid/qn/fnval=16/fourk=1；WBI 增 fnver/web_location | fnval=4048；有 voice_balance、可选 try_look/language 和额外请求上下文 | fnval 主要影响格式集合；不能证明 16 导致 412 |
| UA | Windows Chrome/126 常量 | 该 UGC 分支未覆盖 UA，继承 Request 默认 `Dart/3.6 (dart:io)`；account headers 无 UA | **不能误称 PiliPlus videoUrl 使用 BrowserUa.pc/Safari**；该文件导入 BrowserUa 不代表此分支使用 |
| Referer / Origin | 精确 BV 页面、无 API Origin | 账号拦截器默认 `https://www.bilibili.com`、此 UGC 入口未设置 Origin | 单纯“加 Origin”“改根 Referer”缺乏因果证据 |
| 会话绑定 | 当前唯一平台容器的一次字符串快照 | 拦截器把 account 绑定到请求，cookieJar 按请求 URI 读取；响应/错误响应保存 Cookie | 后者保持响应 Cookie 演进，前者断开同步 |
| 实际播放账号 | 当前本机会话 | `ApiType` 把 UGC 分配到 `Accounts.video`；nav 默认 main | 同一使用者不一定同一播放账号，甚至 PiliPlus main/video 也可不同 |
| 设备标识 | 没有保证 buvid3/buvid4/bili_ticket 存在；来自用户登录容器的原始快照 | LoginAccount 和 AnonymousAccount 均确保 buvid3；另有激活流程 | 缺失/不同生命周期值得优先观察；不复制随机标识、激活载荷或风险相关标志来绕过拒绝 |
| WBI | 相同基本置换/MD5/编码；每小时刷新、nav 并发共享；本机秒时间 | 同样本机秒时间，日期缓存 key、共享 Future | 已知向量和实际规范串验证通过，时钟偏差/线上 key 仍需设备证据 |
| HTTP 与 code | HTTP 异常、业务错误最终都成为字符串，诊断再解析 | Response statusCode 与 JSON code 分层处理；网络错误映射到 message | 需在 FocuBili 保留结构化事实，不能从字符串猜原因 |
| 重试 | 单次 load 遇 412 不重试；不同 load 可并发 | RetryInterceptor 遇已有 HTTP response（含 412）直接 next；无响应连接错误才有限重试 | 不存在“照搬自动重试就能恢复”的依据；上游含 epid 的类型切换是独立语义分支 |
| 只读 | 播放不读取账号只读；`BilibiliInteractionService:606` 才检查 | 视频、心跳等账号可分组 | 不应通过关闭只读尝试修复地址获取 |

上游固定来源：

* [video.dart:211–348](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/http/video.dart#L211)、[api.dart:20](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/http/api.dart#L20)。额外上下文字段仅作为差异记录；不作为绕过风控的修复方案。
* [init.dart:196–216](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/http/init.dart#L196)、[account_mgr.dart:44–154](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/utils/accounts/account_manager/account_mgr.dart#L44)。
* [account.dart:109–150,198](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/utils/accounts/account.dart#L109)、[api_type.dart:97](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/utils/accounts/api_type.dart#L97)。
* [wbi_sign.dart:61–117](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/utils/wbi_sign.dart#L61)、[retry_interceptor.dart:17–66](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/6a5171f98f6d493f3c07bc7fc5f0952d4bc5a5b4/lib/http/retry_interceptor.dart#L17)。

## 根因候选优先级

这是 **验证顺序**，不是伪造的根因概率；多个候选可以同时存在。

| 优先级 | 候选与支持证据 | 尚缺什么 / 如何推翻 |
| --- | --- | --- |
| P1 | 客户端会话及设备上下文不同：PiliPlus 有独立视频账号、jar、响应 Cookie、buvid 生命周期；FocuBili 只发送 WK 一次快照，登录与播放 UA 也不一致。全视频在地址获取阶段失败与请求公共上下文问题相容 | 确认同设备/网络/播放账号；记录固定枚举、会话存在性及设备 Cookie 是否存在。若两客户端会话均稳定且字段存在，缺失 Cookie 假设降级；存在也不证明有效 |
| P1（未控制变量） | 网络出口/代理或账号本身的风险差异。现有“同一用户 PiliPlus 可播放”未证明同网络、同账号、同设备；上游本身还可选不同 HTTP/代理配置 | 用户仅需回答是否一致，无需 IP、账号 ID 或凭据。在未经确认前，不能排除，也不能泛化为“换网络即可” |
| P2 | Mac Cookie 作用域、持久化或不完整快照：Swift 全子域逐字段拼接、写入非整事务，桌面未使用 Android 1.7.1 的完整边界 | Mac 上分别验证 H5/扫码/Cookie 登录、冷启动后状态；原生合成容器测试冲突/路径/到期及写入中读取。当前仅静态证据，不能声称真实用户恰好触发 |
| P3 | WBI 实际未开启、线上材料/时钟问题：当前诊断仅反映设置值；key 有缓存，时钟取设备本地 | 新逐请求 enabled/signed/endpoint 与失败阶段；设备自动日期设置。算法/编码已有独立向量和线上形状 mock 验证，因此不优先改 MD5 或时间单位 |
| P3 | 不同普通 UGC 请求参数、UA/Referer 策略使请求上下文不被接受 | 必须在授权且低频的真实设备对照中单变量验证；没有证据支持批量复制上游全部参数或随机指纹字段 |
| P4（放大因素） | 多次打开/清晰度切换并发。源服务不合并相同 load，mock 三调用得到一次 nav + 三次 playurl；没有单次 412 自动循环 | 需要 attempt/inflight 事实及用户是否点了重试；现有多条诊断不等于同样多的网络请求。静止单次仍失败即可说明它不是唯一初因 |
| P4（场景限定） | 会话变化时发布旧源，已模拟复现 | 仅在切换/写入期间解释得通；不能据此解释重启后长期所有视频失败 |
| 低 | media_kit/缓存枚举、通知权限、精确闹钟、账号只读 | 412 在地址获取前出现，相关代码没有依赖这些权限；媒体解码尚未开始。未见平台选错证据 |

## 验证性补丁：内容、边界与后续最小修复

### 已做的补丁

隔离分支只实施诊断及错误边界修复：

* `desktop_playback_source_service.dart`：实际 HTTP 入口返回状态与正文；异常携带安全数字；每次有效 load 记录签名开关的捕获值、签名是否完成、端点类别、是否发送 playurl、会话读取/来源、设备 Cookie 存在性、请求/返回画质、阶段与结果。非 2xx 立即停止，不读取错误正文、不自动重试。
* `bilibili_wbi_signing_service.dart`：跨包装只传递 HTTP/业务数字；nav 返回非 0/-101 的明确业务拒绝时停止，即使正文同时含签名材料也不继续。仍接受游客 -101 的有效公开材料，保留原有缓存和并发共享。
* `windows_playback_service.dart`：Mac 共用后端可显示安全 WBI 异常，不再把已知拒绝换成通用 Windows 错误。
* `bilibili_auth_service.dart`：只增加实际容器种类的固定枚举；不改读写、登录或账号选择。partial Cookie 仅标注 unknown/partial，不假称已验证游客。
* `PlaybackRequestDiagnostic` 增加严格枚举/布尔白名单；诊断保存/读取上限从 16 增为 24，避免新增安全字段被静默截掉。未知字段及任意枚举文本不会进入记录。
* 普通视频参数、UA、Referer、Origin、签名规范串、账号只读行为和媒体 Cookie 隔离保持原有策略；没有无条件匿名回退、TLS 例外或访问控制绕过。Android 与 Apple 原生源码未改。

这是可审阅的观测补丁，**没有修复 WK Cookie 事务/会话发布边界，也没有证明它能使真实 412 消失**。桌面实际选中轨道 ID 尚未独立暴露，补丁只记录线上的 returned_quality，不伪造 selected_quality。

向 dev 移植时需要手工适配：dev 新增 `loadCourse()` 仍直接使用原 `_requestJson`，本补丁将它改为可空测试注入，移植必须统一到安全读取入口；dev 严格导出校验仍限制 additionalInfo 为 16，需与 24 字段上限同步。不要机械 cherry-pick 后直接发布。

### 下一步行为修复的最小安全范围

1. **先用此类诊断在 Mac 复现一次。** 若是 transport 412，保留阶段并停止；若为 HTTP 200/业务 -412，按业务拒绝处理；若根本没发 playurl，应先修会话读取/签名材料问题。不要通过重试掩盖。
2. **为 Mac 补完整会话快照协议。** 原生按请求目标 host/path/secure/有效期筛选；身份字段整组判断，冲突/读取中/部分状态明确失败；读者等待写事务完成。请求前捕获会话 generation，发布前再次验证；旧代次结果丢弃。仅复用 Android 1.7.1 的安全语义，不删改已有 Android 修复。不要把 `CacheLifecycle.account` 当作覆盖所有 WK Cookie 变化的唯一代次。
3. **有证据再修响应 Cookie 同步。** 对固定官方 HTTPS 响应，只在同一代次中按 Cookie 的域/路径/过期规则合并允许的 Cookie；不要用 `replaceCookies` 全量覆盖导致账号丢失，不把 API Cookie 发送给 CDN。缺设备 Cookie 时使用已有官方登录流程建立完整会话；不伪造/轮换设备标识或加入风险规避标志。
4. **约束重复请求。** 同一会话代次、视频、cid、画质和 WBI 模式共享正在运行的 Future，过时代次取消；观察到 412 后不自动启动额外请求。取消/合并策略不应把别的账号结果复用过来，也不改变用户明确选择游客的语义。
5. UA/Referer/Origin/格式参数调整应独立、可回归，并以真实设备单变量证据为依据。不要同时换所有字段，否则即使恢复也无法确定原因。

## 诊断增强建议

原版 Mac 缺失：wbi 实际启用/完成、endpoint、HTTP 与业务 code、会话来源与读取结果、请求代次、自动回退/尝试次数。此次补丁补齐前四类核心事实与 Cookie **是否存在**，不记录 Cookie 值。

继续增强时只允许固定枚举/有限范围：`ua_profile`、`referer_kind`、`origin_present`、`session_snapshot=stable/partial/conflict/changing`、`attempt_index`、`inflight_count`、`retry_reason`、与官方 Date 响应比较后的 `clock_skew_bucket`。只有真正执行签名后才置 signed；未知 HTTP 状态留空，不能根据字符串夹具或返回 JSON 凭空填 200。设备 Cookie 存在不等于登录已验证。

拒绝记录：完整 URL/query、BV/cid、Cookie/Set-Cookie、账号 ID、token、bili_ticket/buvid 值、签名值、服务端原始 message/body、任意请求头。新增字段的白名单、持久化容量、复制/严格导出都要一起回归；不能只在 producer 增字段却让 storage 截断。

## 最小复现与测试

测试源：`test/desktop_playback_412_regression_test.dart`。HttpOverrides 替换底层 HttpClient，**走生产传输入口**；所有 cookie、设备值、响应与媒体 URL 都是合成常量，没有打开网络 socket。

| 测试 | 原版/结果或补丁验证 |
| --- | --- |
| HTTP 412 | 原版不重试、不丢登录，但找不到逐请求诊断；补丁记录 http_status=412、api_code 缺省、具体 endpoint |
| HTTP 200 + API -412 | 原版会把合成敏感标记及 URL 拼进异常；补丁只展示固定错误与 code，记录 200/-412 |
| nav HTTP 412 | 原版丢失状态，提示关闭 WBI；补丁保留 412，signed=false、playurl_attempted=false、stage=signing |
| 正常 WBI | 独立计算规范串与 MD5 校验；确认同一 Cookie、精确 Referer、实际 UA、无 API Origin、fnval=16、web_location、秒时间；诊断跨存储保留且无凭据/视频标识；响应 Cookie 未同步的现状被记录 |
| 三并发调用 | 一次 nav、三次 playurl，没有额外 412 循环；这是现状特征测试 |
| HTTP 201 | 精确保留 201，不能把成功响应硬编码为 200 |
| nav 业务拒绝但有材料 | 非 0/-101 时停止，不继续 playurl |
| 旧字符串注入夹具 | 没有 HTTP 元数据就不产生 http_status |
| 签名中改变 WBI 设置 | 本次请求和诊断仍使用捕获的原值 |
| 诊断落盘失败 | 不改变成功播放源结果 |
| 部分身份 Cookie | 标注 partial/unknown，不记录值、不清除会话 |
| 加载中会话改变 | 证实目前仍发送/返回旧会话源；明确是尚未修复的桌面缺口 |

执行记录：

* 原版既有播放源/WBI/逐请求诊断三文件：**22 passed**。
* 新增最初五例对准确原版：**1 passed / 4 failed**；失败分别是缺诊断、原文回显、nav 状态丢失、成功请求无事实记录。不是对 B 站风控算法的模拟证明。
* 最终 16 个相关 Flutter 测试文件：**111 passed / 0 failed**，含新增 12 例、Mac 登录初始化夹具、Apple 装配、账号边界、公开内容、播放器与 Android 显式游客协议。
* `flutter analyze --no-pub`：**No issues found**；8 个改动 Dart 文件 `dart format --output=none --set-exit-if-changed` 通过；`git diff --check` 通过。
* Android app JVM 轨道/编解码边界/诊断：**14 passed / 0 failed**，JUnit XML 确认三套件。
* Android 插件 Cookie/会话 JVM：**22 passed / 0 failed**，JUnit XML 确认 Cookie policy、writes、boundary regression、session gate 四套件。两组 JVM 合计 **36 passed**。
* `git diff --quiet 5a76dbb -- android packages/focubili_android packages/focubili_apple` 返回 0，所有原生会话/高清/编解码源码与基线一致。

可在此保存的云环境重跑：

```bash
cd /workspace/FocuBili-412
export XDG_CONFIG_HOME=/workspace/cache/config
export XDG_CACHE_HOME=/workspace/cache/xdg
export PUB_CACHE=/workspace/cache/pub
export PATH=/workspace/toolchains/flutter/bin:$PATH
flutter test --no-pub test/desktop_playback_412_regression_test.dart --reporter expanded
flutter analyze --no-pub
```

首次离线 pub get 因 Linux 媒体包未缓存失败，正常 pub get 后依赖就绪，pubspec/lock 未改。Android 首轮因 Java 不信任环境证书而失败；使用云环境既有 `/etc/ssl/certs/java/cacerts` 信任库重跑成功，未关闭 TLS 验证。包装器不具执行位时用 `bash gradlew`，未修改权限或发布配置。

未跑完整 Flutter 全量套件，未在 Mac 构建/运行 WKWebView 或 libmpv，未安装/发布任何候选包，未验证用户真实账号/真实网络。没有对 B 站发真实 API 请求；外部读取仅 GitHub 来源与工具链依赖。真实 Mac 上的请求被拒绝及会话跨重启保留仍是待确认项。

## 最少必要的用户补充信息

无需提供 Cookie、token、IP、账号 ID 或完整 URL；无需先退出、卸载、清数据。

1. PiliPlus 的版本/来源、运行设备/系统；与 FocuBili 测试时是否为**同一网络与相同播放账号/登录或游客状态**（只回答是否一致，特别核对 PiliPlus 的视频账号配置）。
2. FocuBili 的登录方式（官方网页/扫码/手动 Cookie），以及完全退出重开后“我的”是否仍显示正常登录或提示过期；系统日期时间是否自动同步。
3. 若后续有经审核的诊断构建，仅对一个普通公开视频尝试一次，失败后停止；提供脱敏逐请求记录。重点字段为 endpoint_kind、http_status、api_code、stage、wbi_enabled/signed、session_read/source 与 Cookie 存在布尔值。不要发送 HAR 或自行打印请求头。

这些信息用于选择下一处具体修复，不是开始源码调查的前置条件。
