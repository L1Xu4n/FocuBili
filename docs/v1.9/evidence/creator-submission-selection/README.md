# UP 投稿：逐项菜单与批选

这是 UP 主页的“投稿”列表，不是合集详情。原单项学习图标替换为三点按钮；单次可选学习清单或收藏夹。长按视频或点工具栏多选可批量处理；未完成添加或取消时保留当前勾选。

| 真实组件视口 | 改动前 | 普通状态 | 三点菜单 | 已选 | 两种去向 |
| --- | --- | --- | --- | --- | --- |
| 390×844，浅色 | [原列表](before-phone-list.webp) | [三点](after-phone-list.webp) | [菜单](after-phone-menu.webp) | [多选](after-phone-selected.webp) | [方形按钮](after-phone-destinations.webp) |
| 320×740，200% 字号 | [原列表](before-large-list.webp) | [可换行工具栏](after-large-list.webp) | [菜单](after-large-menu.webp) | [多选](after-large-selected.webp) | [上下排列](after-large-destinations.webp) |
| 1100×800，深色桌面 | [原列表](before-desktop-list.webp) | [双列](after-desktop-list.webp) | [菜单](after-desktop-menu.webp) | [多选](after-desktop-selected.webp) | [方形按钮](after-desktop-destinations.webp) |

WidgetTester 使用应用主题、中文字体、真实 UserProfilePage；本地合成 40 支已加载视频，声明投稿总数 818。没有使用真实账号截图、真实封面或在线写入；不代表实体设备、操作系统读屏或视频解码测试。

**依赖**：#117 提供 UP 页头，#118 提供勾选拖动，#124 提供单批次目的地和保存逻辑。当前 PR 以 #124 + #117 的非发布集成提交为 base，不能跳过这些前置直接摘取页面。最终审查目标是 dev。

**回归入口**：`test/creator_video_batch_test.dart`。包含三点→分 P、两个投稿实际存入本机/学习清单、取消与返回、列表底边停指等待慢分页、排序与跨标签、重复或空 BV、迟到旧排序分页不能污染新选区。针对所选目标的账号与只读约束由 #124 的模拟传输测试覆盖。
