# A–B 区间循环（1.9beta）

## 范围与交互

对应 [issue #62](https://github.com/L1Xu4n/FocuBili/issues/62)：作者希望在背单词、磨耳朵的视频里选择一段反复看、听。本文记录实现及本地自动化证据，不代表作者或真实设备已验收。

- 播放器“更多选项 → A–B 区间循环”打开设置面板。可用当前播放点标记 A、B，也可输入秒数、`分:秒`、`时:分:秒`；最多三位小数。B 至少比 A 晚 1 秒，且不能超过当前媒体时长。
- 启用后时间轴显示 A/B 和选区；点击选区可重新设置或清除。若当前位置在区间外，先跳到 A；暂停状态保持暂停。区间内播放到 B 回到 A。
- 暂停保留区间。手动进度、快进快退、字幕或笔记跳到区间外时清除区间，恢复原播放方式；区间内跳转继续循环。自动回跳走独立路径。
- 同视频同 CID 切换听视频、返回画面、切换清晰度时保留区间，等待已有 seek 完成，切换期间不回跳。暂态 `duration=0` 不清除；真实新时长使 B 失效时清除。
- 切分 P、切视频、外部视频路由或退出播放器清除。没有跨分 P、重启恢复、循环次数或全局偏好设置。
- A–B 活动期间临时接管完播，原整片循环开关、播放次数和已完成次数均保留。清除后原规则继续；若原先未开整片循环，则恢复普通播放。面板明确说明恢复方式。用户主动修改整片循环时先退出 A–B，再应用新选择。

## 接入与竞态

`AbRepeatRange` 仅持有本地 bvid/CID 身份和 A/B 时间。`_PlayerAbRepeatCoordinator` 使用现有 `PlaybackService.seekTo` / `play` 命令；播放快照补充可选的 `playRequested`，旧后端缺字段时按 null 兼容。不增加网络请求、课程鉴权请求或磁盘数据。

真实播放快照用于重算按倍速到 B 的定时器。暂停、loading、恢复进度与源切换不反复 seek。一个回跳在途时不发第二个；seek Future 完成后仍等待 A 点附近的新位置快照，防止旧 B 或 B 前快照立即再次回跳。新导航先取消代次并等待 seek drain，之后才修改媒体身份或打开新源；外部路由先 drain 再暂停，退出时也在 drain 后释放服务。

B 等于媒体末尾时先消费 ended，阻止普通整片循环、学习完播、次数累计和专注完播。`playing → ready(false) → ended` 以及 timer seek 中收到 ended 均有回归；后者最多补一次 play。显式暂停、后端睡眠定时到期、清除、切源、切章或退出会使迟到的续播失效。互动剧情的定时与 ended 提示也在 A–B 活动期间暂停接管。

专注仍使用原会话和现有 seek transition；循环不重新打开视频、不创建专注任务。已购课堂使用原 `cheese:ss...` 加 CID 身份，权限校验和账号栅栏没有变化。字幕和笔记跳转复用同一手动 seek 入口。

## 状态与证据

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| A/B 当前点、时间输入、边界与清除 | 实现；自动化通过 | `ab_repeat_test.dart`、实际 PlayerPage 设置面板 |
| 时间轴选区与移动/桌面大字布局 | 实现；自动化通过 | 4 张实际 Flutter 控件合成截图，未使用真实账号 |
| 320px 宽、160% 字号设置面板 | 自动化通过 | 两个当前点按钮、输入值、启用和清除均实际触达，无 overflow |
| 视频/听视频/课堂与清晰度切换 | 实现；自动化通过 | 合成后端的 loading/零时长/恢复快照 |
| 暂停、延迟 seek、末尾、切章、路由 | 实现；自动化通过 | PlayerPage + Completer 门控，核对 seek/play/媒体 CID |
| 字幕/学习/笔记/专注相邻兼容 | 自动化通过 | 定向兼容套件，非全量 |
| Android/Windows 实际解码、蓝牙、锁屏听视频 | 未做；真机通过：否 | 仍需人工检查原生事件频率、系统后台调度与 seek 精度 |
| 课程真实已购账号与受限媒体 | 未做；真机通过：否 | 不读取真实会话，沿用课程人工验收边界 |
| 多次循环次数、跨 P 持久化 | 未做（不在范围） | 无新增偏好或导出字段 |

环境：Windows，Flutter 3.44.6 / Dart 3.12.2，独立 `codex/v19-ab-repeat`，基于 `609fc32`。未构建 APK、未创建签名、未修改发布或工作流。仅使用现有 SDK 缓存运行 Flutter 测试。

命令（工作目录为本分支）：

```powershell
& C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/ab_repeat_test.dart test/player_ab_repeat_test.dart
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/ab_repeat_test.dart test/player_ab_repeat_test.dart test/refactor_r3_feedback_test.dart test/player_tap_gesture_test.dart test/focus_session_continuity_test.dart test/classroom_integration_test.dart test/clipboard_player_return_test.dart test/classroom_reopen_test.dart test/player_note_flags_test.dart
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub --dart-define=AB_CAPTURE_DIR=docs/v1.9/ab-repeat-evidence test/ab_repeat_evidence_test.dart
```

最终计数见下方交付记录；套件存在重叠，不将轮次相加。早期夹具曾把初始恢复位置设为零、用旧路由 API、在永久 loading 时等待 settle；已修正。一次真实缺陷为等待 seek 确认时仍接受旧的 B 前快照，现只接受 A 附近位置确认，相关回归保留。

合成截图：使用 Windows 已有 `msyh.ttc` 和 SDK MaterialIcons；测试表面并非真机截图，黑色画面是合成播放器。

- [手机时间轴](ab-repeat-evidence/ab-mobile-timeline.png)、[手机设置](ab-repeat-evidence/ab-mobile-sheet.png)：390×844。
- [桌面时间轴](ab-repeat-evidence/ab-desktop-large-text-timeline.png)、[桌面设置](ab-repeat-evidence/ab-desktop-large-text-sheet.png)：1280×800，文字缩放 1.3。

## 人工验收

1. 普通学习视频播放中设 A=10 秒、B=30 秒，确认反复回到 A；暂停超过 30 秒不回跳，继续后从实际位置重算。把 B 设为总时长，确认循环不触发学习完成。
2. 切到听视频并切回，确认 A/B、倍速、播放/暂停状态保留；Android 锁屏、后台、耳机暂停/恢复需真机核对。到睡眠截止时间必须保持暂停，不能被迟到回跳唤醒。
3. 点击字幕、笔记或拖动到区间内继续循环，到区间外清除。切到另一个分 P、另一视频或退出再进，确认没有旧 A/B。
4. 原整片循环关闭、原整片循环开启、原“播放 2 次后暂停”分别启用 A–B 后清除，确认恢复原选择，区间轮数不消耗整片次数。
5. 仅用本人已有权限的课堂账号主动打开已购章节，重复第 1–3 步；切账号后沿用课堂服务的停流与重新鉴权行为。不得使用未购内容进行绕权测试。

## 风险与限度

循环边界通过页面的真实快照和定时器协调，媒体实际 seek 及短暂超出 B 的精度依赖平台、流和系统调度，不保证采样级无缝循环。缺少新 A 位置确认时等待或让用户清除，不连续轰炸 seek。后台/锁屏和真实课堂媒体尚无本次设备证据，不能由合成测试推断已经通过。

## 最终交付记录

- 最后一次 `flutter analyze --no-pub`：0 问题。
- 最终定向兼容套件：40 项通过，其中 A–B 模型与真实 PlayerPage 21 项；涵盖退出播放器前等待在途 seek，原普通/整片循环及次数设置恢复。
- 设置面板/合成证据套件：3 项通过，包含 320px/160% 字号按钮触达，以及手机、桌面大字两种实际布局。
- 另对 `test/widget_test.dart` 分别以 `--plain-name 播放器循环播放` 和 `--plain-name 播放器播放指定次数` 运行现有整片循环/次数暂停回归，各 1 项通过。
- 四张 PNG 已实际查看，文本和按钮可见，没有截图裁切或控件溢出。`git diff --check` 通过。
- 早期 14/19/20 项与 38/39/40 项轮次互相重叠，不能相加。Flutter 测试全部使用合成播放后端；未运行应用读取真实账户。

## 独立审查后的两项 P2 修复

独立审查用两项实际 PlayerPage 合成序列复现了初版遗漏；已将原复现纳入 `test/ab_repeat_capture_lifecycle_test.dart`：

1. B 在片尾、seek 仍在等待时，Android 宿主进入后台直接暂停，初版迟到的 `play` 会唤醒媒体。现在页面 lifecycle 对后台普通视频撤销回跳续播；Android 快照取真正 `playWhenReady` 并监听 `onPlayWhenReadyChanged`，Windows 快照取现有 `_shouldPlayAfterFallback`。即使 isPlaying 在 ended/缓冲时一直为 false，也能识别原生/耳机暂停。合法 audioOnly / PiP 后台继续，不全局禁止后台听视频。
2. 仅选择 5 秒的旧笔记并保存截图，不属于用户跳转。现在捕帧使用独立 temporary scope：暂停 A–B 计时并 drain 已发出的回跳，内部目标/还原 seek 不走 manual 退出规则，同 CID 完成后保留区间。跨 CID 仍按原规则清除。还原 seek 发出前登记原位置与 source generation，必须见到新的还原位置快照才重新调度；Future 提前完成、旧 5 秒快照不会自动跳到 A=10 覆盖原 20 秒位置。

捕帧继续核对 bvid、草稿、导航、源代次，并增加手动 seek serial。捕帧期间用户主动跳转会取消旧位置还原，迟到截图执行 orphan 清理；后台普通视频或显式暂停也不能由捕帧收尾迟到续播。

追加验证：

```powershell
& C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/ab_repeat_capture_lifecycle_test.dart
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/ab_repeat_test.dart test/player_ab_repeat_test.dart test/ab_repeat_capture_lifecycle_test.dart test/notes_subtitles_widgets_test.dart test/classroom_integration_test.dart test/classroom_account_race_test.dart test/listening_playback_test.dart test/windows_source_identity_race_test.dart test/windows_playback_audio_lifecycle_test.dart test/focus_session_continuity_test.dart test/clipboard_player_return_test.dart
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
# android/ 下执行；只编译，不打包/签名
.\gradlew.bat :app:compileDebugKotlin --no-daemon
```

- 最终静态分析：0 问题。
- 扩大定向兼容：61 项通过；随后补全的复现/边界文件 8 项通过，包含两项原复现、前台/后台真实暂停信号、合法音频后台、旧 null-intent 音频后台、迟到位置确认和手动跳转/orphan 清理。轮次重叠，不相加。
- Android `:app:compileDebugKotlin`：成功，2 分 25 秒；未执行 APK 打包或签名任务。Gradle 的既有 Kotlin 插件/弃用警告未阻止编译。
- 此次没有视觉改动，沿用四张合成截图及 320px/160% 字号证据；真实设备与真实课堂验收仍未完成。

## 临时捕帧 seek 串行复核

第二轮只读审查发现：捕帧目标 seek 已发出但尚未完成时，手动拖动或切章只等待 A–B 自动回跳，旧捕帧命令仍可能晚到并覆盖新位置或落到新 CID。现在目标和还原 seek 都在调用后端之前登记命令级完成栅栏，手动跳转、切源、切章、外部路由和退出共同等待这些已发出的命令完成。仅等待实际 seek，不等待整次笔记保存，避免捕帧自身跨章和返回时自等待。

临时命令还校验捕帧 serial、导航代次、来源代次和 bvid/CID，撤销后的排队捕帧不能重新下发。新增回归分别门控 5 秒目标 seek 与 20 秒还原 seek：放行前不下发手动 90 秒命令、不打开新 CID；放行后手动位置最终为 90 秒，旧命令只在 CID 101 完成，切章随后才打开 CID 102。跨 CID 捕帧再返回的正向用例也通过，保持原跨章清除 A–B 的规则和 orphan 清理。

睡眠定时器在捕帧已内部暂停期间到期时，现在同时撤销续播意图并递增暂停代次；捕帧结束后不会因原 shouldResume 值再次播放。单独回归确认捕帧和还原仍完成、play 次数为 0，合法听视频后台续播及旧 null-intent 兼容回归继续通过。

最终代码上的新执行结果（与前面轮次重叠，不相加）：

- 上节完整定向兼容命令：68 项全部通过，其中 `ab_repeat_capture_lifecycle_test.dart` 包含 14 项。
- `flutter analyze --no-pub`：0 问题；本轮修复了花括号和 null-aware collection lint。
- `dart format --output=none --set-exit-if-changed lib/features/player/player_ab_repeat_coordinator.dart lib/features/player/player_controls_coordinator.dart lib/features/player/player_notes_workspace.dart test/ab_repeat_capture_lifecycle_test.dart`：4 个文件、0 个变化。
- `git diff --check`：通过。本轮没有原生代码变化，Android Kotlin 编译证据沿用上一轮成功结果，没有重新构建 APK 或创建签名。
- 本轮没有 UI 改动，沿用已有合成截图和窄屏大字验证；真实账号、原生设备验证仍未完成。
## 外部嵌套路由的捕帧取消复核

第三轮只读审查复现：捕帧正在等待原生截图返回时，关闭笔记并打开作者页，页面已遮挡且播放器暂停；迟到截图仍可能进入原位置还原并续播。现在外部嵌套路由在异步等待前显式取消捕帧 serial、清除待还原位置并递增暂停代次，再等待已发出的 seek 完成。作者页、简介提及页、下载队列和屏蔽管理页均覆盖；外部视频路由和退出也显式取消。通用清除 A–B 方法没有改变，内部跨 CID 捕帧、还原和 orphan 图片清理规则保留。

`ab_repeat_nested_route_test.dart` 使用真实 PlayerPage 和路由控件回调，共 12 项：四条路由分别门控 `captureCurrentFrame`，确认遮挡后没有还原 seek、没有 play，迟到图片被清理；再分别覆盖原播放与原暂停的往返行为。作者页、提及页、屏蔽管理页返回后沿用原播放选择，下载队列返回后保持暂停。夹具使用全内存凭据、合成公共服务和内存下载队列，没有读取真实会话或进行下载。

最终命令与结果（本轮与前面的测试重叠，不相加）：

```powershell
& C:\Users\L1XU4N\flutter\bin\flutter.bat test --no-pub test/ab_repeat_test.dart test/player_ab_repeat_test.dart test/ab_repeat_capture_lifecycle_test.dart test/ab_repeat_nested_route_test.dart test/notes_subtitles_widgets_test.dart test/classroom_integration_test.dart test/classroom_account_race_test.dart test/listening_playback_test.dart test/windows_source_identity_race_test.dart test/windows_playback_audio_lifecycle_test.dart test/focus_session_continuity_test.dart test/clipboard_player_return_test.dart
& C:\Users\L1XU4N\flutter\bin\flutter.bat analyze --no-pub
& C:\Users\L1XU4N\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/player/player_ab_repeat_coordinator.dart lib/features/player/player_playback_session.dart lib/features/player/player_focus_coordinator.dart lib/features/player/player_video_coordinator.dart lib/features/player/player_details_view.dart lib/features/player/player_local_library.dart lib/features/player/player_controls_coordinator.dart test/ab_repeat_nested_route_test.dart
git diff --check
```

- 最终定向兼容：80 项全部通过，包含捕帧/生命周期 14 项、新路由 12 项，以及内部跨 CID 捕帧往返正向。
- 最终静态分析：0 问题；最终格式检查：8 个 Dart 文件、0 个变化；`git diff --check` 通过。
- 本轮没有 UI 布局或原生代码变化，没有重新打包 APK；合成截图和 Kotlin 编译证据沿用前轮。真机与真实已购账号仍未验收。