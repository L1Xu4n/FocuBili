<p align="center">
  <img src="assets/icon/focubili_icon.png" width="128" alt="FocuBili 图标">
</p>

<h1 align="center">FocuBili · 焦点哔哩</h1>

<p align="center">
  一个强调主动搜索与专注观看的第三方 B 站 Android 客户端。
</p>

<p align="center">
  <a href="https://github.com/L1Xu4n/FocuBili/releases"><img src="https://img.shields.io/github/v/release/L1Xu4n/FocuBili?display_name=tag&sort=semver" alt="GitHub Release"></a>
  <img src="https://img.shields.io/badge/current-v0.2.1-00A1D6" alt="Current version v0.2.1">
  <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Android-5.0+-3DDC84?logo=android" alt="Android 5.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
</p>

> [!IMPORTANT]
> FocuBili 是个人学习和技术研究项目，不是哔哩哔哩官方客户端，与哔哩哔哩无隶属或合作关系。项目依赖的非官方接口可能随时变化，请遵守平台规则、版权要求与所在地法律，不要用于绕过付费、隐私或其他访问控制。

## 项目目标

FocuBili 希望保留“主动找到一支视频并认真看完”这件事本身：

- 首页不提供无限推荐流；
- 搜索、BV 号和视频链接是主要入口；
- 播放页优先保留视频、选集、简介和必要控制；
- 账号数据功能以只读为主，不伪装点赞、投币、收藏或关注写操作。

## v0.2.1 更新内容

### 播放器

- 重新整理播放器上下控制栏，缩小高度并统一播放、时间、选集、画质、倍速和全屏按钮的对齐方式。
- 普通竖屏在详情页显示横向分P列表；只有全屏多P视频在播放栏显示“选集”，单P视频不显示无意义按钮。
- 修复反复进入和退出全屏后弹幕生成位置逐渐向左偏移的问题。
- 弹幕时间轴跟随 0.75x～2x 播放倍速，并根据完整播放器宽度重新计算移动轨迹。
- 左右滑动快捷跳转时显示目标时间对应的视频画面预览；预览接口不可用时仍保留时间提示和跳转能力。
- 视频详情显示发布时间、标签、BV/AV、简介和只读互动统计；长按 BV 可复制，过长简介以省略号折叠。
- 修复合集内切换其他视频后持续缓冲的问题；合集切换复用同一个原生播放器，返回键会回到切换前的视频。
- 修复合集条目在不同接口字段下无法显示封面的问题。

### UP 主主页

- 投稿支持关键词搜索，以及“最新发布、最多播放、最多收藏”三种服务端排序。
- 修复投稿时长为字符串时被错误显示成 `0:00` 的问题，兼容秒数、`分:秒` 和 `时:分:秒`。
- 投稿接口遇到 `-352`、`-779`、`-799` 或 HTTP 412 风控时，会自动切换 WBI 签名接口并有限重试。
- 旧名片接口受限时，使用公开 WBI 资料接口和关系统计接口补齐昵称、头像、简介、认证和粉丝数。
- 不绕过充电专属、私密、会员或其他受限内容；没有公开权限的视频仍不会展示。

### 我的页面

- 修复收藏夹 `attr` 位标志被误判为“收藏夹已失效”的问题。
- 收藏夹缺少封面时，尝试使用其中首个公开视频的封面补齐。
- 收藏夹、收藏内容、我的订阅、我的关注和本机观看记录均支持搜索。
- 重新设计“我的关注”卡片，分层显示头像、昵称、UID、认证和签名。
- 重新设计本机观看记录卡片，让标题、分P标题、观看进度和具体时间在窄屏上也能完整阅读。

### 工程质量

- 所有新增或修改的 Dart 函数均包含中文作用注释。
- `flutter analyze` 无问题。
- 完整 `flutter test` 共 99 项全部通过。
- Windows 中文目录下可通过映射英文盘符构建 Release APK。

## 已实现功能

### 搜索与视频详情

- 支持关键词、BV 号和 B 站视频链接。
- 支持候选词、搜索历史、自动分页、排序、发布日期、时长和内容分区筛选。
- 搜索结果显示标题、UP 主、发布时间、播放量、弹幕数、时长和多P提示。
- 视频详情包含标题、简介、标签、公开统计、分P、UP 主入口和 UGC 合集。

### 原生播放器

- Android Media3 直接播放 DASH 视频与音频，并通过 Flutter `Texture` 显示画面。
- 支持播放/暂停、进度拖动、双击快进/快退、长按临时二倍速、清晰度与倍速切换。
- 支持横向滑动进度预览、竖向亮度/音量调节、沉浸全屏、画面比例、字幕、弹幕和画中画。
- 支持 MediaSession、耳机和系统媒体按钮。
- 支持播放进度、最后分P、本机观看记录和有限容量的边播边缓存。
- 网络波动时会尝试 Media3 重试、备用 CDN 和有限次数播放数据刷新。

### 登录与只读账号数据

- 手机号、密码和人机验证均在 B 站官方网页中完成，FocuBili 不接触用户密码。
- 支持应用 WebView 会话检测和用户主动导入 Cookie。
- 支持只读查看收藏夹、收藏内容、已关注 UP 主和已订阅 UGC 合集。
- 不提供收藏、取关、私信或其他账号写操作。

## 当前限制

- 项目依赖非官方公开接口，接口可能随平台策略调整而失效或触发风控。
- 充电专属、会员、课程、番剧、私密或其他受访问控制保护的内容不会被绕过。
- 弹幕屏蔽词、透明度、字号、轨道记忆和解码策略仍待完善。
- 不同 Android 厂商的全屏安全区、画中画和后台恢复仍需要更多真机验证。
- Release APK 目前使用本机现有签名配置，仅适合学习测试；正式长期分发前应配置并妥善保存独立签名密钥。

## 下载

可以在 [GitHub Releases](https://github.com/L1Xu4n/FocuBili/releases) 下载公开构建。

## 本地构建

### 环境

- Flutter 3.16.5 或兼容版本
- Dart 3.2.3 或兼容版本
- JDK 21
- Android SDK 35
- Android NDK 25.1.8937393

```bash
git clone https://github.com/L1Xu4n/FocuBili.git
cd FocuBili
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

Release APK 默认生成在：

```text
build/app/outputs/flutter-apk/app-release.apk
```

Windows 用户建议把仓库放在不含中文和空格的目录。若必须使用中文目录，可以先映射英文盘符再构建：

```powershell
subst X: "C:\path\to\FocuBili"
Set-Location X:\
flutter build apk --release
```

## 项目结构

```text
lib/
├─ core/                 # 主题与路由
├─ features/             # 首页、搜索、播放器、登录与个人页
├─ models/               # 视频、分P、合集、账号与预览模型
└─ services/             # B 站数据、账号、字幕弹幕与播放桥

android/app/src/main/kotlin/com/focubili/app/
├─ MainActivity.kt               # Flutter 宿主、系统栏与画中画生命周期
├─ NativePlaybackController.kt   # Media3、播放数据、缓存与进度记忆
└─ BilibiliCookieController.kt   # WebView Cookie 会话桥
```

## 隐私与安全

- 项目没有自建服务器。
- 不在 Flutter 表单中收集 B 站密码。
- 不把 Cookie、播放记录或搜索记录上传到开发者服务器。
- 播放进度、最后分P、搜索记录和本机观看记录保存在本机。
- 视频缓存位于 Android 缓存目录，可由用户或系统清理。
- WBI 签名只用于读取公开接口，不用于绕过访问控制。

## 致谢

- [PiliPala](https://github.com/guozhigq/pilipala)：优秀的 Flutter 第三方 B 站客户端。FocuBili 在技术路线、模块划分和移动端产品思路上受到了它的启发。
- [JKVideo](https://github.com/tiajinsha/JKVideo)：优秀的 React Native 第三方 B 站客户端。FocuBili 在研究原生 DASH 播放链路与单一播放器所有权时参考了它的公开实现思路。

详细说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。感谢所有上游作者和贡献者。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 发布。

使用、修改或分发本项目时，请同时遵守第三方项目许可证、平台条款和内容版权要求。

项目主要在 Codex 协助下开发。
