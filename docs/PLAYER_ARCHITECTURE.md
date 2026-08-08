# 播放器代码结构与维护规则

更新日期：2026-07-18

这份文档用于避免播放器重新退化成单个超大文件。修改播放功能前，应先确认代码属于下面哪一层。

## 1. Flutter 播放页分层

- `lib/features/player/player_page.dart`：页面状态编排、播放服务调用、手势和路由生命周期。主文件已从约 5900 行降到约 4900 行。
- `lib/features/player/player_collection_sheet.dart`：UGC 合集搜索、排序、定位和条目列表。
- `lib/features/player/player_layout_widgets.dart`：折叠播放器头、全屏设备状态栏、详情小组件和滚动文字。
- `lib/features/player/player_danmaku_rendering.dart`：弹幕车道规划、位置计算和 Canvas 绘制。
- `lib/features/player/widgets/player_control_widgets.dart`：选集、清晰度、倍速和图标按钮共用的尺寸与文字基线。
- `lib/features/focus/player_focus_sheet.dart`：播放器专注表单和视频关联确认面板。

前三个拆出文件使用 Dart `part`，目的是让现有私有类型保持同一 library，先完成低风险物理拆分；新控制栏组件使用普通 import，已经形成可复用边界。

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

1. 把时间点笔记编辑、列表和截图预览迁移到独立的 `player_notes_*` 文件。
2. 把横滑、竖滑、双击和长按倍速整理为独立手势协调器。
3. 把字幕与播放数据网络解析从 `NativePlaybackController.kt` 迁移到只读数据源类。
4. 每次只迁移一个边界，保持原测试通过后再继续下一层。

## 5. 回归命令

```powershell
dart analyze lib test
flutter test
flutter build apk --debug
```

原生轨道策略测试需要使用 Android Studio JBR 11 以上运行 Gradle；本机系统默认 Java 8 不能直接运行当前 Gradle。
