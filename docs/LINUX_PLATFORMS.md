# Linux 桌面适配

当前目标为 Ubuntu 24.04 系列 amd64 桌面；其他发行版需要满足 GTK3、WebKitGTK 4.1、libmpv2 和 Secret Service 等依赖，不能直接视为已通过兼容测试。

## 功能与系统服务

- 播放、DASH 独立音轨、倍速、画质、字幕弹幕、缓存、笔记和桌面快捷键复用已有 Dart/media_kit 实现
- Linux 音量手势调节应用播放器音量，不依赖可能不存在的 ALSA Master 混音器
- MPRIS 提供媒体键、桌面播放状态和播放/暂停/跳转/倍速控制
- 视频小窗复用当前窗口和播放器，返回时恢复窗口尺寸及置顶、最大化/全屏状态；Wayland 是否允许置顶由合成器决定
- QR/Cookie 登录沿用统一账号校验；官方网页登录使用独立、临时 WebKitGTK 容器，关闭后丢弃浏览器数据
- 持久登录会话只使用 Secret Service 密钥环；缺少或锁定密钥环时应明确报错，不回退明文存储
- 图片分享使用 GTK 图片剪贴板，笔记包使用文件保存对话框；桌面需提供 xdg-desktop-portal 及对应后端
- 专注提醒通过桌面通知服务发送。未来提醒由应用计时器驱动并保存期限，应用最小化时继续；退出后不能自动唤醒，重新打开后恢复尚有意义的期限
- 无跨桌面通用的系统勿扰 API；需用户在桌面通知设置中手动开启

## 安装与构建

DEB 安装包声明系统依赖，可使用桌面软件安装器或 apt 安装；tar.gz 为已编译应用目录，需要自行安装依赖后运行其中的 focubili。两者不是 AppImage，不保证在任意发行版直接运行。

源码构建需要 Flutter 3.44.6、Clang、CMake、Ninja、pkg-config，以及 GTK3、libmpv、libsecret、libjsoncpp、ALSA、WebKitGTK 4.1 的开发包。

```
flutter pub get
flutter analyze
flutter test
flutter build linux --release
bash tool/package_linux.sh
```

## 验证边界

Linux CI 会单独保存正常 release 安装包，再构建独立原生测试入口；测试入口不会进入用户安装包。测试覆盖本地合成视频、播放器操作、MPRIS、密钥环、通知、图片剪贴板、小窗恢复和网页登录窗口反复关闭。

本文件记录实现与验收计划，最终以对应提交的 CI 和运行诊断为准。合成素材与浏览器生命周期检查不等于真实账号登录、在线高码率视频、所有桌面环境或所有发行版兼容性均已实测。
