# 专注计时第三阶段维护说明

更新日期：2026-07-18

这份文档记录“视频关联、播放联动、打断、提醒、统计”的统一规则，后续改功能时应先保持这些规则一致。

## 1. 计时规则

- 首页创建任务后先进入“等待关联视频”，不会立即消耗时长。
- 从播放器创建任务时自动关联用户当时所在的 BV 和分P。
- 只有关联的 BV、分P与当前播放器一致，并且原生播放器报告 `isPlaying=true` 时，计时才会继续。
- 普通视频暂停只暂停计时，不算打断；手动暂停专注、离开关联播放器、应用进入后台或意外恢复才算打断。
- 打断不会结束任务；只有用户在终止原因弹窗中确认“终止”才计入提前结束。
- 意外关闭恢复时采用保守策略：不会把无法证明视频仍在播放的后台时间计入专注，并记录“专注被打断”。

## 2. 视频关联与首页 Pin

- 首页任务进入播放页后询问是否关联当前视频。用户点取消时，只记住当前 `bvid:cid` 候选；换分P或换视频后再次询问。
- 用户确认时才读取当前 BV、分P、标题、播放位置和视频画面，避免把先前候选错误写入任务。
- 首页 Pin 点击后重新查询公开视频详情，并恢复到保存的分P和“上次看到”位置。
- 保存位置为 `00:00` 时不主动 seek，让原生播放器继续使用本机观看历史；非零位置才作为专注记录的明确跳转目标。
- 旧完成记录只有 BV 号、没有分P CID 时仍允许打开视频，并回退到默认或本机保存的分P。
- 首页 Pin 在最后画面上方显示格式化视频时间点；确认关联后播放器显示“已关联视频：标题（分P）”。
- 离开关联播放器或切换分P前尝试截取最后画面；截图失败不会阻止退出或保存进度。
- 任务结束瞬间会再次保存当前帧和真实播放位置，保证完成记录也可准确继续。

## 3. 完成、打断和统计

- 正常到时会暂停视频、展示 120 片从屏幕顶部同时落下的全屏礼花雨、播放 `res/raw/focus_complete.mp3`，并允许给同一任务增加 5 分钟。
- 手动暂停或退出播放器时先展示鼓励；达到 80% 或剩余不超过 5 分钟时使用额外鼓励语料。
- 鼓励文案位于 `assets/data/focus_encouragements.json`，可直接扩充 `regular` 与 `nearCompletion` 数组。
- 打断记录保存类型、时间、原因和可选提醒时间；空原因保存为“未填写原因”，意外中断保存为“专注被打断”。
- 统计页显示总打断次数；单条记录显示打断次数、最近原因和主动终止原因。
- 每次运行片段在暂停或结束时按设备本地午夜切分，并以 `dailyFocusMs` 写入任务 JSON；因此跨午夜、暂停后隔日恢复都只计入真实播放发生的日期。旧版本没有逐日桶的记录仍按结束时间向前兼容估算。
- 7 天和 30 天总时长只汇总范围内的逐日桶，与折线图求和保持一致；“全部”指标使用完整历史，但趋势图固定显示最近 30 天并在分享图中明确标注。

## 4. Android 通知

- Android 13 及以上需要 `POST_NOTIFICATIONS` 运行时权限；旧版本不显示这项运行时权限弹窗。
- Android 8 及以上使用“专注提醒”通知通道。
- 用户填写提醒时间后才检查权限；拒绝后提供直达当前应用通知设置页的按钮。
- 提醒使用 `AlarmManager.setAndAllowWhileIdle`，不申请受限制的精确闹钟权限，因此省电模式下可能延后送达。
- 用户继续、完成、终止或删除记录时会尝试取消对应待发送提醒。

## 5. 关键文件

- `lib/models/focus_session.dart`：任务状态、视频来源、打断和 JSON 兼容。
- `lib/features/focus/focus_timer_controller.dart`：全应用唯一计时状态机。
- `lib/features/player/player_page.dart`：真实播放状态、关联提示、上下集和退出流程。
- `lib/features/focus/player_focus_sheet.dart`：播放器专注面板与独立的视频关联确认面板。
- `lib/features/focus/focus_dashboard.dart`：首页任务创建与 Pin。
- `lib/features/focus/focus_statistics_page.dart`：折线图、指标和记录管理。
- `lib/features/focus/focus_interruption_dialog.dart`：鼓励、原因、提醒和权限引导。
- `android/app/src/main/kotlin/com/focubili/app/FocusNotificationController.kt`：Android 权限、闹钟与无需音频文件的完成提示音。
- `android/app/src/main/kotlin/com/focubili/app/FocusReminderReceiver.kt`：到时通知。

## 6. 回归命令

```powershell
dart analyze lib test
flutter test
flutter build apk --debug
```

测试意外中止后如果任务管理器残留 `flutter_tester.exe`，应先结束残留测试宿主再重跑；正常整套测试结束时进程数量应回到 0。

## 7. 播放器拆分约定

- `player_page.dart` 已超过五千行，需要继续拆分，但每次只移动一个清晰边界并先补测试。
- 第一处拆分是视频关联确认面板，避免播放器状态类继续直接维护整段弹层布局。
- 合集、通用布局、全屏状态栏、弹幕画布和底部控制组件已经拆分；下一步按“笔记工作区 → 手势协调器”继续。
- 完整播放器结构和维护边界见 `docs/PLAYER_ARCHITECTURE.md`。
