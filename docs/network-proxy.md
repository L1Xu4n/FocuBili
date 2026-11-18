# 代理设置

入口：个性化设置 → 外观与应用 → 代理设置。新安装和没有该设置的升级用户默认**跟随系统**。

- **跟随系统**：按目标 URL 查询操作系统的首选代理，保留支持的绕过规则。
- **直接连接**：显式关闭应用 HTTP 代理，不继承 `http_proxy`；不会关闭 VPN、TUN 或操作系统的 IP 路由。
- **手动 HTTP 代理**：填写主机名、IPv4 或 IPv6 和 1–65535 端口。HTTPS 目标通过 HTTP CONNECT 隧道连接。
- 保存后完全退出并重启应用。正在播放、下载、运行的前台任务不热切换。Android 同一进程中的前台与后台 Flutter 引擎共享首份启动配置，避免后台任务意外改动播放器。

只支持**不需要认证的 HTTP 代理**。不支持 SOCKS、HTTPS-to-proxy 或代理用户名/密码。地址字段拒绝 URL、账号密码、路径、控制字符和代理指令注入。配置只保存于本机一个偏好键，不进入设置迁移、统一导出或诊断信息。正常 TLS 校验保持开启；播放器显式启用 `tls-verify`，不会模仿关闭证书校验的调试代理做法。

## 实际覆盖范围

| 链路 | 行为 |
| --- | --- |
| Dart API、图片、二维码登录、短链接、更新、字幕、下载 | 启动前安装 `HttpOverrides`，逐请求异步解析代理；自动和显式重定向重新解析，跨源敏感头剥离 |
| 后台订阅 | Android 和 Apple 后台入口在发请求前初始化配置；Android 插件自动注册解析器 |
| Android Media3、原生 URLConnection API | 应用进程的 `ProxySelector` 使用同一启动配置，逐 URL 解析 |
| Windows/Linux/macOS/iOS media-kit | 打开媒体前应用音视频共同的首选代理，串行化代理属性与媒体打开，防止旧异步结果覆盖新视频 |
| WebView 账号密码登录、外部浏览器 | 使用各自系统网络栈，不受应用的手动/直接连接选项控制 |

代理连接失败不会自动降级为 DIRECT，也不尝试 OS 返回的后备代理。损坏配置或无法解析的系统策略会阻止相关请求，用户可在设置页重新选择后重启。系统代理不是流量匿名化保证，HTTP 目标和 CONNECT 目的主机仍可被代理看到。

## 平台边界

- **Windows**：当前用户的 Windows Internet 代理配置，支持静态按协议代理、绕过列表和 WinHTTP PAC/WPAD。PAC 解析不自动向服务器发送 Windows 登录凭据；明确配置 PAC 失败不会悄悄直连。WPAD 未发现配置且系统没有静态代理时可直连。原生解析在工作线程运行。
- **Android**：委托原系统 `ProxySelector`，包括系统可解析的 PAC。监听系统代理变化，重新安装应用策略，不修改设备代理设置。无效的首次配置阻断原生网络，同进程其它引擎继承已激活快照。
- **macOS / iOS**：通过 CFNetwork 读取静态 HTTP 代理及绕过规则。**暂不执行 PAC 脚本**；命中自动代理配置时明确失败，需改为手动 HTTP 代理。无法使用需要认证的代理。
- **Linux**：使用 GIO 桌面代理后端。DEB 增加 `glib-networking` 运行依赖；裸目录/其它打包方式需自行提供带 libproxy 支持的 GIO 后端。若仅有总是返回 DIRECT 的 dummy 后端，使用明确设置的 HTTP(S)/ALL_PROXY 和 NO_PROXY 环境变量；没有后端也没有显式环境配置时提示缺少解析器，不冒充已读取系统设置。
- **桌面及 Apple 媒体限制**：mpv 的代理选项对一个播放实例生效。初始视频和音频必须选中同一个代理，否则拒绝播放。媒体内部重定向、manifest/分段请求沿用此代理，不能逐 URL 重新求值系统 PAC/绕过规则。此类复杂配置应改用统一手动 HTTP 代理或系统 VPN/TUN。
- **FFmpeg 环境限制**：`http-proxy` 为空不足以禁用继承的 `http_proxy`，因此同时显式设置 `stream-lavf-o=http_proxy=`。FFmpeg 的小写 `no_proxy` 直接读取进程环境，不能通过 AVOption 清除；当需要代理且该变量非空时拒绝播放并提示移除变量后重启，避免无意绕过代理。不修改用户或系统环境变量。

## 设计与参考

参考 PiliPlus 的设置入口、主机/端口及重启生效交互，代码按 FocuBili 的多套网络栈独立实现。PiliPlus 当前 `enableSystemProxy` 实际使用手工填写的 HTTP 代理，默认关闭；本实现将“跟随系统”与“手动代理”分开，并按用户要求默认选择前者。

- [PiliPlus 代理设置](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/e3aff4435e0df6d703b359b6999c6aa41a4fd678/lib/pages/setting/models/extra_settings.dart)
- [PiliPlus 网络适配器](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/e3aff4435e0df6d703b359b6999c6aa41a4fd678/lib/http/init.dart)
- [Dart HttpClient](https://api.dart.dev/dart-io/HttpClient-class.html)
- [WinHttpGetProxyForUrl](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpgetproxyforurl)
- [GIO ProxyResolver](https://docs.gtk.org/gio/iface.ProxyResolver.html)
- [mpv HTTP/FFmpeg 参数处理](https://github.com/mpv-player/mpv/blob/master/stream/stream_lavf.c)
- [FFmpeg HTTP 环境代理处理](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/http.c)

Dart 的 `findProxy` 回调是同步的，而平台查询是异步的，故 `RoutingHttpClient` 在建连前求值、按路线复用客户端，并自己处理重定向。它不替换证书上下文、不截获请求正文、不记录 URL、Cookie 或代理密码。所有新增网络测试使用本机合成 HTTP/CONNECT 服务，不使用真实账户。

## 验证范围

自动化测试覆盖设置默认值、持久化与失败、无效地址/端口/凭据、系统路由解析失败、真实 loopback HTTP/CONNECT、逐跳重定向、关闭与过时异步结果、表单重复保存及窄屏布局。Android 另有纯 JVM `ProxySelector` 与真实 URLConnection/本机代理测试；桌面解析器有独立可执行检查。

2026-11-05 最终本地检查：Flutter 3.47.5 / Dart 3.13.4，全量测试 1797 通过、3 跳过、0 失败；526 文件格式检查无改动，静态分析无问题。新增代理焦点测试 114 项，另有可选截图生成测试。

本轮云端环境可运行 Dart/Flutter 和纯 Kotlin/JVM，不能替代 Windows、Android 设备或 Apple SDK 的原生编译与端到端代理验证。PR 保持 draft，跨平台构建结果和尚未执行的原生验证在 PR 描述中单独列明。
