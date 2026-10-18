<p align="center">
  <img src="assets/icon/focubili_icon.png" width="128" alt="FocuBili 图标">
</p>

<h1 align="center">FocuBili · 焦点哔哩</h1>

<p align="center">
  主动搜索，按需订阅，专注观看。一个面向学习的第三方 B 站客户端。
</p>

<p align="center">
  <a href="https://github.com/L1Xu4n/FocuBili/releases/latest"><img src="https://img.shields.io/github/v/release/L1Xu4n/FocuBili?display_name=tag&sort=semver" alt="GitHub Release"></a>
  <img src="https://img.shields.io/badge/Flutter-3.44.6-02569B?logo=flutter" alt="Flutter 3.44.6">
  <img src="https://img.shields.io/badge/Android-7.0+-3DDC84?logo=android" alt="Android 7.0+">
  <img src="https://img.shields.io/badge/Windows-10%201809+-0078D4?logo=windows" alt="Windows 10 1809+">
  <a href="https://qm.qq.com/q/szv665wx7W"><img src="https://img.shields.io/badge/QQ%E7%BE%A4-1055054828-12B7F5?logo=tencentqq&logoColor=white" alt="官方QQ群 1055054828"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
</p>

> [!IMPORTANT]
> FocuBili 是个人学习和技术研究项目，不是哔哩哔哩官方客户端，与哔哩哔哩无隶属或合作关系。项目依赖的非官方接口可能随时变化，请遵守平台规则、版权要求与所在地法律，不要用于绕过付费、隐私或其他访问控制。

## 下载与安装

**[下载最新正式版](https://github.com/L1Xu4n/FocuBili/releases/latest)** · [v1.8.0 更新简报](docs/RELEASE_NOTES_v1.8.0.md) · [反馈问题](https://github.com/L1Xu4n/FocuBili/issues)

在 Release 页按设备选择安装包：

| 平台 | 选择的文件 | 安装说明 |
|---|---|---|
| Android 7.0+ | `FocuBili-v1.8.0-android.apk` | 更新请直接覆盖安装，不要先卸载旧版 |
| Windows 10 1809+ / x64 | `FocuBili-v1.8.0-windows-x64-setup.exe` | 使用安装器；没有商业代码签名时，系统可能显示“未知发布者” |
| macOS | `FocuBili-v1.8.0-macos-universal.dmg` | 打开后将 App 拖入 Applications；当前为 ad-hoc 签名、未公证，详见 [Apple 平台说明](docs/APPLE_PLATFORMS.md) |
| Ubuntu 24.04 系列 / amd64 | `FocuBili-v1.8.0-linux-amd64.deb` | 通过系统软件安装器安装；其他发行版见 [Linux 平台说明](docs/LINUX_PLATFORMS.md) |

iOS 目前提供源码与未签名开发构建说明，需要自行签名后安装，没有可直接安装的 App Store / TestFlight 正式包。模拟器构建不能安装到真实 iPhone，参见 [Apple 平台说明](docs/APPLE_PLATFORMS.md)。

Android 正式版与 Beta / debug 预览包的包名不同，数据不会自动跨包迁移。升级前请留意自己安装的版本，保留原应用及重要资料。各平台的实际验证范围、签名和安装限制以对应 Release 说明为准。

## 焦点哔哩能做什么

首页不提供无限推荐流。你可以主动搜索视频，也可以选择少量知识来源，等有更新时再回来学习。

- **搜索与浏览**：关键词、BV 号和视频链接，查看 UP 主主页、分 P 和 UGC 合集。
- **焦点订阅**：在本机订阅 UP 主与合集，通过首页卡片查看更新，按需开启系统通知。
- **学习与专注**：按视频分 P 整理学习清单，观看时进行专注计时，查看本机专注统计。
- **播放与笔记**：画质、倍速、字幕、弹幕、时间点笔记和截图，以及离线缓存；Android 支持听视频和后台媒体控制。
- **个性化**：首页与“我的”卡片排序、主题、自定义双击区域与长按倍速、横竖屏布局选择。
- **本机数据管理**：软件收藏夹、观看记录、设置与登录信息迁移；关于和问题诊断显示构建号、BuildTime 及脱敏诊断信息。

## 开始使用

1. 在首页点“开始搜索”，输入关键词、BV 号或 B 站视频链接，打开视频。
2. 将想继续学习的分 P 加入学习清单；需要专注时，在首页或播放页开始计时。
3. 在播放页记录时间点笔记，可附上当前画面；之后从“我的 → 时间点笔记”继续查看和整理。
4. 从“我的 → 设置”调整主题、播放器和布局。长按临时倍速默认 3 倍，可在 1～5 倍间按 0.25 倍调整，松手恢复原倍速；横竖屏布局修改后需重启应用。

账号只读保护默认开启。登录后可读取自己的收藏夹、关注和已订阅 UGC 合集；点赞、投币、收藏、关注等账号写操作，需要用户主动关闭只读保护。

### 开启焦点订阅

1. 点击新版首页的“新增焦点订阅”，选择“好，开启焦点订阅”；也可随时从“我的 → 焦点订阅”进入。选择不需要后，首页不再显示首次提示。
2. 添加 UP 主或 UGC 合集。开启后首页会增加订阅卡片和快捷按钮；已经开启订阅的 Beta 用户保留原有布局。
3. 在更新列表点击卡片播放，点击来源头像或合集图片筛选；长按可多选、全选、标为已读或加入学习清单。
4. 想接收提醒时，再分别开启系统通知和后台检查，并按系统提示授权。未授权通知仍可查看列表；来源可批量暂停或删除，也可在 UP / 合集页面取消订阅。

焦点订阅、系统通知、后台检查默认均关闭。它与 B 站账号的关注、收藏以及“我的订阅”入口相互独立，不会替你修改 B 站账号数据，也不提供云端同步。

更新按发现日期分组，已读消息放到底部。已读记录自标记起保留七天，在应用下次初始化或运行中的定期清理时移除；去重记录和学习资料保留。消息列表最多保留 500 条、未读优先，订阅源上限为 50 个。

### 后台检查在不同平台上的区别

开启订阅后，启动、回到前台、手动刷新及前台运行时都可检查更新。额外的原生后台检查需在订阅设置中主动开启：

| 平台 | 实际运行范围 |
|---|---|
| Android | WorkManager 请求每小时联网检查，实际时机由系统决定；省电、Doze、网络和厂商策略可能延迟。建议省电设为无限制、多任务加锁并开启自启动；强行停止后需重新打开应用 |
| Windows / macOS / Linux | 应用失焦或最小化后仍可检查，但仅在进程运行期间有效；退出后停止，休眠或系统挂起期间不保证检查，不添加开机启动 |
| iOS | 由系统机会式安排，不保证每小时执行；系统禁止后台刷新或未分配运行机会时，可回前台检查。强行退出后需重新打开 |

每轮后台检查有时间限制，未完成内容留待前台或下一轮继续。系统通知只是提醒，专注期间会抑制订阅通知，不能保证每条必达。

UP 主先读取最近两页建立有限基线；合集按默认顺序和反向顺序各取前两页，避免反复扫描整个大型合集。合集中间位置新增或任意重排可能不在覆盖范围内。需要完整历史时，可单独发起历史导入；历史导入不会增加新更新未读或发送系统通知，离开应用时暂停，回到前台可继续。

## 数据、隐私与诊断

- 项目没有自建服务器；学习清单、笔记、专注记录、搜索和观看记录保存在当前设备。
- 手机号、密码和人机验证在 B 站官方网页中完成，应用不在自己的表单中收集 B 站密码。登录会话用于需要鉴权的 B 站接口，不上传到开发者服务器。
- “我的 → 设置 → 数据导入与导出”分别提供设置和登录信息迁移。 **登录文件含可用于登录账号的明文 Cookie，请只保存在可信位置，不要分享或上传**。导入经 B 站验证成功后才切换账号。
- 重置设置会关闭焦点订阅、通知和后台检查，保留账号、订阅源与学习资料，重启后生效。设置迁移不等于完整资料备份，离线视频也不会随设置文件迁移。
- 卸载应用、清除应用数据或系统清理缓存可能影响本机资料；有需要时先使用相应功能的导出入口保存重要内容。
- 遇到问题，可在“问题诊断”查看版本构建号、BuildTime 和脱敏状态，再通过 [GitHub Issues](https://github.com/L1Xu4n/FocuBili/issues) 或 [QQ群 1055054828](https://qm.qq.com/q/szv665wx7W) 反馈复现步骤。

项目依赖非官方接口，网络、账号权限和平台风控可能影响使用。不会绕过充电专属、会员、课堂、私密内容或其他访问控制。不同设备的画中画、通知、全屏和后台恢复仍需持续验证。

## 本地构建与贡献

Android / Windows / Apple 使用 Flutter 3.44.6，Linux 使用 Flutter 3.47.5；Dart 随 Flutter 提供。Android 需要 JDK 21、Android SDK 36 和 NDK 28.2.13676358；Windows 需要 Visual Studio 2022 C++ 桌面开发工具、Windows SDK 与 ATL。构建安装器另需 Inno Setup 6。

以正式版源码开始：

```bash
git clone https://github.com/L1Xu4n/FocuBili.git
cd FocuBili
git checkout v1.8.0
flutter pub get
flutter analyze
flutter test
dart tool/write_build_metadata.dart
```

选择当前开发平台需要的命令：

```bash
flutter build apk --debug
flutter build windows --release
```

调试 APK 使用独立的 `.preview` 包。正式 APK 需要已有发布签名配置，正式发布链路会核对历史证书；不要把调试包当作正式包分发。Windows 编译目录是 `build/windows/x64/runner/Release/`，生成安装器可运行：

```powershell
.\windows\installer\build_windows_packages.ps1
```

打包脚本从 `pubspec.yaml` 读取版本，安装器输出到 `build/windows/x64/installer/`。`FocuBili.exe` 依赖同目录 DLL 和 `data/`，不能单独复制。脚本也能生成便携包，但本次正式 Release 只分发安装器。Apple 和 Linux 的构建环境与运行检查分别见 [Apple 平台说明](docs/APPLE_PLATFORMS.md)、[Linux 平台说明](docs/LINUX_PLATFORMS.md)。

提交修改前请阅读 [贡献指南](CONTRIBUTING.md)，PR 目标为 `dev`。目录结构和第三方依赖可从 `lib/`、`packages/`、`third_party/` 与 `tool/` 查看；首次安装展示的完整声明见 [用户须知与使用协议](docs/USER_AGREEMENT.md)。

发布说明中供 App 展示的摘要格式见 [v1.8.0 更新简报](docs/RELEASE_NOTES_v1.8.0.md)。以往更新见 [v1.7.1](docs/RELEASE_NOTES_v1.7.1.md)、[v1.7.0](docs/RELEASE_NOTES_v1.7.0.md) 和 [全部 Releases](https://github.com/L1Xu4n/FocuBili/releases)。

## 致谢

- [PiliPala](https://github.com/guozhigq/pilipala)：优秀的 Flutter 第三方 B 站客户端。FocuBili 在技术路线、模块划分和移动端产品思路上受到了它的启发。
- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：空间公开接口、WBI 参数、请求上下文以及弹幕分段调度思路为本项目提供了重要参考。
- [JKVideo](https://github.com/tiajinsha/JKVideo)：优秀的 React Native 第三方 B 站客户端。FocuBili 在研究原生 DASH 播放链路与单一播放器所有权时参考了它的公开实现思路。

详细说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。感谢所有上游作者和贡献者。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 发布。

使用、修改或分发本项目时，请同时遵守第三方项目许可证、平台条款和内容版权要求。

项目主要在 Codex 协助下开发。

友情链接：
[Linux.do](https://linux.do/)——新的理想型社区
