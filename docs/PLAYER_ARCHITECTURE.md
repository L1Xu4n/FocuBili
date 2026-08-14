# 播放器代码结构与维护规则

更新日期：2026-08-11

这份文档用于避免播放器重新退化成单个超大文件。修改播放功能前，应先确认代码属于下面哪一层。

## 1. Flutter 播放页分层

- `lib/features/player/player_page.dart`：页面依赖装配、共享状态、Flutter 生命周期和最终 `build` 委托。经过后续功能增长曾达到 7,099 行，持续拆分后现为 380 行。
- `lib/features/player/player_collection_sheet.dart`：UGC 合集搜索、排序、定位和条目列表。
- `lib/features/player/player_layout_widgets.dart`：折叠播放器头、全屏设备状态栏、详情小组件和滚动文字。
- `lib/features/player/player_danmaku_rendering.dart`：弹幕车道规划、位置计算和 Canvas 绘制。
- `lib/features/player/player_playback_session.dart`：平台无关的播放初始化、状态订阅、快照同步、清晰度确认、续播恢复和错误重试。
- `lib/features/player/player_learning_coordinator.dart`：学习清单加入/移除、分 P 进度、观看记录、完播标记和继续学习。
- `lib/features/player/player_focus_coordinator.dart`：专注状态同步、视频关联、快进去抖、结束暂停、退出保护、最后画面和专注面板。
- `lib/features/player/player_gesture_coordinator.dart`：双击快进/暂停、长按三倍速、横滑预览跳转、竖滑亮度/音量、系统手势安全区和中央反馈状态。
- `lib/features/player/player_notes_workspace.dart`：播放器内笔记状态、自动保存、跨分 P 截图、删除、竖屏面板和全屏面板。
- `lib/features/player/player_viewport_coordinator.dart`：设备方向、Android 系统栏、横竖屏自动全屏和 Windows 窗口全屏。
- `lib/features/player/player_overlay_coordinator.dart`：字幕轨道、弹幕片段、失败退避、分段缓存、时间轴和弹幕设置。
- `lib/features/player/player_controls_coordinator.dart`：播放命令、控制层显隐、进度、倍速、清晰度、选集状态、键盘、画幅和画中画。
- `lib/features/player/player_video_coordinator.dart`：分 P、章节、互动剧情、合集视频、UP 主页面和嵌套播放器恢复。
- `lib/features/player/player_controls_view.dart`：选集、更多菜单、视频画面缩放和加载/错误状态。
- `lib/features/player/player_feedback_view.dart`：横滑预览、学习完播和互动剧情反馈层。
- `lib/features/player/player_details_view.dart`：视频统计、简介、学习清单按钮、富文本提及和外链确认。
- `lib/features/player/player_collection_view.dart`：合集预览、UP 主资料和非全屏详情组合。
- `lib/features/player/player_page_view.dart`：播放器画面、控制层、响应式工作台和最终页面骨架的同库视图扩展。
- `lib/features/player/widgets/player_control_widgets.dart`：选集、清晰度、倍速和图标按钮共用的尺寸与文字基线。
- `lib/features/focus/player_focus_sheet.dart`：播放器专注表单和视频关联确认面板。

十七个拆出文件使用 Dart `part`，目的是让现有私有类型保持同一 library；九个协调器 mixin 都受 `State<PlayerPage>` 约束，并显式声明依赖。控制协调器在播放、专注、手势、笔记、视口和叠加层之后应用；视频协调器最后应用，并实现前面协调器要求的分 P 与视频切换能力。五个视图 extension 只组合 Widget，不直接拥有计时器或平台资源。控制栏组件使用普通 import，已经形成可复用边界。

`player_page.dart` 不再接收新的控制、导航或详情业务函数。新增功能必须先判断属于现有协调器、视图或可复用组件；只有服务装配、跨模块共享状态和 Flutter 生命周期可以留在主文件。任一播放器文件超过约 900 行时必须重新审计职责，不能通过换文件名掩盖新的大文件。

## 2. Android 原生播放层

- `NativePlaybackController.kt`：Media3 生命周期、播放数据请求、音视频合并、进度、缓存、字幕和弹幕原始数据。
- `PlaybackTrackPolicy.kt`：编码兼容优先级与缓存键清洗，不应再散落回主控制器。
- Media3 各模块必须保持相同版本，当前统一为 `1.10.1`。

部分 B 站视频会同时返回 AVC/H.264 和 HEVC。当前策略优先 AVC；这是为了避免异常 HEVC 初始化数据在提取器中触发 `HevcConfig.parseImpl` 越界。AVC、HEVC 和音频使用包含编码名称的不同缓存键，防止旧编码数据污染新轨道。

## 3. 控制栏对齐规则

- 所有底栏文字入口必须使用 `PlayerControlLabel`，固定高度 34、字号 11、`height: 1`。
- 图标入口必须使用 `PlayerCompactIconButton`，固定为 34×34。
- “选集”必须使用 `PlayerPartSelectorButton`，不能重新使用带默认视觉边距的 `TextButton`。
- 修改后必须运行“全屏选集从右侧展开并切换分P”测试；测试会比较选集与清晰度菜单的垂直中心。

## 4. 后续拆分顺序

1. [已完成] 把时间点笔记编辑、列表和截图流程迁移到 `player_notes_workspace.dart`。
2. [已完成] 把横滑、竖滑、双击和长按倍速迁移到 `player_gesture_coordinator.dart`。
3. [已完成] 把播放会话初始化、快照同步、重试和进度恢复迁移到 `player_playback_session.dart`。
4. [已完成] 把专注播放状态、关联确认和最后画面保存迁移到 `player_focus_coordinator.dart`。
5. [已完成] 把学习清单、观看记录和完播进度迁移到 `player_learning_coordinator.dart`。
6. [已完成] 把系统栏、设备方向和桌面全屏生命周期迁移到 `player_viewport_coordinator.dart`。
7. [已完成] 把字幕轨道、弹幕片段加载和配置持久化迁移到 `player_overlay_coordinator.dart`。
8. [已完成] 把播放器画面、控制层和响应式页面骨架迁移到 `player_page_view.dart`。
9. [已完成] 把播放命令、选集状态、键盘和画幅设置迁移到 `player_controls_coordinator.dart`，并把控制 Widget 迁移到 `player_controls_view.dart`。
10. [已完成] 把分 P、互动剧情、章节、合集切换和嵌套页面恢复迁移到 `player_video_coordinator.dart`。
11. [已完成] 把详情视图继续拆成反馈、元数据和合集三个独立 extension，避免产生新的近千行视图文件。
12. [下一步] 把字幕与播放数据网络解析从 `NativePlaybackController.kt` 迁移到只读数据源类。
13. 每次只迁移一个边界，保持原测试通过后再继续下一层。

## 5. 回归命令

```powershell
dart analyze lib test
flutter test
flutter build apk --debug
```

原生轨道策略测试需要使用 Android Studio JBR 11 以上运行 Gradle；本机系统默认 Java 8 不能直接运行当前 Gradle。
