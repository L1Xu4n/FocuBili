# 黑名单：成功提示按时离场

基线 `2657d2f`。真实搜索视频菜单和播放器 UP 主菜单均复现：提示带「撤销」，6 秒后仍留在底部。Flutter 3.44.6 的 `SnackBar` 在未指定 `persist` 又有操作按钮时默认常驻。

- 常规模式显示约 4 秒，右侧也可直接关闭；关闭或超时只收起提示，不恢复视频或 UP 主。启用系统无障碍导航时，有「撤销」的提示保留到操作或关闭。
- 连续屏蔽不会堆积提示，只保留最近一条屏蔽反馈，不打断其它功能的重要提示。离开原来的页面不会把旧撤销带到新页面。
- 仅新插入的屏蔽项获得一次撤销。重复屏蔽没有新撤销；此前移除再重新加回的同一 BV 或 UID 不会被旧按钮误删。撤销写入失败仍保留屏蔽。
- 现有入口是搜索视频卡片（包括 BV 直达）和播放器的「更多」。没有增加 UP 个人页按钮，也没有修改黑名单作用范围。

## 真实搜索页截图

[提示出现：可撤销或关闭](01-confirmation-visible.png) · [提示超时：视频仍保持屏蔽](02-confirmation-expired.png)

## 复验

```sh
flutter test -j1 --no-pub test/block_feedback_timeout_test.dart test/content_blocklist_test.dart test/player_blocklist_test.dart
```

Flutter 测试驱动实际搜索和播放器页面，使用合成搜索结果、本地存储替身和无障碍标志，未连接真人账号或运行实体设备上的 TalkBack / VoiceOver。
