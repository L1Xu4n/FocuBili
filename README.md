<p align="center">
  <img src="assets/icon/focubili_icon.png" width="128" alt="FocuBili 图标">
</p>

<h1 align="center">FocuBili · 焦点哔哩</h1>

<p align="center">
  一个强调主动搜索与专注观看的第三方 B 站 Android 客户端。
</p>

<p align="center">
  <a href="https://github.com/L1Xu4n/FocuBili/releases"><img src="https://img.shields.io/github/v/release/L1Xu4n/FocuBili?display_name=tag&sort=semver" alt="GitHub Release"></a>
  <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Android-5.0+-3DDC84?logo=android" alt="Android 5.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
</p>

> [!IMPORTANT]
> FocuBili 是个人学习和技术研究项目，不是哔哩哔哩官方客户端，与哔哩哔哩无隶属或合作关系。项目依赖的非官方接口可能随时变化，请遵守平台规则、版权要求与所在地法律，不要用于绕过访问控制或批量抓取内容。

## 为什么做 FocuBili

FocuBili 希望保留“主动找到一支视频并认真看完”这件事本身：

- 首页不提供无限推荐流；
- 搜索、BV 号和视频链接是主要入口；
- 播放页优先保留视频、选集和必要控制；
- 不把点赞、投币、收藏等账号操作伪装成网页请求。

## 已实现功能

### 搜索

- 支持关键词、BV 号和 B 站视频链接。
- 支持输入候选词、搜索历史和自动加载下一页。
- 支持默认排序、播放多、新发布、弹幕多和收藏多。
- 支持发布日期、视频时长和内容分区筛选。
- 结果展示标题、UP 主、发布日期、播放量、弹幕数和视频时长。
- 封面直接请求 320×200 WebP 缩略图，并使用内存与磁盘缓存。

### 原生播放器

- Android Media3 直接播放 DASH 视频与音频，播放页只有一个播放器和一份声音。
- 支持播放/暂停、进度拖动、0.75x～2x 倍速和清晰度切换。
- 左右双击快退/快进 5 秒，中间双击播放或暂停。
- 播放时长按临时切换为 2 倍速，松手恢复原速度。
- 控制栏 5 秒后自动隐藏，隐藏时显示贴底微型进度条。
- 支持横屏沉浸全屏、长标题滚动、刘海/挖孔区域适配和系统返回退出全屏。
- 左侧竖滑调整亮度，右侧竖滑调整媒体音量，并排除底部系统手势区。
- 支持 Android 原生画中画。
- 接入 MediaSession，可响应系统控制中心、耳机和媒体按键。
- 网络波动时尝试 Media3 重试、备用 CDN 和有限次数播放数据刷新。
- 使用最大 512MB 的 LRU 边播边缓存；缓存满后自动淘汰旧数据，不属于离线下载。

### 播放记忆与分P

- 按 `BV + cid` 保存每个分P的播放进度，拖动进度条后立即保存。
- 距离结尾 3 秒以内视为已经看完。
- 进入视频时恢复上次进度；超过一小时会显示“时:分:秒”。
- 多P视频会恢复最后观看的分P，单P视频不显示无意义的选集和跳转提示。
- 选集支持横向浏览、双列展开、定位当前分P、正序和倒序。

### 登录与本地会话

- 默认提供手机号登录入口，也可选择密码、Cookie 和完整网页登录。
- 手机号、密码和人机验证都在 B 站官方网页完成，FocuBili 不接触用户密码。
- 网页登录成功后自动读取应用 WebView 容器中的会话状态。
- Cookie 登录只写入应用自己的 WebView Cookie 容器，不会上传到 FocuBili 服务器。

### 界面与工程

- Flutter Material 3 明暗主题。
- Android 5.0（API 21）及以上系统支持。
- 自定义应用图标和多密度 Android 图标资源。
- Dart 单元/组件测试覆盖搜索解析、筛选、播放手势、进度恢复、全屏、画中画和布局边界。

## 当前限制与 TODO

- 接入真正的弹幕数据、时间轴同步、样式和屏蔽规则；当前弹幕按钮只有界面状态。
- 完成全屏“更多选项”中的画面比例、字幕、解码和播放策略。
- 补全搜索结果中的多P识别；部分结果缺少可直接使用的集数字段。
- 重新设计分P按钮：按钮内两行显示，超长标题竖向滚动。
- 增加长按后左右拖动快捷调节进度。
- 为亮度、音量手势增加顶部排除区，避免影响系统控制中心下拉。
- 增加缓存占用、清理和容量上限设置。
- 为画中画增加系统播放/暂停操作按钮。
- 增加会话过期、账号切换和更细粒度的 Cookie 管理。
- 在获得合适的官方授权能力后，再评估原生手机号、密码和短信登录。
- 持续验证长视频、会员画质、番剧、课程和不同厂商 Android 系统的兼容性。

## 下载

可以在 [GitHub Releases](https://github.com/L1Xu4n/FocuBili/releases) 下载 APK。

当前 APK 用于学习测试。仓库中的 Release 构建仍使用本机调试签名；如果准备长期公开分发，请先配置并妥善保管自己的 Android 签名密钥。

## 本地构建

### 环境

- Flutter 3.16.5 或兼容版本
- Dart 3.2.3 或兼容版本
- JDK 21
- Android SDK 35
- Android NDK 25.1.8937393

建议把仓库克隆到不含中文和空格的路径，避免旧版 Flutter 着色器工具在 Windows 上处理路径时失败。

```bash
git clone https://github.com/L1Xu4n/FocuBili.git
cd FocuBili
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK 默认生成在：

```text
build/app/outputs/flutter-apk/app-release.apk
```

## 项目结构

```text
lib/
├─ core/                 # 主题与路由
├─ features/             # 首页、搜索、播放器、登录与个人页
├─ models/               # 视频、分P、搜索分页与筛选模型
└─ services/             # B 站数据、账号、搜索历史与原生播放桥

android/app/src/main/kotlin/com/focubili/app/
├─ MainActivity.kt               # Flutter 宿主、全屏与画中画生命周期
├─ NativePlaybackController.kt   # Media3、播放数据、缓存与进度记忆
└─ BilibiliCookieController.kt   # WebView Cookie 会话桥
```

## 隐私与安全

- 项目没有自建账号服务器。
- 不在 Flutter 表单中收集 B 站密码。
- 不把 Cookie、播放记录或搜索记录上传到开发者服务器。
- 播放进度、最后分P和搜索记录保存在本机。
- 视频缓存位于 Android 缓存目录，可由系统清理。

## 致谢

- [PiliPala](https://github.com/guozhigq/pilipala)：优秀的 Flutter 第三方 B 站客户端。FocuBili 在技术路线、模块划分和移动端产品思路上受到了它的启发。
- [JKVideo](https://github.com/tiajinsha/JKVideo)：优秀的 React Native 第三方 B 站客户端。FocuBili 在研究原生 DASH 播放链路、单一播放器所有权和播放体验时参考了它的公开实现思路。
详细说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。感谢所有上游作者和贡献者。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 发布。

使用、修改或分发本项目时，请同时遵守相关第三方项目许可证、平台条款和内容版权要求。
