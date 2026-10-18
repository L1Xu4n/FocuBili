# 1.8 播放器与自定义布局变更

范围：part1 15、17、18、19、23、30。基线为 `5e128bdd1952b3f619500f69aa7bc8c33a88d0b4`，包含 1.7.1 安全修复和 Beta5 缓存修复；之后 fast-forward 接入集成设置提交 `0abe1ac`。

## 实现

- 整个卡片棋盘接收拖拽，真实指针命中卡片间隙并计算前后插入；保留拖动占位、短位移动画、外层边缘滚动和保存失败恢复；放手到保存完成期间保持新顺序，避免闪回。
- 顶部倍速/续播/短消息，中央方向/播放/亮度/音量反馈，底部字幕/完成操作使用独立空间。按真实控制栏高度避让，触摸透传不变；普通短消息在独立计时结束后用 160ms 淡出、收拢，后续卡片连续移动。
- 画面双击播放/暂停和侧滑亮度/音量保持当前控制栏状态；系统取消侧滑后同样清理提示并恢复原有自动隐藏。长按倍速异步完成有请求代次校验，防止松手后的迟到回包把 UI 改回临时倍速。
- 紧凑笔记预览使用原图比例和 contain，不再固定 16:9/cover，预览高度限制在 108–280px。
- 展开和收起的进度条使用同一缓冲段数据。Media3 报告当前连续已缓冲区间；桌面读取 mpv 实际 seekable-ranges，合并重叠区间并保留 seek 留下的空隙，不用已播放比例或下载字节数伪造缓冲。
- 未改字幕会话/账号隔离、听视频画面分层、磁盘缓存软阈值和现有保留/锁定策略。

## 验证边界

- 最终定向 44 项通过，涵盖迟到倍速回包、缓冲/方向避让和保存期间无闪回；全量 Flutter 920 通过 / 1 环境跳过 / 0 失败，静态分析 0 问题；详细记录见 validation.json。
- 最终 4 项截图回归通过并生成/目视检查 5 张 PNG；PNG 为真实 Flutter PlayerPage/编辑器的渲染，使用替身解码器或合成图片，**不是设备播放验收**。截图中的 SYNTHETIC VIDEO FIXTURE 是明确的测试素材标识。
- `native-buffer-result.json` 来自此电脑实际 libmpv + loopback MP4：4023ms 媒体推进到 490ms，实际返回 0–3994ms 缓冲段。该探针没有 UI，不等同整页实播。
- Windows 整页实播测试已提供 `integration_test/player_windows_v18_test.dart`，目前 Debug 构建未通过：先遇到受限账户下 MSBuild FileTracker E_ACCESSDENIED，任务局部关闭可选增量追踪后进入编译；最终现有 Windows 插件出现 `_CrtDbgReport`/`_calloc_dbg` 等 Debug CRT 链接错误。未改系统权限、工具链安装或产品插件以隐藏失败。
- `adb devices -l` 当前无设备。Android 真机、Apple、Linux 原生缓冲/UI及真实B站视频尚未验收；Android Kotlin 编译由最终集成构建再次确认。
- mpv 官方文档说明 seekable-ranges 仅涵盖主解复用器；独立音轨可能仍需读取网络，所以灰色缓冲段不承诺完整音视频离线可用：[mpv demuxer-cache-state](https://mpv.io/manual/master/#command-interface-demuxer-cache-state)。

## 截图

- `player-mobile-seek.png` / `player-desktop-seek.png`：实际页面的方向反馈避让和边缘位置。
- `player-speed-and-volume.png`：倍速保持顶部，音量独立居中。
- `note-portrait.png` / `note-landscape.png`：两种原图的完整预览。

## 仍需人工测试

| 场景 | 操作 | 预期 |
|---|---|---|
| 首页/我的拖拽 | 单列/多列中把卡片拖到间隙，反向拖回，靠上下边缘移动，重启 | 每次响应插入，排序持久化，无来回抖动 |
| 双击方向反馈 | 短/长真实视频，连续快进、反向快退，横竖屏和缩放窗口 | 数值正确累加或重置，方向动画不偏移、不越栏 |
| 多提示 | 保持长按倍速，同时触发音量/亮度/续播等提示，再逐条到期 | 倍速留在顶部，各条独立快速淡出，字幕不被压住 |
| 控制栏 | 先隐藏控制栏，再侧滑调节和双击暂停/播放 | 控制栏不被这些手势呼出；单击仍可显示 |
| 自定义长按 | 设置为 2.5 倍，普通播放先设为 1.25 倍，长按后松手 | 长按期间 2.5 倍，松手恢复 1.25 倍，提示使用正确数值 |
| 笔记截图 | 竖屏视频插入当前帧，保存后重开；再测横屏 | 上下内容完整，原图比例保留 |
| 缓冲条 | 网络流等待缓冲，再跳到远处、换分P/清晰度、听视频切换 | 灰色段对应后端实际缓冲，空隙不被填满，旧源区间及时清除 |

## 复现

```text
flutter test test/editable_card_board_test.dart test/player_feedback_layout_test.dart test/player_action_feedback_test.dart test/player_v18_gestures_test.dart test/playback_buffer_range_test.dart test/video_note_composer_layout_test.dart test/player_note_flags_test.dart
flutter test test/player_v18_visual_test.dart --dart-define=PLAYER_CAPTURE_DIR=docs/reviews/v180-player
flutter test integration_test/player_windows_v18_test.dart -d windows
# 可指定本机既有 libmpv 路径，不下载用户数据：
dart run tool/player_buffer_probe.dart <libmpv-path>
```

长按倍速设置模型由集成任务维护，已纳入 `0abe1ac` 并接通 `PlaybackPreferences.longPressPlaybackSpeed` 的读取和提示文案；新增 2.5 倍速与松手恢复测试。无需消费者补丁。


## 公开分支的截图范围

本地生成的审查截图不随本公开分支上传。它们只保留在本机原始恢复分支和证据目录；文中的PNG文件名用于本地复现。应用代码和原有公开资源不受影响。自动审批拒绝了本地图像导出，未通过其他编码或引用方式公开被拒绝的图片。
