# 第三方项目说明

## PiliPala

- 项目地址：https://github.com/guozhigq/pilipala
- 原作者：guozhigq 及 PiliPala 贡献者
- 许可证：GNU General Public License v3.0

焦点哔哩的新 Flutter 框架参考了 PiliPala 的技术路线和模块边界，包括：

- Flutter 跨平台客户端结构；
- 页面、路由、服务、模型和播放器分层；
- 移动端原生播放器体验；
- B 站 API、Cookie、弹幕、字幕和本地存储的后续演进方向。

当前第一阶段骨架代码为重新编写的最小实现，没有直接复制 PiliPala 的完整页面或播放器源码。为确保后续可以合法复用和改造 GPL-3.0 代码，本项目采用 GPL-3.0-only 发布。

## JKVideo

- 项目地址：https://github.com/tiajinsha/JKVideo
- 原作者：tiajinsha 及 JKVideo 贡献者
- 许可证：MIT License

FocuBili 在研究 Android 原生 DASH 音视频播放、单一播放器所有权、播放状态同步和移动端播放器交互时，阅读并参考了 JKVideo 的公开实现思路。当前 Flutter 与 Kotlin 播放代码为本项目重新编写，没有直接复制 JKVideo 的完整播放器源码。
