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
- 当前 libmpv 画面未实现系统画中画，不伪造支持状态。
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
