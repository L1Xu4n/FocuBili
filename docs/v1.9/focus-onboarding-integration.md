# 首页订阅引导、三档抽屉与连续专注整合

基于候选整合提交 `af282f5b2f4ccfb266b04e763b17ad6e17eb16e8`，其中已合入获准继续整合的 1.8 候选 `95b2323`。本次仅在独立分支 `codex/v19-focus-onboarding-integration` 修改首页回调及测试；没有修改 1.8 工作树，没有发布 Beta，也不代表最终整合验收。

## 修复与保留行为

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 接受订阅引导后，重建卡片容器前同步退出父页编辑状态、清理旧手势并停止旧滚动 | 自动化通过 | 新增实际点击引导、确认和设置返回流程；修复前明确失败于 `physics.enabled()` 为 false，修复后恢复半开吸附 |
| 首次提示异步出现时清理基于旧首屏高度的手势起点 | 自动化通过 | 阻塞合成订阅初始化，在外层手指拖动期间放行；验证起点被清除且下一次手势按当前范围吸附 |
| 大字体提示关闭后的首屏高度与抽屉范围同步 | 自动化通过 | 360×720、2.5 倍字体，真实拒绝引导后测量首屏缩短及半开位置，无布局异常 |
| 内层卡片滚动、内容区长甩不误关抽屉 | 自动化通过 | 合成 60 项内层列表滚动不改变外层位置；外层内容区长甩不能越过全开边界 |
| 首笔拖动未落盘时再次拖动 | 自动化通过 | 阻塞首笔布局保存，预览 `a,b,c → b,a,c → c,b,a`；两笔串行保存后最终顺序及首卡位置正确 |
| 1.9 连续专注、终态优先存储、学习文件夹与课程记录兼容 | 自动化通过 | 引导和抽屉手势前后会话 ID、running 状态连续；既有连续会话、拒写重启、文件夹迁移及非 BV 课程记录测试通过 |
| Windows/Android 真机手势、原生后台恢复及最终发布验收 | 未做 | 本轮只有 Flutter 合成组件/单元测试，未调用真实账号或数据 |

保留候选的卡片间隙命中、边缘滚动重算、待保存预览和绘制位移动画。没有改动 `EditableCardBoard`/tile 的生产实现。三段抽屉的物理实现、卡片内部滚动隔离，以及专注计时和清单存储实现也保持原样。抽屉吸附范围仍以当前首屏高度和实际最大滚动范围为准。

## 实际命令与结果

Flutter：`C:\Users\L1XU4N\flutter\bin\flutter.bat`。工作目录为本独立工作树。SDK 缓存写入使用正常构建授权，未修改 SDK 权限。

```powershell
flutter pub get
# exit 0；未更改依赖版本或 lock 文件

flutter test --no-pub test/focus_home_onboarding_integration_test.dart test/editable_card_board_test.dart test/home_drawer_gesture_test.dart test/home_drawer_scroll_physics_test.dart test/focus_dashboard_test.dart test/subscription_release_test.dart test/focus_session_continuity_test.dart test/focus_session_storage_failure_test.dart test/focus_timer_controller_test.dart test/learning_subject_folders_test.dart test/course_learning_records_test.dart --reporter expanded
# exit 0；89 passed，0 failed，约 10 秒测试时间

flutter test --no-pub test/focus_home_onboarding_integration_test.dart --reporter expanded
# 将长甩断言加强为实际返回全开位置后复验：exit 0；4 passed，0 failed，约 2 秒
```

本地完整测试输出：`build/focus-onboarding-integration-tests.log`（忽略的构建产物，不纳入提交）。修复前单独运行新增引导测试，结果为 2 passed、1 failed，失败点是完成引导后父页吸附开关仍为 false；该记录不把测试夹具调整期间的失败算作产品缺陷。

针对静态分析使用 `flutter analyze --no-pub`，范围为首页的三个 Dart 文件、`home_drawer_scroll_physics.dart`、card board/tile 及四个相关测试文件，共 10 项；exit 0，`No issues found!`，3.4 秒。

修改的三个 Dart 文件通过 `dart format --output=none --set-exit-if-changed`：exit 0，0 changed。`git diff --check` 无输出，exit 0。

## 后续人工步骤与预期

1. 在合成测试配置中开始一次专注，进入首页卡片编辑，再回到欢迎区接受首次订阅提示；从订阅设置返回后应显示“自定义”，依次滑动可到半开、全开，原专注会话继续。
2. 在窄屏和大字体下拒绝订阅提示；额外提示空间应消失。接着手动打开抽屉、滚动卡片内部列表、从较深内容区快速向下甩动；内滚不移动外层，内容区长甩最多回到全开，继续明确手势才逐档关闭。
3. 在注入慢布局存储的配置下连续重排两次；第二次从第一次预览的位置开始，存储恢复后顺序与最后预览一致，重进仍保留。

这些步骤的真机结果目前未记录。父任务完成其它候选整合后仍需按最终提交进行统一验证。
