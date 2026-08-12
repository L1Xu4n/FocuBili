# FocuBili 多平台开发方案

更新日期：2026-08-10

状态：`v0.2`，架构方向已确认，第一批平台边界改造正在实施。

## 当前实施状态

截至 2026-08-10，阶段 0 已完成，阶段 1 已完成平台边界与安全降级的主体代码：

- 已新增 `AppPlatform`、`PlatformCapabilities` 和唯一装配入口 `PlatformServices`；
- Android 继续使用 Media3，Windows 继续使用 media_kit，未改变现有播放后端；
- 播放、字幕/弹幕、缓存、Cookie、通知、登录、系统能力、更新、诊断和桌面启动已改为读取统一能力；
- iOS、macOS、Linux 和未知平台在实现前使用明确的 unavailable 状态，不会回退调用 Android 通道；
- 已增加 6 项平台架构测试，覆盖五个平台识别、Android/Windows 能力映射、Android 装配和未支持平台降级；
- 本批已通过 346 项 Flutter 测试、Android 应用模块 JVM 测试、Android ADB 冒烟和 Windows 真进程/单实例冒烟；没有生成新的原生 Runner。

## 1. 目标与范围

近期正式支持：

- Android
- Windows

未来按顺序扩展：

- iOS
- macOS
- Linux

当前不把 Web 纳入目标。FocuBili 依赖本地播放器、系统通知、安全凭据、文件导出和桌面窗口等原生能力，Web 会形成另一套产品边界，不应只为了“平台数量”提前增加维护成本。

## 2. PiliPlus 调研结论

本次以 PiliPlus `main` 分支提交 `36dec609315cd34f8895cf15607f1cc582a66f01`（2026-08-09）为样本。

### 2.1 值得借鉴的做法

1. 使用一个 Flutter 仓库，同时保留 `android/`、`ios/`、`macos/`、`windows/` 和 `linux/` Runner。页面、模型、网络和大部分播放器界面由 Dart 共享。
2. 用 `PlatformUtils` 统一区分移动端、桌面端和 Darwin 平台，并在启动阶段分别初始化移动端方向/系统栏、Windows WebView、macOS 服务和桌面窗口。
3. 播放器使用 media_kit 形成跨平台底座，桌面端补充窗口全屏、鼠标、键盘和画中画交互，移动端补充方向、亮度、音量和系统画中画。
4. 登录、WebView、下载目录、保存图片、分享和权限没有假设所有平台能力相同，而是保留平台实现和降级路径。
5. Android、iOS、Windows、macOS、Linux 使用独立构建工作流和独立发布产物，避免一个平台的工具链故障阻塞所有产物。
6. `pubspec.yaml` 对 Windows 图标、Linux/macOS 图标等资产使用平台过滤，并为真正需要差异的插件选择平台实现。

### 2.2 不应直接照搬的做法

1. PiliPlus 当前约有 146 个 Dart 文件包含平台判断，相关引用约 656 处。平台差异已经进入大量页面和播放器控制逻辑，新增平台时需要逐处审查。
2. 项目依赖多个自有 Git fork，并对 media_kit、WebView、window_manager 等核心插件做覆盖。它能快速解决上游问题，但升级 Flutter 或插件时维护成本很高。
3. `PlatformUtils.isMobile` 和 `isDesktop` 只能回答设备类别，不能表达“是否支持画中画、精确提醒、安全 Cookie、原生全屏”等具体能力。
4. 部分平台失败依赖异常捕获或空操作。对 FocuBili 这类强调可诊断性的产品，能力不可用应当在界面和测试中明确，而不是等到运行时才发现插件缺失。

### 2.3 对 FocuBili 的直接启示

PiliPlus 证明“单 Flutter 仓库 + 多原生 Runner”是可行路线，但它也说明平台判断会随着功能增长迅速扩散。FocuBili 应复用单仓库和共享业务的优点，同时把平台差异集中在能力接口与平台实现目录中。

## 3. FocuBili 当前基线

FocuBili 已经完成的多平台工作：

- 已存在 Android 和 Windows Runner。
- Android 使用 Media3 原生播放器；Windows 使用 media_kit/libmpv。
- 已有 `PlaybackService`、`PlayerOverlayService`、`MediaCacheService`、`BilibiliCookieStore` 等接口。
- Windows 已有扫码登录、安全 Cookie、Toast、系统能力页、桌面快捷键、真实窗口全屏、缓存、安装器和多种分发产物。
- 宽屏工作台、响应式布局和桌面输入已经复用了原有平板适配成果。

当前结构风险：

- 只有 `android/` 和 `windows/`，尚未生成 iOS、macOS、Linux Runner。
- 约 13 个 Dart 文件直接判断操作系统，共约 36 处引用；另有约 29 个 Dart 文件导入 `dart:io`。
- 多个工厂采用“Windows，否则 Android”的二分法。新增 iOS/macOS/Linux 后，它们会错误调用 Android 方法通道。
- `SystemCapabilitiesPage` 在非 Windows 平台一律显示 Android 权限页。
- `NativePlaybackService`、`NativeMediaCacheService` 中的 `Native` 实际表示 Android，命名会在 Apple/Linux 加入后产生歧义。
- Windows 通知后端由通用通知服务直接导入，具体平台实现与跨平台契约尚未完全分开。
- 仓库目前没有 GitHub Actions，无法持续证明 Android 与 Windows 同时可分析、测试和构建。

结论：当前不是“从零开始做多平台”，而是从可工作的 Android/Windows 双平台原型升级为可扩展的正式多平台架构。

## 4. 建议确定的架构决策

### 决策 A：继续使用单 Flutter 应用仓库

不拆 Android、Windows 为两个业务仓库，也不迁移到 Kotlin Multiplatform、.NET MAUI 或 Electron。

理由：现有 Flutter 页面、模型、网络、专注、笔记和测试可以继续共享；拆仓会立即产生功能漂移、重复修复和数据模型兼容问题。

### 决策 B：统一契约，不强求统一底层实现

- Android 播放器继续使用 Media3。
- Windows 播放器继续使用 media_kit/libmpv。
- iOS、macOS、Linux 在开始适配时优先验证 media_kit。
- 所有平台通过同一个 `PlaybackService` 契约向页面提供能力。

Android 已有针对 AVC/HEVC、缓存、字幕、弹幕和生命周期的专项修复，不应为了表面上的“一个播放器”放弃已验证成果。

### 决策 C：按“能力”分支，不在页面按“系统名”分支

页面应询问：

- 是否支持画中画；
- 是否支持系统勿扰；
- 是否支持后台定时提醒；
- 使用二维码、WebView 还是外部浏览器登录；
- 是否支持真实窗口全屏；
- 缓存属于持久缓存还是临时播放缓冲。

页面不应自行判断 `Platform.isWindows` 或 `Platform.isAndroid`。平台名判断只允许出现在平台检测、应用装配入口和具体平台实现中。

### 决策 D：使用显式且穷尽的平台装配

建议逐步形成以下结构：

```text
lib/
  platform/
    app_platform.dart
    platform_capabilities.dart
    platform_services.dart
    android/
    windows/
    ios/
    macos/
    linux/
    unsupported/
  services/
    contracts/
  features/
  models/
```

`app_platform.dart` 只负责把运行环境识别为明确枚举。`platform_services.dart` 是唯一装配入口，按枚举创建播放、通知、登录、安全存储、缓存、窗口和系统信息实现。

平台枚举必须穷尽处理。未知或尚未实现的平台使用明确的 `unsupported` 实现，不能自动回退到 Android。

### 决策 E：依赖注入保持轻量

沿用现有“接口 + 构造函数注入 + 工厂”的方式，不为了多平台引入大型 service locator 或状态管理框架。应用根部完成一次装配，页面和控制器只接收契约。

只有当插件在某个平台连编译都不支持时才使用 Dart conditional import；普通的功能差异使用能力接口和平台实现，避免条件导入泛滥。

### 决策 F：支持等级必须明确

| 等级 | 含义 | 当前平台 |
| --- | --- | --- |
| Tier 1 | 正式发布，完整自动化与人工冒烟，问题按正式版本优先修复 | Android、Windows |
| Tier 2 | 能构建和启动，核心浏览/播放可用，但部分系统能力可明确缺失 | 未来的 iOS、macOS、Linux 开发期 |
| Unsupported | 没有 Runner、构建验证或产品承诺 | Web 及其他平台 |

不能因为插件清单中出现某个平台就宣称该平台受支持。至少通过该平台的真构建和核心冒烟后，才能进入 Tier 2。

## 5. 平台能力初始矩阵

| 能力 | Android | Windows | iOS（未来） | macOS（未来） | Linux（未来） |
| --- | --- | --- | --- | --- | --- |
| 播放底层 | Media3 | media_kit | 优先验证 media_kit | 优先验证 media_kit | 优先验证 media_kit |
| 登录 | 官方 WebView | 官方二维码 | 官方 WebView/外部浏览器评估 | 二维码/外部浏览器评估 | 二维码/外部浏览器评估 |
| Cookie 存储 | Android WebView 容器 | Windows 加密存储 | Keychain | Keychain | Secret Service；不可用时明确提示 |
| 通知/提醒 | AlarmManager + 通知 | Windows Toast | UNUserNotificationCenter | UNUserNotificationCenter | freedesktop 通知；定时能力单独验证 |
| 勿扰 | 用户授权后支持 | 当前不自动控制 | 暂不承诺 | 暂不承诺 | 暂不承诺 |
| 画中画 | 已支持 | 当前不支持 | 后续验证 | 后续验证 | 后续验证 |
| 窗口管理 | 不适用 | 已支持 | 不适用 | 需要 | 需要 |
| 更新产物 | APK/AAB | EXE/ZIP/MSIX | IPA/TestFlight | DMG/ZIP | tar.gz，后续选择 deb/AppImage |

矩阵描述的是产品承诺，不是插件理论支持列表。每项能力必须由真实平台测试更新状态。

## 6. 后续开发规范

### 6.1 代码边界

1. `features/`、共享组件和业务服务不得新增直接的 `Platform.isXxx`。确需使用时必须先说明为什么能力接口无法表达。
2. 新的平台功能先定义小而明确的接口，再实现 Android/Windows 版本，并提供 unsupported 或显式不可用结果。
3. 禁止使用 `MissingPluginException` 作为正常的能力检测方式。它只能作为最后一道故障保护。
4. 禁止“非 Windows 就是 Android”“非移动端就是桌面端”这类开放式默认分支。
5. `Native` 不再用于代表 Android。新文件和逐步重命名使用 `AndroidPlaybackService`、`AndroidMediaCacheService` 等明确名称。
6. 文件路径使用 `path_provider` 和应用专属目录；删除、迁移和缓存清理必须验证目标边界。
7. 登录 Cookie、令牌、设备信息和诊断继续遵守最小收集原则，不因新增平台降低安全标准。

### 6.2 函数与文档

1. 每个函数、方法和工厂都写简短注释，说明目的、关键输入输出或平台限制。
2. 注释解释“为什么”和边界，不重复代码字面行为。
3. 新增平台能力时同步更新本文件的能力矩阵、`PROGRESS.md` 和 `TODO.md`。

### 6.3 UI 与交互

1. 布局优先依据可用宽度、方向和输入设备，不依据操作系统名称。手机、平板、窄窗口和宽窗口继续共享响应式断点。
2. 桌面端必须支持鼠标悬停、滚轮、右键语义、键盘焦点和快捷键；移动端必须支持触摸、安全区和系统返回。
3. 不展示无法工作的入口。功能缺失时隐藏入口或展示明确的“当前平台暂不支持”，不能点击后静默失败。
4. 平台原生体验可以不同，但业务数据、账号安全、播放进度和笔记格式必须一致。

### 6.4 依赖准入

新增或升级原生插件前必须记录：

- 实际支持的平台和最低系统版本；
- 最近维护状态与已知问题；
- 开源许可证；
- 是否增加原生运行库体积；
- 是否需要权限、签名、entitlement 或系统包；
- 在 Android 与 Windows 上是否完成真实构建。

优先使用活跃维护的正式版本。只有上游无法满足且问题可复现时才采用 Git fork；fork 必须固定提交、记录原因、保留回归测试和退出计划。

### 6.5 测试门槛

每个共享改动至少需要：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```

涉及 Android 时：

- 运行 Android JVM 测试；
- 构建 Debug APK；
- 优先使用 ADB 安装、启动、采集日志和冒烟；
- 播放、权限、通知或生命周期改动需要对应真机/模拟器路径。

涉及 Windows 时：

- 真正执行 Windows Debug 或 Release 构建；
- 启动并检查窗口、播放、登录和单实例；
- 打包改动需要验证 EXE/ZIP/MSIX 或本次涉及的目标产物。

未来平台进入 Tier 2 前，必须在对应系统执行真构建和“启动、登录、搜索、播放、退出”冒烟。不能用当前 Windows 主机上的静态分析代替 Apple/Linux 构建。

### 6.6 CI 规范

建议建立分层矩阵：

1. 所有 PR：格式、静态分析、Flutter 单元/组件测试。
2. Android 相关 PR：Android JVM 测试与 Debug 构建。
3. Windows 相关 PR：Windows Debug 构建。
4. 后续新增平台：各自 Runner 的编译任务；发布构建与普通 PR 构建分离。
5. 工作流按平台拆分，失败能明确归属，不把所有系统塞进一个难以诊断的超长任务。

### 6.7 Git 与发布

正式版本继续严格执行：

```text
本地提交 -> 普通 SSH push 到 dev -> 合并到 master -> 构建 Release -> 发布正式版
```

禁止强制推送发布分支。不要提交 `PROGRESS.md`、`TODO.md`、本机研究快照、构建目录、签名、Cookie、密钥、日志或临时截图。

同一产品版本使用同一个语义版本和标签，各平台构建号按商店/安装器要求映射。发布资产名必须包含版本、平台、架构和类型，例如：

```text
FocuBili-v1.5.0-android-arm64.apk
FocuBili-v1.5.0-windows-x64-setup.exe
FocuBili-v1.5.0-windows-x64-portable.zip
```

## 7. 推荐迁移顺序

### 阶段 0：确认方案

- 确认本文六项架构决策。
- 确认 Android 与 Windows 为 Tier 1，其他平台暂不承诺发布时间。
- 暂不生成 iOS/macOS/Linux Runner。

### 阶段 1：平台边界重构，不改变现有行为

- 新增明确的 `AppPlatform` 与 `PlatformCapabilities`。
- 建立唯一平台装配入口。
- 把“Windows，否则 Android”改为穷尽分支。
- 把 Android/Windows 具体类从通用契约中分离，并逐步消除含糊的 `Native` 命名。
- 为 Android、Windows、unsupported 三组装配增加单元测试。

### 阶段 2：固定 Android/Windows 质量门槛

- 增加格式、分析、测试、Android 构建、Windows 构建工作流。
- 建立可机器检查的平台能力矩阵或测试夹具。
- 用 ADB 完成 Android 回归，用 Windows 真进程完成桌面冒烟。

### 阶段 3：完成双平台产品一致性

- 清理页面剩余的平台名判断。
- 补齐 Windows 长时间播放、CDN 切换和正式登录验收。
- 明确 Android 与 Windows 可以不同的功能，并保证界面不展示无效入口。

### 阶段 4：按平台逐个扩展

1. iOS：先启动和共享业务，再处理登录、安全存储、播放器、通知、分享与签名。
2. macOS：复用 Apple 安全存储和通知经验，再补桌面窗口、快捷键与分发。
3. Linux：验证 media_kit、Secret Service、系统通知和发行包差异。

一次只把一个新平台推进到 Tier 2；不得同时生成三个 Runner 后留下大量无法验证的占位代码。

## 8. 第一批实施任务建议

用户确认本文后，第一批代码只做架构整理：

1. 新增平台枚举、能力模型和装配入口。
2. 迁移播放、叠加层、缓存、Cookie、通知、系统能力和更新目标的默认工厂。
3. 为尚未实现的平台返回明确 unsupported 实现，不新增 iOS/macOS/Linux 业务代码。
4. 保持 Android 和 Windows 现有行为、存储格式、MethodChannel 名称和发布产物不变。
5. 完成静态分析、全量测试、Android 构建/ADB 冒烟和 Windows 真构建/启动冒烟。

这批完成后，FocuBili 才具备安全添加第三个平台的结构基础。

## 9. PiliPlus 三项第三方组件参考结论

### 9.1 media-kit：继续使用，但隔离在播放服务后端

PiliPlus 当前直接使用 media-kit，并在自定义 `PlPlayerController` 与 `PLVideoPlayer` 后面封装底层播放器。media-kit 提供跨平台播放、状态 Stream、音视频/字幕轨选择、HTTP Header、外部音轨、截图和播放列表等能力。

FocuBili 已经在 Windows 使用 media-kit，值得继续参考：

- `Player`、`VideoController` 和画面 Widget 分离；
- 通过 Stream 把播放、缓冲、进度、时长和错误转换成统一状态；
- 严格管理播放器创建、重开、订阅取消和 `dispose`；
- 为 B 站 DASH 的视频轨、外部音频轨统一附加 Cookie、Referer、Origin 和 User-Agent；
- iOS、macOS、Linux 适配时优先验证 media-kit，但仍放在 `PlaybackService` 后面。

不直接采用 PiliPlus 的 media-kit Git fork 和依赖覆盖。只有正式版本无法解决可复现问题时才评估 fork，并要求固定提交、回归测试和退出计划。

### 9.2 flutter_meedu_videoplayer：参考控制层，不新增依赖

PiliPlus 当前只在 README 致谢中提到 flutter_meedu_videoplayer，`pubspec.yaml` 和源码没有直接依赖或导入。PiliPlus 已经改为自写控制层直接连接 media-kit。

flutter_meedu_videoplayer 本身使用移动端 `video_player` 和桌面端 `fvp`，不是 media-kit 的组成部分。其最后一个仓库提交样本为 2024-06-22，依赖版本也明显早于 FocuBili 当前工具链，因此不建议把它作为新的核心依赖。

值得阅读和借鉴的设计：

- 播放核心、控制器、控制按钮和全屏页面分层；
- 移动端横滑进度、左右竖滑亮度/音量、双击跳转和长按倍速；
- 桌面端空格、方向键、Escape、Enter 和鼠标双击；
- 用 `EnabledControls`、`EnabledButtons` 一类能力配置隐藏不可用入口；
- 自动隐藏控制栏、锁定控制、全屏切换和统一资源释放。

FocuBili 已经实现其中大部分交互，真正需要借鉴的是文件拆分和能力配置，而不是替换现有播放器页面。

### 9.3 Dio：值得分阶段引入统一网络层

PiliPlus 当前大量使用 Dio，并用一个集中请求对象配置基础地址、超时、Cookie 拦截器、有限重试、取消令牌、后台解析、下载和 HTTP 适配器。

FocuBili 当前约有 10 个 Dart 文件直接使用 `HttpClient`，约 44 处相关引用；请求头、关闭客户端、状态码和异常转换存在重复。Dio 值得用于降低这类重复，并为搜索取消、统一超时、下载进度和只读请求重试提供基础。

建议在平台边界重构完成后再分阶段实施：

1. 先定义可测试的 `BilibiliHttpClient` 契约，业务服务不直接依赖 Dio 类型。
2. 使用一个受控 Dio 实例统一基础 Header、连接/接收超时和错误分类。
3. 先迁移一个低风险只读接口并保持原测试，再逐个迁移其他服务。
4. Cookie、请求正文、响应正文和带敏感参数的 URL 禁止写入日志。
5. 只对明确幂等的 GET 请求做有限重试；412、风控和业务拒绝不能盲目重试。
6. DASH 媒体、字幕、弹幕等大响应继续保留主机白名单、端口限制、响应大小上限和流式处理边界。

Dio 是网络基础设施，不负责解析 B 站业务模型，也不应与播放器引擎绑定。引入后仍保留服务接口和测试注入能力。

### 9.4 最终取舍

| 组件 | PiliPlus 当前角色 | FocuBili 建议 |
| --- | --- | --- |
| media-kit | 真实播放底层 | Windows 继续使用；未来 iOS/macOS/Linux 优先验证；保持在播放接口后面 |
| flutter_meedu_videoplayer | README 历史致谢/控制层来源 | 只参考架构与交互，不新增依赖 |
| Dio | 统一 API、认证、重试、下载和取消 | 平台边界重构后分阶段引入统一网络层 |
