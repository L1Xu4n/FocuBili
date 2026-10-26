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

DEB 安装包声明系统依赖，建议使用 apt 安装，以便看到具体的依赖错误。先在下载目录检查实际包，再模拟安装；确认没有异常卸载或降级计划后执行安装：

```bash
cat /etc/os-release
dpkg --print-architecture
deb=./FocuBili-v1.8.1-linux-amd64.deb # 替换为实际文件名
dpkg-deb -f "$deb" Package Version Architecture Depends
apt -s install "$deb"
sudo apt install --no-remove "$deb"
```

应用中心的“未知错误”不足以定位原因；反馈时请附系统版本、架构、实际包文件名和上述模拟安装的完整错误输出，个人路径可以隐藏。若已安装但不能启动，请另外提供终端运行 `focubili` 的错误；安装失败与启动失败分别排查。不要通过强制忽略依赖、替换系统 glibc 或跨发行版混装库来安装。

tar.gz 为同一已编译应用目录，需要自行安装依赖后运行其中的 focubili。两者不是 AppImage，不保证在任意发行版直接运行。Ubuntu 22.04 不在支持范围内：现有正式版插件需要 `GLIBC_2.38` 和 `GLIBCXX_3.4.32`，只改依赖包名不能使它兼容；需要另行在旧系统重构建并验证。

打包使用 `dpkg-shlibdeps` 从 runner 及其链接的随包 ELF 库生成系统依赖和 ABI 最低版本，额外保留无法从 ELF 发现的桌面 portal 依赖与密钥环建议项。未链接的可选原生资产不自动转为启动依赖；新增 `dlopen`/FFI 后端时仍需检查相应运行时依赖。当前链接链不使用 JsonCpp，不再硬编码 `libjsoncpp25`。历史发布包的 control 不会随源码修改而改变，具体依赖以实际 DEB 元数据为准。

源码构建需要 Flutter 3.47.5 stable（自带 Dart 3.13.4）、Clang、CMake、Ninja、pkg-config、Python 3、binutils、dpkg-dev，以及 GTK3、libmpv、libsecret、ALSA、WebKitGTK 4.1 的开发包。依赖扫描须在目标构建发行版及其正常的软件包数据库中执行；不要在另一发行版上生成发行用 DEB 的依赖元数据。

Linux SDK 单独固定为 3.47.5；Android、Windows 和 Apple 工作流仍使用 3.44.6。3.44.x 的 X11 非共享 OpenGL 合成路径会在窗口尺寸变化时，用新窗口尺寸上传旧 framebuffer 的像素缓冲区，可能导致越界读取和 SIGSEGV。3.47.5 使用 framebuffer 本身的宽高上传，修复这一引擎问题；不通过等待、关闭软件渲染或强制 Wayland 绕过。

上游实现：[Flutter 3.47.5 fl_compositor_opengl.cc](https://github.com/flutter/flutter/blob/3.47.5/engine/src/flutter/shell/platform/linux/fl_compositor_opengl.cc)。

```
flutter --version # 必须确认 Linux 使用 3.47.5
flutter pub get
flutter analyze
flutter test
flutter build linux --release
bash tool/package_linux.sh
```

## 验证边界

2026-10-25 打包专项检查使用 `dd3ebb7`（v1.8.1+31）的官方已发布程序文件，仅重新生成 DEB 元数据；`/opt/focubili` 内容逐字节保持一致。新包在 Ubuntu 24.04、26.04 amd64 隔离容器中完成实际 APT 安装、共享库解析、普通账户 Xvfb 启动至用户协议页和单实例检查；25.10 仅通过 APT 模拟，22.04 被系统库与 ABI 约束明确拒绝。这不是一次 Linux 应用源码重编译，也不代表真实显卡、Wayland、登录、播放或 portal 文件访问已通过验证；主要支持目标仍为 Ubuntu 24.04。

Linux CI 会先安装生成的正常 DEB，通过 `/usr/bin/focubili` 检查基本启动和单实例，再构建独立原生测试入口；测试入口不会进入用户安装包。测试覆盖本地合成视频、播放器操作、MPRIS、密钥环、通知、图片剪贴板、小窗恢复和网页登录窗口反复关闭。暂停视频时额外重复六次缩小、恢复后立即打开 WebKit 的回归流程，随后验证 Flutter 窗口 metrics、完成的 raster frame 和截图尺寸；保留小窗进入时销毁、WebKit 关闭时仍有请求的中断测试。原生探针即使先输出成功标记，只要收到致命信号或没有正常退出，CI 仍会失败。

本文件记录实现与验收计划，最终以对应提交的 CI 和运行诊断为准。合成素材与浏览器生命周期检查不等于真实账号登录、在线高码率视频、所有桌面环境或所有发行版兼容性均已实测。
