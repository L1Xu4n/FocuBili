# FocuBili v1.4.1 发布说明

发布日期：2026-08-16
版本号：`1.4.1+16`
Windows 包版本：`1.4.1.16`

<!-- focubili-update-summary:start -->
- 修复安卓端记笔记时会自动关闭输入法的问题。
- 修复观看记录不跳转的问题。
- 更改 Windows 调节画面亮度的逻辑，修复导致显示器亮度意外变化的问题。
- 扩展更新简报。
<!-- focubili-update-summary:end -->

## Android 笔记输入

- 自动保存期间不再禁用标题和正文输入框，软键盘与输入焦点会继续保持。
- 手动保存仍会锁定输入，避免重复提交；自动保存和手动保存使用独立状态。
- 自动保存期间继续产生的新输入会被标记，并在当前保存结束后补存，避免遗漏最后输入的内容。

## 观看记录与续播

- 从观看记录进入视频时，后端已经校验的播放位置不会再被详情接口中暂时缺失的分 P 时长清零。
- 页面内切换分 P 时会读取目标 CID 自己的播放记录，不再强制从零开始。
- Windows 为每个 `BV + CID` 独立保存进度，并兼容迁移旧版仅按 BV 保存的单槽记录。
- 外部 DASH 音轨完成解码后会再次校正续播位置，避免音轨加载把画面拉回开头。

## Windows 画面亮度

- Windows 播放器不再调用显示器硬件亮度接口。
- 亮度手势改为播放器内部黑色遮罩，只调暗当前视频画面，不影响系统和外接显示器亮度。
- 移除 `screen_brightness` Windows 插件及生成的插件注册项。

## 更新简报

- GitHub Release 摘要解析器不再收集三条后停止，会保留标记区内的全部有效条目。
- 关于页会展示全部更新简报；冷启动提示保留第一条和“查看”入口，并继续使用去重、Markdown 清理和单条长度保护。

## 产物与校验

### Windows x64 EXE 安装器

- 文件：`FocuBili-v1.4.1-windows-x64-setup.exe`
- 大小：待正式构建后填写。
- SHA-256：待正式构建后填写。
- 使用：按当前用户安装到本机，不需要管理员权限；提供开始菜单入口、可选桌面快捷方式和标准卸载程序。
- 签名：当前候选包未使用商业代码签名证书，Windows 可能显示“未知发布者”，但不需要导入测试根证书。

### Windows x64 便携版

- 文件：`FocuBili-v1.4.1-windows-x64-portable.zip`
- 大小：待正式构建后填写。
- SHA-256：待正式构建后填写。
- 使用：完整解压后运行目录内的 `FocuBili.exe`，不能只复制单个 exe。

### Android APK

- 文件：`FocuBili-v1.4.1-android.apk`
- 大小：待正式构建后填写。
- SHA-256：待正式构建后填写。
- 版本：`1.4.1 (16)`；包名：`com.focubili.app`；最低 Android 7.0 / API 24。
- 签名：待正式构建后校验；当前项目仍沿用 Android Debug 证书签署 Release，不适合作为应用商店正式签名。

### 未公开分发的 Windows MSIX

- MSIX 候选包仅使用测试证书，证书链不受 Windows 信任，因此本次正式 Release 不包含 MSIX，也不会要求用户导入测试根证书。

## 已完成验证

- `dart format --output=none --set-exit-if-changed lib test`：223 个 Dart 文件格式检查通过。
- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub`：444 项全部通过。
- Android `:app:testDebugUnitTest`：使用 Android Studio JDK 21 构建并全部通过。
- 待完成 Android 与 Windows Release 构建、产物校验和实机冒烟。

## 已知边界

- EXE 安装器消除 Windows“未知发布者”提示仍需要可信代码签名证书。
- 正式 MSIX 安装、升级和卸载验收必须等待可信代码签名证书或 Microsoft Store 签名，当前不会向用户分发测试签名 MSIX。
- Android Release APK 当前由 Debug 证书签署，不适合作为应用商店正式签名。

## 发布顺序

正式发布严格执行：本地提交 → 普通 SSH push 到 `dev` → 合并到 `master` → 构建正式产物 → 创建 Release。本次 GitHub Release 只提供 Android APK、Windows x64 EXE 安装器和 Windows x64 便携 ZIP。
