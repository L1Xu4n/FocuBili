# 首页：关注与收藏的快捷入口

从首页抽屉底部进入「自定义」，再打开「我的关注」或「我的收藏」的卡片设置。两个页面先显示两种方式。上方只保留通往关注／收藏页的快捷入口，不加载候选；点下方才打开选择列表。当前方式同时用文字和读屏选中状态标明。

| 步骤 | 关注和收藏并排（左为关注） |
| --- | --- |
| 旧版编辑页：分段切换 | [修改前](previous-editors.webp) |
| 首页：UP 头像、收藏封面来源 | [首页卡片](home.webp) |
| 选显示方式：两张大按钮 | [两种方式](modes.webp) |
| 自选内容：点名称看详情，点加号才添加 | [编辑已选与可选项](manage.webp) |

- 已选项可以独立移除、拖动调整顺序。进入详情再返回，继续刚才的草稿；退出设置不保存，点「保存」才写入。
- 本机收藏夹用书签，B 站收藏夹用云朵。角标贴在封面右下角，没图也会显示；读屏直接读出来源。关注头像缺失时显示人像占位，旧记录优先使用当前账号的分组快照，必要时只补查关注第一页。编辑候选加载失败可以重试，不会清空已选项。
- [深色封面和来源](dark-favorite-home.webp) · [320dp、200% 文字的方式选择](large-favorite-chooser.webp) · [桌面编辑区](desktop-follow-editor.webp)

截图取自 Flutter 实际组件与导航；使用合成内容、中文字体及经图片缓存实际解码的示例头像和封面，不代表在线 B 站账号或实体设备上的系统读屏。桌面为 1000×730，普通手机为 390×740。

主要回归入口：

```sh
flutter test test/home_collection_modes_test.dart test/home_collection_preview_test.dart
flutter test test/home_collection_card_test.dart test/home_collection_offline_test.dart test/home_favorite_covers_test.dart test/home_drawer_edit_mode_test.dart
```
