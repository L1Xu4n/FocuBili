# 播放器、用户搜索、笔记导出与专注分享维护说明

更新日期：2026 年 7 月 19 日

## 1. 播放器新增行为

- 长按播放画面临时切换到 3 倍速，松手或手势取消后恢复原速度。
- 倍速菜单包含 `0.75x / 1x / 1.25x / 1.5x / 2x / 3x`。
- 全屏左侧控制锁开启后，其他按钮和画面手势全部停用；按系统返回键会先解锁。
- 全屏横向拖动在左右各保留至少 48dp 安全区，底部同时避开系统导航区域。
- 播放页横屏自动进入全屏，自动全屏转回竖屏时自动退出；笔记面板打开期间不执行自动切换。
- 竖屏播放器底栏不使用整机底部导航 inset，只有真正全屏时才使用。
- 双击快进快退偏好位于“我的 → 设置”，默认开启；关闭后任意区域双击都是播放/暂停。

相关文件：

- `lib/features/player/player_page.dart`
- `lib/models/playback_preferences.dart`
- `lib/services/playback_preferences_service.dart`
- `lib/features/profile/personalization_settings_page.dart`

## 2. 简介与用户搜索

视频详情优先解析 `desc_v2`。普通片段按正文显示，带 `biz_id` 的提及片段显示为主题蓝色，点击时把该 MID 交给 `UserProfilePage`。正文中的 HTTP(S) 地址也会拆成蓝色下划线片段；点击先展示完整地址与离开应用风险，确认后才通过 `url_launcher` 唤起默认浏览器。旧接口没有 `desc_v2` 时仍显示普通简介。

视频简介和 UP 主签名都使用真实文本测量决定是否显示展开按钮；UP 主页认证说明保留独立的蓝色认证行，避免与签名混在一起后被截断。

搜索页通过独立的 `BilibiliUserSearchService` 增加用户搜索，避免破坏只实现视频查询的旧测试替身。用户结果支持综合、粉丝数、等级排序和账号类型筛选。

相关文件：

- `lib/models/user_search.dart`
- `lib/models/video_preview.dart`
- `lib/services/bilibili_service.dart`
- `lib/features/search/search_page.dart`
- `lib/features/profile/user_profile_page.dart`

## 3. 笔记导出与分享格式

无截图时直接保存 `.md` 或 `.json`。存在可读取截图时，系统保存 `.zip`：

```text
focubili_notes_时间戳.zip
├─ focubili_notes.md（或 focubili_notes.json）
├─ README.txt
└─ images/
   └─ 笔记ID.png
```

Markdown 使用相对图片路径。JSON 根对象包含：

- `format: "focubili.video_notes"`
- `version: 1`
- `exportedAt`
- `notes`

JSON 中的 `framePath` 改为包内相对路径，不泄露 Android 应用私有绝对路径。笔记列表进入多选后可选择系统“另存为”或把同一导出包交给系统分享面板。当前版本未实现回导；后续回导应校验版本、重复 ID、路径穿越和图片缺失后再写入。

笔记详情页另外提供 PNG 长图分享。卡片固定宽度、正文高度自适应，包含标题、完整正文、BV、视频标题、分P、视频时间点、字数及可选截图；捕获时会根据长图高度动态降低像素倍率，避免常见移动 GPU 纹理上限导致生成失败。

## 4. 专注统计与分享

分享卡使用 `RepaintBoundary` 在本机渲染为 PNG，再通过系统分享面板发送。图片生成过程不访问开发者服务器。专注统计页和分享图都绘制完整纵轴时长刻度，并按画布宽度抽样横轴日期；分享图不绘制数据圆点。单次完成分享卡显示“今日专注时长”和“累计专注时长”。

依赖选择：

- `archive 4.0.9`：创建带图片的 ZIP。
- `file_picker 11.0.2`：调用系统“另存为”。
- `path_provider 2.1.6`：定位分享临时目录。
- `share_plus 11.1.0`：调用系统分享面板。项目当前 Android 构建链为 AGP 8.11.1；`share_plus 12+` 要求 AGP 8.12.1 与 Kotlin 2.2，因此暂不跨越该构建链边界。

相关文件：

- `lib/services/video_note_export_service.dart`
- `lib/services/video_note_share_service.dart`
- `lib/features/notes/video_note_share_preview.dart`
- `lib/services/focus_share_service.dart`
- `lib/features/focus/focus_share_preview.dart`

## 5. 关于与更新检查

“我的 → 设置 → 关于”从安装包元数据读取当前版本。启动检查开关保存在本机；启用时每次启动访问 `https://api.github.com/repos/L1Xu4n/FocuBili/releases/latest`，只比较 GitHub 最新正式 Release，不下载、不静默安装。发现更高语义版本后，“我的”设置入口与关于页显示红点，用户确认后由默认浏览器打开 Release 页面。

更新失败、GitHub 限流或响应格式异常都会转换为界面文字，不影响应用启动。`package_info_plus` 固定在兼容当前 AGP 8.11.1 的 8.3.x；9+ 当前要求 AGP 8.12.1，因此不要在未同步升级 Android 构建链时直接跨主版本。

相关文件：

- `lib/services/app_update_service.dart`
- `lib/features/profile/about_page.dart`
- `lib/features/profile/personalization_settings_page.dart`

## 6. 本轮验证结果

- `dart analyze lib test`：通过，无静态问题。
- `flutter test test/widget_test.dart`：49 项通过。
- `flutter test`：全项目 191 项通过。
- `flutter build apk --debug`：成功，产物为 `build/app/outputs/flutter-apk/app-debug.apk`。
- Android 15 模拟器 `emulator-5554`：覆盖安装和启动成功，首页、个性化设置、用户搜索模式完成冒烟验证。
- 收尾时 `flutter_tester.exe`：0 个。

项目通过 `X:` 映射盘构建时，Kotlin 增量缓存可能提示 Pub 缓存位于 `C:`、工程位于 `X:`，随后自动改用非增量编译。只要命令最终显示 `Built ...app-debug.apk` 且退出码为 0，APK 就已经成功生成；这类缓存提示不等同于应用编译失败。
