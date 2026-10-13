# 1.7.1 更新页检查

截图由真实 AboutPage 和应用主题在 Linux Flutter widget 渲染器生成，使用合成 GitHub Release 数据及中文/Material 字体；不是 Android/iOS 真机截图。画布 390×940，左侧状态为检测到 1.7.1，另一张为用户忽略后的状态。当前安装版本 1.7.0 是升级场景夹具。

- `about-update-before.png`：忽略按钮、重新检查、下载入口。
- `about-update-ignored.png`：只抑制入口红点，版本、摘要和下载仍保留，说明主动检查会取消忽略。
- `test/update_ignore_ui_test.dart` 同时覆盖个人中心/设置入口一致性，以及 320×800 深色、1.4 倍字号的禁用状态。图片仅用于人工布局检查，不充当像素级跨平台验收。
