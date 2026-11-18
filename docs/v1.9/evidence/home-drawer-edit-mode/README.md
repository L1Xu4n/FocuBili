# 首页抽屉：只在编辑时显示卡片设置

普通首页不再出现顶端编辑按钮。“我的收藏”和“我的关注”的滑杆图标也不会占据日常列表：从底部“自定义”进入编辑后，才能打开对应卡片的自选内容。个人中心及其他页面的编辑、收藏来源选择和已有封面不变。

| 视口 | 修改前普通态 | 修改后普通态 | 编辑 | 单卡设置 | 全隐藏 | 点击小抽屉后 |
| --- | --- | --- | --- | --- | --- | --- |
| 390×844，浅色 | [之前](before-phone-normal.webp) | [普通](after-phone-normal.webp) | [编辑](after-phone-editing.webp) | [设置](after-phone-card-editor.webp) | [收起](after-phone-all-hidden.webp) | [恢复编辑](after-phone-restore-editing.webp) |
| 320×740，200% 字号 | [之前](before-large-normal.webp) | [普通](after-large-normal.webp) | [编辑](after-large-editing.webp) | [设置](after-large-card-editor.webp) | [收起](after-large-all-hidden.webp) | [恢复编辑](after-large-restore-editing.webp) |
| 1200×800，深色 | [之前](before-desktop-normal.webp) | [普通](after-desktop-normal.webp) | [编辑](after-desktop-editing.webp) | [设置](after-desktop-card-editor.webp) | [收起](after-desktop-all-hidden.webp) | [恢复编辑](after-desktop-restore-editing.webp) |

真实 Flutter 组件、中文字体、受控的本机偏好；不使用用户提供的原图。这里模拟的是应用页面而非实体系统读屏或真实 B 站账号。

## 交互验收

- 普通态支持原收藏入口和内容导航。编辑时只开放卡片个性化和布局控件，不误开卡片中的内容。卡片设置可分别用键盘找到并打开，保存与取消保留各自语义。
- 隐藏最后一个可用卡片会收起抽屉。底部小按钮的点击区域至少 48dp；点后启用抽屉、直接进入编辑，不擅自添加卡片或重排。首页搜索一直可用。
- 单纯想收起而保留既有卡片配置，也可以使用编辑态的次要“关闭抽屉”操作。关闭尚未落盘时不能反向发起恢复；若保存失败，非空抽屉回到原布局，确已全隐藏的仍提供恢复入口。
- 执行入口：`test/home_drawer_edit_mode_test.dart`；相邻收藏来源、卡片封面及断网降级、卡片排序、抽屉手势和首页导航均有原有回归。
