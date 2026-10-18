# 1.9 与本地 1.8 发布快照的内容基线核对

1.8 待发布快照为 `98e02e8a7dd4ac59d23b94f29813f40df52fab48`，父提交为远端 dev `da0946b98994fea9020a58c870b0ddddcde72a42`。该快照将原候选 `95b2323` 与两个最小补丁整理为相同最终文件树，避免推送已拒绝的祖先图片对象。它不是已发布正式版，也不能根据历史形状盲目 merge 到 1.9。

对 `95b2323..98e02e8` 的生产增量与 1.9 `ae1f1f8` 做独立只读核对，结果如下：

| 文件 | 1.9 内容状态 |
| --- | --- |
| `subscription_notification_delivery.dart` | 与 1.8 快照完全相同 |
| `subscription_notification_service.dart` | 与 1.8 快照完全相同 |
| `windows_focus_notification_service.dart` | 与 1.8 快照完全相同 |
| `subscription_service.dart` | 完整保留请求级通知 guard；额外差异属于 1.9 导出实现 |
| `focus_dashboard.dart` | 已停止旧滚动、清理 editing 和手势起点后重建卡片；保留 1.9 抽屉改进 |

五个 1.8 生产文件与通知 `f845a65`、首页 `61f11c0` 两个原始回移补丁匹配。其余增量为测试和文档。**没有发现需要补入的生产代码，没有 merge/cherry-pick 重整后的快照。**

1.9 原完整验证仍对应生产提交 `309e039`：1353 通过、2 跳过、0 失败；本次只记录内容基线，没有因无代码变化重复运行整套测试。1.8 组合回归独立为 999 通过、1 跳过、0 失败，不与 1.9 计数混用。

GitHub 因当前 OAuth App 缺少 `workflow` scope 拒绝推送 1.8 候选；远端分支未创建，PR/CI 未启动。1.9 可以继续准备本地测试包，不能称为 GitHub 已发布版本。后续正式 1.8 提交若再修改生产代码，仍需重新对齐。
