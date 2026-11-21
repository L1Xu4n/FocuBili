# A–B 区间：自动回跳与控制面板

自动从 B 回到 A 不新增播放或暂停动作图标，仍按原区间循环。手动点击播放 / 暂停的确认反馈不变。区间在片尾时，播放器可能先上报停止，再跳到 A 后恢复，整个过程不是一组手动动作。不同后端的播放状态可能晚于 seek 指令回执，因此不能只在 seek Future 期间过滤动画。

控件去掉了信息图标，点击对勾启用区间。点铅笔打开精确时间输入时，面板的左、右和上边缘不动，内容向下展开；空间不足时，可在面板内滚动。全屏右侧把手可用鼠标或手指长按拖动，或者聚焦后使用方向键。把手不会触发画面长按倍速、跳转或播放 / 暂停。收起保留当前视频的草稿；真正切换内容时仍清除。

## 实际 Flutter 画面对照

相同的 1152 × 720 全屏播放器 widget，视频、位置和播放后端用合成夹具。旧展开框宽 600 dp；新版紧凑和展开外框均为 360 dp。

- [修复前：紧凑](before-compact.png)、[展开](before-expanded.png)
- [修复后：紧凑](after-compact.png)、[向下展开](after-expanded.png)、[用右侧把手移动](after-moved.png)

```sh
mkdir -p /tmp/focubili-ab-evidence
FOCUBILI_AB_EVIDENCE=/tmp/focubili-ab-evidence \
  FOCUBILI_DESKTOP_INPUT_FONT=/path/to/NotoSansCJK-Regular.ttc \
  FOCUBILI_DESKTOP_INPUT_ICON_FONT=/path/to/MaterialIcons-Regular.otf \
  flutter test test/player_ab_repeat_panel_interaction_test.dart \
  --plain-name 'capture the same actual Flutter fullscreen editor in both states'
```

字体变量仅用于截图；Material 图标字体取自 Flutter SDK 的 `bin/cache/artifacts/material_fonts`。基线是 `5d072e4`，使用同一个测试文件。快照测试覆盖正常回跳、5 倍速稀疏位置、片尾、等待中的手动暂停、后端不提供播放意图，以及 #134 的电脑鼠标单击。未在实体设备上播放或验证系统级窗口行为。
