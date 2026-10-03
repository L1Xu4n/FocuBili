# iOS 与 macOS 开发预览

本分支为 `dev` 增加 Apple 工程和平台实现。应用标识固定为 `com.focubili.app`，版本号从 `pubspec.yaml` 读取。

## 实现范围与验证边界

| 功能 | 实现方式 | 验证要求 |
| --- | --- | --- |
| 搜索、合集、关注、历史、收藏、学习清单、布局 | 复用现有 Flutter 与 Dart 服务 | 自动测试 + 真机回归 |
| 官方网页登录、扫码、Cookie 登录 | WKWebView 官方页面，WKHTTPCookieStore 会话容器；扫码复用官方接口 | 真机登录与退出测试，不记录密码/Cookie |
| 在线/本地播放、独立音轨、倍速、画质、弹幕、字幕 | Apple media_kit/libmpv，复用经过域名校验的播放源与 Dart 叠加服务 | Apple 编译 + 实际视频/音轨验证 |
| 缓存、离线队列、断点续传 | 应用沙箱文件与 Dart 下载队列 | 前台下载/暂停/重启恢复 |
| 时间点笔记、截图、导出/分享 | 复用笔记服务、Flutter 捕获/视频雪碧图回退、系统文件/分享插件 | iPhone/iPad/Mac 文件和分享回归 |
| 全屏与操作 | iOS 旋转策略、macOS 窗口全屏、软件亮度覆盖层、系统音量 | 真机旋转/多窗口/快捷键 |
| 后台听视频、系统控制 | iOS AVAudioSession playback，Apple Now Playing、播放/暂停/拖动；中断和耳机拔出暂停 | 真机锁屏、耳机、电话中断 |
| 专注通知 | UNUserNotificationCenter 即时与定时通知，权限仅主动申请 | 真机授权/拒绝/取消/重启 |

平台边界：
- Apple 系统勿扰不能由普通第三方 App 自动切换，页面明确说明需手动操作。
- iOS 15 / macOS 12 及以上接入系统画中画：从 libmpv 输出复制独立帧交给 AVSampleBufferDisplayLayer，保留原播放源与音轨；只有系统 didStart 回调确认后才报告进入成功。设备不支持或当前状态不可用时返回失败。画中画不包含 Flutter 弹幕/字幕覆盖层。
- iOS 可挂起后台下载；不承诺 Android 前台服务式无限后台下载。回到 App 后可继续队列。
- 没有 Apple 实机验证，不能把 CI 编译成功描述为所有功能真机通过。
- 自签/未公证构建仅供测试，不是 App Store、TestFlight 或 Developer ID 正式发布包。

## 构建

使用 Flutter 3.44.6、macOS/Xcode 和 CocoaPods；依赖由 `pubspec.lock` 固定。

```sh
flutter pub get
flutter analyze
flutter test
flutter build ios --release --no-codesign
flutter build ios --simulator --debug
flutter build macos --release
```

`.github/workflows/apple-build.yml` 在此分支、面向 dev 的 PR 和 dev 提交运行，保存与精确提交关联的 Actions artifacts：
- `FocuBili-ios-unsigned.ipa`：真机架构，未签名，需用户自行签名
- `FocuBili-ios-simulator.zip`：仅模拟器使用，不能安装到真实 iPhone
- `FocuBili-macos-preview.dmg`：本地 ad-hoc 签名，无 Developer ID / Apple 公证

构建不使用或申请 Apple 账号、证书、私钥，也不自动合并 PR。二进制不提交到 Git 源码分支；dev 工作流会生成对应安装产物。

## 免费 iOS 自签与升级

用户可自行在电脑通过 [Sideloadly](https://sideloadly.io/) 或 [AltStore Classic](https://faq.altstore.io/) 为 IPA 签名，也可用 Xcode 的免费 Personal Team 测试。Apple ID 与密码只由用户在可信工具中处理，不交给项目维护者。

免费签名通常七天到期，需刷新；自动刷新仍依赖工具运行和设备连接条件。参见 [Apple 会员对比](https://developer.apple.com/support/compare-memberships/) 与工具官方说明。没有免费永久、全设备通用的测试证书。

升级时继续使用同一 Apple ID/团队及相同的最终 Bundle ID，覆盖安装，不要先卸载旧版。若签名工具改写应用标识，也要保持改写结果一致。更换身份可能无法覆盖或失去原数据/钥匙串访问；重要笔记先导出备份。

## Mac 安装与升级

DMG 包含 FocuBili.app 和 Applications 快捷方式。测试包无 Apple 公证，系统可能限制首次运行。不要全局关闭 Gatekeeper 或要求用户执行不明脚本。正式发行需维护者选择可信的 Developer ID 签名与公证流程。

更新前退出旧应用，使用相同标识的新版替换 App；用户数据位于应用独立数据目录。签名身份变化可能需要重新授权，不能保证从 ad-hoc 转正式签名无缝迁移所有系统权限。

## 测试版转正式版验收清单

- 使用相同 Bundle ID 不代表不同签名团队之间一定可以覆盖安装。iOS 自签工具若改写标识，必须保留其原结果；正式团队与个人团队切换需分别验证。
- 升级前导出重要笔记，记录收藏、离线缓存、设置和登录状态；不要先卸载旧版。
- 覆盖升级后核对笔记文字/图片、收藏列表、下载文件、进度与布局；登录态和系统权限独立核验。
- 应用容器、钥匙串与文件权限均可能受签名/沙箱变化影响；正式包必须实测迁移，不把可编译当作无损升级证据。
- 开发者目前没有苹果实机；本清单尚未完成。模拟器启动截图仅证明对应构建可以进入界面，不等于登录/媒体/后台场景通过。

## 自动化覆盖升级检查

CI 在正常安装包已打包后，另外构建两个测试专用入口版本（build number 900001 → 900002），保持 `com.focubili.app` 不变。
iOS 模拟器使用替换安装而非卸载；macOS 替换同路径应用后启动新进程，核对 SharedPreferences、Documents 笔记样例和 Application Support 离线文件字节是否保留。测试记录包含阶段和结果，不写入真实账号。

此检查仅证明同标识、同测试签名条件下的容器数据保留，不覆盖跨个人/正式签名团队、钥匙串迁移、真实历史版本数据库升级或第三方自签工具改写标识。测试入口不会装进已打包的用户 IPA/DMG。

## 画中画与 iOS 后台渲染

本地固定 `third_party/media_kit_video` 2.0.1 的 MIT 源码，Apple 渲染 worker 只在用户请求画中画后复制帧。复制目标来自独立像素缓冲池，待派发帧有界，避免原纹理循环缓冲被复用后的画面错乱；Mac 硬件路径仅在该消费者开启时等待 GPU 写入完成。

iOS 预览采用软件画面输出并请求 `hwdec=auto-copy`，避免应用进入后台继续调用 OpenGL ES。硬件解码是否实际启用需真机观测；软件输出仍有 CPU 色彩转换/缩放成本，不能宣称高分辨率/高帧率性能与旧硬件路径相同。真机温度、耗电和长时间后台播放仍需验收。

CI 会记录 `APPLE_PIP_RESULT` 的真实 started 状态和收到的独立帧数。帧桥检查通过而 started=false 仅证明帧传输可用，不算系统浮窗启动成功；不支持的运行环境单独标记。正式验收还需 Home/锁屏/恢复、旋转、连续进入退出、拖动与倍速、音频中断等场景。
