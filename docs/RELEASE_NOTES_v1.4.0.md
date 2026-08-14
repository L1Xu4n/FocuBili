# FocuBili v1.4.0 发布说明

发布日期：2026-08-14
版本号：`1.4.0+15`
Windows 包版本：`1.4.0.15`

<!-- focubili-update-summary:start -->
- 正式发布 Windows 端。
- 添加循环播放和定时关闭功能，支持从 B 站分享到焦点哔哩后直接跳转。
- 进行了一些代码重构。
<!-- focubili-update-summary:end -->

## Windows 客户端

- 标准 Win32 Runner，默认 `1280×800`、最小 `900×640`、居中启动，并通过原生互斥锁阻止重复实例。
- 使用 `media_kit` / libmpv 播放 B 站 DASH 视频与独立音轨，支持画质、倍速、进度恢复、截图、备用 CDN、音量和亮度控制。
- 播放地址只接受 B 站视频 CDN 的 HTTPS 地址，并拒绝用户信息、自定义端口和 URL 片段。
- 字幕与弹幕由桌面 Dart 服务读取；字幕主机、响应大小、弹幕分段大小和 Protobuf 字段都有边界限制。
- 使用 B 站官方二维码接口登录，不读取密码或验证码；确认后的 Cookie 写入 Windows 加密凭据存储。
- 播放器支持空格、方向键、`F` 与 `Esc`，全屏会同步切换真实 Windows 窗口。
- 专注完成和未来提醒接入 Windows Toast；系统能力页不会混用 Android 的精确闹钟、勿扰或后台权限说明。
- 播放缓冲只写入应用专属目录，支持容量统计、五档上限、按旧到新裁剪和安全清空。
- 更新检查优先选择本项目 Release 中的 MSIXBundle、MSIX 或 EXE；不安全或不匹配的资产会回退到 Release 页面。
- 增加无需管理员权限的简体中文/英文 EXE 安装器，提供开始菜单入口、可选桌面快捷方式、稳定升级身份和标准卸载项。

## Android 兼容性

- Windows 通知依赖同时包含 Android 实现，因此项目已按插件要求启用 core library desugaring，并把 Java/Kotlin 目标统一为 11。
- Android 继续使用现有 Media3、WebView Cookie、AlarmManager、勿扰、画中画和缓存链路，不改用 Windows 后端。
- Android 已注册系统文本分享入口；从 B 站分享标准链接或 `b23.tv` 短链时，可展开目标并直接进入焦点哔哩播放器。

## 播放体验与代码重构

- 播放器新增当前分 P 循环播放，以及按分钟或播放次数定时暂停；互动视频仍优先显示剧情选择。
- 首次打开、搜索、学习清单和观看历史统一通过续播计划决定分 P 与位置，避免就绪后再次跳转。
- Android、Windows 与 Flutter 观看历史采用一致的完播边界，并串行保存进度，降低旧异步状态覆盖新位置的风险。

## 产物与校验

### Windows x64 EXE 安装器

- 文件：`FocuBili-v1.4.0-windows-x64-setup.exe`
- 大小：27,777,254 字节
- SHA-256：`4F241B0BA5C1B5712F6EE7E4CA397CE983ACF30783CD62DCDD855D45336471FB`
- 使用：按当前用户安装到本机，不需要管理员权限；提供开始菜单入口、可选桌面快捷方式和标准卸载程序。
- 签名：当前候选包尚未使用商业代码签名证书，Windows 可能显示“未知发布者”，但不需要导入测试根证书。

### Windows x64 便携版

- 文件：`FocuBili-v1.4.0-windows-x64-portable.zip`
- 大小：37,853,371 字节
- SHA-256：`DE81C02EB558AC2BB23F2D59F7109B89768FAE3969D6FCCD0B89C46432E984C7`
- 使用：完整解压后运行目录内的 `FocuBili.exe`，不能只复制单个 exe。

### Android APK

- 文件：`FocuBili-v1.4.0-android.apk`
- 大小：68,992,603 字节
- SHA-256：`1F48C7E7DEA4007137B54B327512DF4C39E1FA2C84127E1B01EC0D77951AAF76`
- 版本：`1.4.0 (15)`；包名：`com.focubili.app`；最低 Android 7.0 / API 24。
- 签名：APK Signature Scheme v2 校验通过；当前项目仍沿用 Android Debug 证书签署 Release，不适合作为应用商店正式签名。

### 未公开分发的 Windows MSIX

- MSIX 候选包仅使用测试证书，证书链不受 Windows 信任，因此本次正式 Release 不包含 MSIX，也不会要求用户导入测试根证书。

## 已完成验证

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub`：437 项全部通过。
- Android `:app:testDebugUnitTest`：全部通过；Android Release APK 使用 Android Studio JDK 21 构建成功。
- `dev` GitHub Actions 运行 `31779907888`：Dart 质量、Android Debug 和 Windows Debug 全部通过。
- Windows Release 为 `1.4.0+15`；便携 ZIP 共 53 个条目，主程序、Flutter 引擎、`app.so`、libmpv 与 VC 运行库齐全。
- Windows Debug 真实网络：公开搜索、视频详情、DASH 画面、控制层、自然播完和返回搜索页通过。
- Windows 官方扫码页：二维码生成成功；没有扫描、确认或写入测试账号会话。
- Windows v1.4.0 便携版：从独立目录启动、首页渲染和单实例保护通过。
- Windows v1.4.0 EXE 安装器：普通用户静默安装、同版本覆盖、程序启动、第二实例拦截和标准卸载全部返回成功；卸载后程序文件与卸载注册项均已移除。
- 原生窗口实测为 `1280×800`，在当前显示器工作区中心误差不超过 1 像素；150% DPI 下最小跟踪尺寸为 `1350×960` 物理像素，对应 `900×640` 逻辑像素。
- Android 16 / API 36 模拟器：ADB 覆盖安装成功，系统核对为 `1.4.0+15`，首页语义树和前台 Activity 正常，日志没有 Flutter/Android 致命异常。

## 已知边界

- EXE 安装器已经完成功能验收；消除 Windows“未知发布者”提示仍需要可信代码签名证书。
- 正式 MSIX 安装、升级和卸载验收必须等待可信代码签名证书或 Microsoft Store 签名，当前不会向用户分发测试签名 MSIX。
- Android Release APK 当前由 Debug 证书签署；本次构建时没有 ADB 在线设备，因此未对这一个最终 APK 重做安装冒烟。
- Windows 当前隐藏未实现的画中画入口；浏览器 `focubili:` 协议尚未注册。
- 已验证一支公开视频完整播放；备用线路实际故障切换和一小时以上长视频仍应继续在更多网络环境观察。
- 真实账号最终扫码确认、收藏/关注/订阅读取需要用户自愿登录后验收，开发测试不会代替用户扫码。

## 发布顺序

正式发布严格执行：本地提交 → 普通 SSH push 到 `dev` → 合并到 `master` → 构建正式产物 → 创建 Release。本次 GitHub Release 只提供 Android APK、Windows x64 EXE 安装器和 Windows x64 便携 ZIP。
