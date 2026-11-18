# PC 播放器：鼠标与触屏输入对照

适用 Windows、macOS、Linux 的鼠标操作。桌面上的触摸屏与移动端手势不变。

| 操作 | 结果 |
| --- | --- |
| 鼠标单击视频画面 | 暂停 / 恢复。等待约 300 毫秒确认不是双击。 |
| 鼠标双击视频画面 | 仅进入 / 退出全屏，不暂停、不恢复、不快进。 |
| 鼠标移至视频底部 | 唤出控制栏；停在控制栏上不会自动隐藏。 |
| 鼠标不按键，在进度条上移动 | 显示指向的时间；如有图集，显示当前分 P 中对应采样帧。图集不可用时仍有时间。 |
| 用鼠标或手指拖动进度条 | 不显示、不请求新的预览图，只在松手时跳转一次。原本的悬停图在按下时即关闭。 |
| 用鼠标或手指在**画面内**横拖 | 保留原本的横滑时间、图集预览和一次性跳转。 |

## 可复现的前后对照

这些截图来自同一尺寸（1280 × 720）的真实 Flutter `PlayerPage`，使用模拟播放后端、合成画面和四格 PNG 图集，不涉及账户和真实视频数据。鼠标定位到同一条时间轴的 50%（`1:00`）；合成图集的对应格为绿色，模拟播放位置保持在 `0:20`。测试另对比 `1:36` 的橙色格，确认图像不是停留在上一个位置。Flutter widget 测试的虚拟指针不绘入截图。

- [修复前：底部移动后仍无控制栏和预览](before-hover.png)
- [修复后：底部移动已唤出控制栏，尚未移到时间轴](after-bottom.png)
- [修复后：悬停显示 1:00 和正确的绿色采样格](after-hover.png)
- [修复后：同一鼠标按下并拖动进度条，预览关闭](after-drag.png)

```sh
mkdir -p /tmp/focubili-desktop-input
FOCUBILI_DESKTOP_INPUT_EVIDENCE=/tmp/focubili-desktop-input \
  FOCUBILI_DESKTOP_INPUT_FONT=/path/to/NotoSansCJK-Regular.ttc \
  FOCUBILI_DESKTOP_INPUT_ICON_FONT=/path/to/MaterialIcons-Regular.otf \
  flutter test test/player_desktop_input_test.dart --plain-name 'desktop timeline raster evidence'
```

两个字体变量只用于截图；`MaterialIcons-Regular.otf` 可从当前 Flutter SDK 的 `bin/cache/artifacts/material_fonts` 取用。要重放修复前，从 `fc53f61` 的独立工作树运行同一个测试文件，不带入播放器改动。

测试通过 Flutter 模拟 Windows、macOS、Linux 的输入分支，覆盖播放命令、窗口内全屏布局、鼠标/触点仲裁、播放源切换、晚到的旧分 P 图集、笔记覆盖和窄尺寸大字布局。未在三平台的实体窗口或真实解码播放中测试；这里的缩略图是视频采样帧，不是解码器当前帧。
