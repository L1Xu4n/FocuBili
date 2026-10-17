# 1.8 首页订阅引导最小回移

准确基线：`95b23239f933f38d61c05c2c6b0cd958ffb74902`。

独立工作树：`task-5/v18-home-onboarding-backport`；分支：`codex/v18-home-onboarding-backport`。本次不修改正式 1.8 分支，不修改其它工作树，不推送或发布。

## 原版复现与范围判定

先新增仅使用 1.8 现有 API 的 `home_subscription_onboarding_backport_test.dart`，产品代码保持基线原样，实际得到 **2 passed、1 failed**：

| 原版用例 | 结果 | 含义 |
| --- | --- | --- |
| 非编辑状态接受首次订阅引导，经过确认及设置页返回，慢拉首页 | 通过 | 原两档吸附直接打开卡片区 |
| 编辑卡片后回到欢迎区接受同样引导，再返回慢拉 | 失败 | 卡片容器已重建并显示“自定义”，但父页仍保留 editing；停在 120px，未吸附到预期全开位置 772px |
| 360×720、2.5 倍字体拒绝提示，再慢拉首页 | 通过 | 提示收起后首屏高度恢复，原两档吸附可用；本次未发现提示高度本身的独立缺陷 |

因此，编辑状态残留是 **1.8 已有缺陷**，不是 1.9 三档抽屉引入。1.8 的 `_handleHomeScrollEnd` 和滚动通知处理本来就会在 editing 时跳过吸附，而旧卡片容器销毁不会向父页回报结束编辑。

1.9 的三档 physics、连续专注会话和学习文件夹属于其功能改动；这里没有带入。`608d439` 中提示可见性变化时清旧手势起点的额外处理，本轮没有证实是 1.8 必须修复的独立故障，因此也不回移。没有扩大提示高度、拖动或计时实现的改动范围。

## 最小修复

仅在 `focus_dashboard.dart` 的引导 `onEnabled` 更换 `_homeBoardKey` 前增加 `_handleHomeEditingChanged(false)`，复用 1.8 原有的父编辑、方向、手势起点及吸附进行状态清理。产品 diff 只有这一行调用和一行注释。保留原两档 `_handleHomeScrollEnd`、卡片拖动优化、视频关联式专注和原学习清单。

## 实际验证

Flutter 为 `C:\Users\L1XU4N\flutter\bin\flutter.bat`。全部使用 mock preferences 和合成数据，注入空后台调度回调，没有加载真实账号资料。

```powershell
flutter pub get
# exit 0，未修改依赖版本或 lock 文件

# 原版产品代码，新增测试已适配 1.8：
flutter test --no-pub test/home_subscription_onboarding_backport_test.dart --reporter expanded
# exit 1，2 passed、1 failed；编辑后接受引导的实际位置 120，预期 772

# 最小修复后：
flutter test --no-pub test/home_subscription_onboarding_backport_test.dart test/home_customization_test.dart test/focus_dashboard_test.dart test/editable_card_board_test.dart test/subscription_release_test.dart --reporter expanded
# exit 0，51 passed，0 failed，约 5 秒测试时间

flutter analyze --no-pub lib/features/focus/focus_dashboard.dart test/home_subscription_onboarding_backport_test.dart
# exit 0，No issues found，4.6 秒

dart format --output=none --set-exit-if-changed lib/features/focus/focus_dashboard.dart test/home_subscription_onboarding_backport_test.dart
# exit 0，0 changed

git diff --check
# exit 0，无输出
```

原版和修复后完整本地输出分别在忽略的 `build/v18-home-onboarding-original.log` 与 `build/v18-home-onboarding-backport-tests.log`。夹具曾先调整过同名“自定义时长/卡片自定义”选择器；该夹具失败不属于上述产品缺陷证据。

状态：**实现 / 自动化通过**。真机验收：**未做**。人工预期为：编辑卡片 → 回欢迎区接受订阅提示 → 从设置返回 → 慢拉超过 48px 后，按 1.8 原规则直接吸附到卡片区。最终整合与发布由父任务唯一发布者处理。
