# iPad 发热反馈：代码审查、解码偏好与验证记录

日期：2026-10-21。本报告记录初始本地调查阶段；后续用户已另行授权独立测试分支的 Android/iOS Actions 构建，原生构建结果以对应 Actions run 为准。结论：已提供可持久化、能传至实际播放器的 iOS 解码及流编码偏好，并补充本机实际解码诊断。**没有证据证明反馈中的发热一定来自软解，也尚未验证真机降温。**

## 基线与授权范围

- 正式版：1.8.1+31，`dd3ebb7de85fa02120b74debf8fd85d525a573da`。
- 本次执行 `git fetch origin test/v1.8.2-search-details`，核实结果为 `f7a4b31c919a55fb823cd473cafc27554d5217a3`。
- 从该精确提交新建隔离 worktree `/workspace/FocuBili-ipad` 和本地分支 `fix/ipad-decoder-preferences`；保留此前 Android 缓冲/诊断、Mac 搜索及会话修复。
- 正式版到测试基线只有 `a94413f`、`f7a4b31` 两个提交；本次没有合入 dev1.9，没有修改版本号、依赖锁、缓存容量或超时。
- 初始阶段只做本地源码、测试、提交及交付文件；随后追加的授权仅限原仓库独立测试分支 push 与双平台 Actions 构建，不含 master/dev、PR merge、tag 或 release。
- 工作区及仓库未找到适用的 AGENTS.md；工作区 .agents/.codex 为空。

## 确定的代码事实

1. iOS 平台装配到 `WindowsPlaybackService`（这个类实际供多个平台使用），后端为 media_kit/libmpv，**不是 Android Media3**。正式版与本次测试基线的 iOS 播放/渲染配置相同。
2. 锁定依赖为 media_kit **1.2.6**、本地 media_kit_video **2.0.1**、media_kit_libs_ios_video **1.1.4**。Apple libs 的 Makefile 下载并校验 libmpv-darwin **v0.6.0**；该构建源码锁定 **mpv 0.36.0 / FFmpeg 6.0**。
3. `AppleVideoCapabilities` 在 iOS 设置 `enableHardwareAcceleration=false`，同时设置 `hwdec=auto-copy`。前者选取 `TextureSW` CPU 渲染，后者仍会尝试可用的回拷硬件解码；**CPU 渲染不能作为正在软件解码的证据**。
4. 固定版 mpv 支持 `videotoolbox-copy`，不支持视频/设备时可以退回软件解码。`hwdec` 是偏好，`hwdec-current` 才报告实际硬件解码后端；后者不可读时是未知，不能根据偏好补值。
5. `TextureSW` 用 libmpv SW render API 输出 `bgr0`，按视频画面尺寸维护三份像素缓冲。回拷、色彩/像素转换与 CPU 画面处理是合理的发热风险，不能由此确定用户真机根因。iOS 关闭 OpenGL 路径有后台运行兼容性依据；本次保留该渲染器，避免损害画中画/后台能力。
6. 原来视频选轨用分数奖励 AVC；默认清晰度是 720P。原设置没有解码偏好，媒体运行诊断入口仅采 Android 数据。media_kit 1.2.6 的 `setProperty` 不返回 mpv 的接受状态，新增设置因此必须读回确认。
7. 本机设置中的 `codec_fallback` 等名称（如有）不能证明实际硬解；本次不以这类字段、播放地址请求成功或界面选项作为硬解证据。

## PiliPlus 对照

执行时 `git ls-remote ... HEAD` 返回并检出 **`a5665fbe3492d1eb09a2e22ca8ae1fea4f07a255`**，与给定参考一致。

- 它将流编码优先级（AVC/HEVC/AV1 等）和 mpv `hwdec` 设置分开；前者用于挑选同清晰度 DASH 表示。
- `HwDecType.kHwdec` 的 Android release 分支为 `mediacodec,auto-safe`，其他平台为 `auto`；枚举里虽然列出很多平台 API，但不代表本项目 iOS 都可用。
- 播放控制器把保存的 `hwdec` 传入 VideoController；调试信息读取 `hwdec-current`。
- 它通过 dependency_overrides 使用自己的 media-kit native 分支，接口及行为与本项目固定版不同。因此这里只参考设置分层和观测方式，没有照抄跨平台参数或硬件加速总开关。

## 仍需测量的风险与未知

| 检查范围 | 代码证据与边界 |
| --- | --- |
| AVC / HEVC / AV1 | iOS 构建启用 AVC/HEVC VideoToolbox，FFmpeg 6.0 构建中有 AV1/libdav1d 解码器但未列 AV1 VideoToolbox hwaccel；不能仅凭新 iPad 芯片宣称这个旧二进制支持 AV1 硬解。本次不开放 AV1 优先，只有服务器仅提供它时仍保留可播放回退。 |
| HDR / 高帧率 / 高分辨率 | 会扩大解码、回拷和渲染工作量；诊断可记录帧率、尺寸与可读的传递函数。未修改色彩管线，也未做 HDR 正确性或能耗实测。 |
| 缩放 / 滤镜 | media_kit 固定版默认 bilinear；项目未默认启用超分、插帧或额外视频 shader。本次不新增滤镜。 |
| 缓冲 / 后台 | 共享服务有 500ms 缓冲范围及磁盘软阈值检查；画面允许后台运行，是否在用户场景中形成额外负载需区分普通后台、听视频和画中画。没有证据支持盲改全局缓存或超时。 |
| 画中画 | 帧桥仅在 PiP capture 开关启用时复制独立 BGRA 帧，最多一份待投递；没有发现无条件持续复制到桥接层的代码。PiP 的额外转换仍需测量。 |
| 弹幕 / 字幕 / 页面 | 弹幕帧时钟在关闭、暂停/非 ready、听视频、PiP 等条件下停止，页面退出会 dispose；字幕按位置查找并有异步身份/请求代次保护。状态订阅和多个 timer 在退出时清理；静态检查未确认一个足以解释严重发热的泄漏。高弹幕密度、页面刷新仍是负载变量。 |
| 倍速音频 | mpv 正常变速使用音高校正；项目 >2x 设置 scaletempo2，旧版不接受时关音高校正。倍速同时增加视频解码需求；未改变既有声音行为。 |
| 设备情况 | 型号、iPadOS、视频、清晰度、帧率、倍速、应用版本、充电情况及运行时解码结果尚未提供；不能给出已确认的单一热因。 |

## 已实现设置

入口：**我的 → 个性化设置 → 播放与专注**。搜索 iPad、硬解、软解、编解码、HEVC 可找到。只在 iOS 显示，Android/macOS/Windows/Linux 不出现无效开关。

| 选项 | 实际行为 |
| --- | --- |
| 自动（推荐，默认） | `hwdec=auto-copy`，保留原兼容路径，失败可软件解码。 |
| VideoToolbox 优先 | `hwdec=videotoolbox-copy`，适合当前 CPU 渲染路径；不是强制硬件，不承诺温度更低。 |
| 软件解码（排查用） | `hwdec=no`；界面明确提示可能明显增加耗电和发热。 |
| AVC / H.264（兼容优先，默认） | 同清晰度优先 AVC，再 HEVC，再其他可用编码。 |
| HEVC / H.265 优先 | 同清晰度优先 HEVC，再 AVC，再其他；首选媒体线路失败时，复用已有恢复逻辑尝试同档 AVC（如有）。 |

- 解码和流编码是两个独立本机偏好。缺失、损坏、未知新值回到自动+AVC；支持设置导出、导入和重置，导入拒绝任意 mpv 参数。
- **下次加载视频、分P、清晰度或本地媒体时应用解码偏好**，不抢占当前播放。编码偏好只作用于下次在线播放，不转换本地文件。
- iOS 选轨按清晰度、编码优先级、原有细分分数排序，避免大码率覆盖编码优先级。不为偏好编码主动升画质，也不为选中 HEVC 主动降画质。
- 写入在 VideoController 原有初始化等待之后完成，先写 `hwdec` 再读回。被拒时尝试读回验证自动；仍不能确认则记录 unavailable，保持播放可用，不声称设置生效。
- 固定 mpv 允许运行时更改 `hwdec`，下一次 open 会初始化解码器；不需重建 Flutter 路由/纹理。保留原有请求代次与账号会话校验，等待期间失效的请求不得打开或播放旧媒体。

## 隐私与诊断

每次新视频就绪后最多自动采样一次；问题诊断打开/刷新时按需采样。**没有新增轮询 timer、持久化遥测或外传。**

进程内环形记录最多 64 条，复制诊断时包含：配置偏好、参数接受/自动回退/不可用状态、可读的实际 `hwdec-current`、视频格式、解码器名称白名单、帧率、宽高、丢帧、倍速、传递函数及严格版本号。记录可在退出播放器后查看，重启清空，也可用原诊断清除操作清空。

所有字段有第二层白名单；不读取 track-list、媒体标题、视频编号、URL、文件路径、Cookie 或原生错误正文。无解码器时不填 `hwdec-current`；`no` 才表示该次样本为软件解码。`cpu_bgr0` 描述渲染路径，不能推导解码方式。**未读取系统 thermalState 或温度**，也不生成虚构热状态。

诊断读写串行化，源代次变更会丢弃旧样本，销毁时先撤销注册并等待读写结束，再释放 mpv 句柄。

## 已执行验证

- `flutter pub get` 成功，pubspec.lock 无变化。
- `flutter analyze --no-pub`：**No issues found**。
- 最终一次相关测试集：**175 项全部通过**。其中新增 25 项，覆盖所有平台能力、默认迁移、持久化失败、UI 提示与保存、设置迁移、编码优先级及回退、实际后端与偏好区分、异步取消、销毁和隐私边界。
- 既有回归覆盖音视频解码健康检查、播放会话身份、音轨恢复、听视频、本地续播、字幕文档绑定/请求来源、视频 metadata 会话、Apple 锁屏/PiP 会话、缓冲范围、磁盘软阈值及诊断页面。
- `git diff --check` 通过。
- 初次扩大测试时把既有测试文件名少写了一个 s，产生一次“文件不存在”；修正后最终完整测试集全绿。没有把那次执行称为成功。

测试证据见交付包 `verification/analyze.log`、`verification/verification.log` 及 `verification/commands.txt`。

**未执行**：iOS/macOS 原生编译、签名安装、真机硬解/热量/耗电测量、画中画后台实测。当前为 Linux，未安装 Xcode/xcodebuild；没有擅自通过推送或 Actions 替代。Dart 测试中的播放器/属性是假实现，验证接线与生命周期，不代表真实 VideoToolbox 已运行。

## 简短真机 A/B

1. 先记型号、iPadOS、应用版本；固定同一个视频/分P、画质/帧率、亮度、网络、弹幕状态、倍速和充电状态。尽量不充电，冷却至相近起点后再开始下一轮。
2. A：自动+AVC，720P/1x 前台连续播放约 10 分钟，记录何时明显热、是否掉帧；保持播放器或结束后立即到“问题诊断”复制本机记录，重启前完成。
3. B：只改 VideoToolbox 优先，其他条件一致。若两轮 `hwdec_current` 都为 videotoolbox-copy，不能将差异解释为“软解改硬解”。然后可单独比较 HEVC 偏好，确认实际 codec 变更。
4. 如仍热，分别单独对比 60fps→普通帧率、较低清晰度、关弹幕、前台→PiP/后台；每次只改一项。软件解码仅在短时兼容排查确有需要时尝试，明显变热即结束。
5. 只需视频 BV/分P或非敏感描述、上述条件及本机诊断。**不需要 Cookie、HAR、完整签名播放 URL。**无温度计时描述体感/系统提示即可，不把体感当温度数值。

## 固定主来源

- [FocuBili 正式版 iOS 配置](https://github.com/L1Xu4n/FocuBili/blob/dd3ebb7de85fa02120b74debf8fd85d525a573da/lib/services/apple_video_capabilities.dart)
- [media_kit 1.2.6 发布包](https://pub.dev/packages/media_kit/versions/1.2.6)、[Apple libs 1.1.4 发布包](https://pub.dev/packages/media_kit_libs_ios_video/versions/1.1.4)：实际读取本地由 lock 校验的包源码与 Makefile。
- [libmpv-darwin v0.6.0 downloads.lock](https://github.com/media-kit/libmpv-darwin-build/blob/4286f5557bdccc0747030e3c376ce5cd160a96a0/downloads.lock)、[FFmpeg 构建配置](https://github.com/media-kit/libmpv-darwin-build/blob/4286f5557bdccc0747030e3c376ce5cd160a96a0/scripts/ffmpeg/meson.build)
- [mpv 0.36.0 hwdec 选项](https://github.com/mpv-player/mpv/blob/v0.36.0/DOCS/man/options.rst)、[实际后端属性](https://github.com/mpv-player/mpv/blob/v0.36.0/DOCS/man/input.rst)、[video-codec 属性实现](https://github.com/mpv-player/mpv/blob/v0.36.0/player/command.c)
- [PiliPlus 固定 hwdec 分支](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/a5665fbe3492d1eb09a2e22ca8ae1fea4f07a255/lib/plugin/pl_player/models/hwdec_type.dart)、[播放器配置](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/a5665fbe3492d1eb09a2e22ca8ae1fea4f07a255/lib/plugin/pl_player/controller.dart)、[选轨](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/a5665fbe3492d1eb09a2e22ca8ae1fea4f07a255/lib/pages/video/controller.dart)、[依赖覆盖](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/a5665fbe3492d1eb09a2e22ca8ae1fea4f07a255/pubspec.yaml)

这些链接对应代码依据，不构成真机结果；HTTP 抓取和静态代码审查不能替代目标设备能耗测试。
