# 1.8 发布 PR 阶段组合回归

本轮仅推进到 dev PR、Codex 审查请求和现有 CI；未合并、打标签或发布安装包。1.9 开发分支保持独立。

## 来源与最小补丁

- 原候选：`95b23239f933f38d61c05c2c6b0cd958ffb74902`。
- 通知补丁：`f845a65adbf569b5840de3e42126e595700b4d82`，本地接续为 `506ee3f`。在异步 provider 准备完成后，再检查该次请求是否仍允许投递。
- 首页补丁：`61f11c06e8a558a8a85221b349ea7511e9ae4ffd`，本地接续为 `0b57053`。接受首次订阅引导时，使用 1.8 现有方法清理父页面编辑状态。
- 生产增量仅五个文件，不包含 1.9 的文件夹、连续专注、统一导出、多帧笔记或 A–B 循环。

## 实际执行结果

在 Windows、本机 Flutter 3.44.6 和既有离线依赖缓存中验证，使用合成数据，不启动真实账户或实际系统通知。

| 命令 | 结果 |
| --- | --- |
| `flutter pub get --offline` | exit 0，未修改锁文件或依赖版本 |
| 通知与首页相关 12 个测试文件组合运行 | 133 通过，exit 0 |
| `flutter test --no-pub --reporter expanded` | 999 通过、1 跳过、0 失败；01:37；exit 0 |
| `flutter analyze --no-pub` | 无问题；7.5 秒；exit 0 |
| `dart format --output=none --set-exit-if-changed lib test` | 417 文件、0 改动；exit 0 |
| `git diff --check` | 通过 |

唯一跳过项为 Windows 符号链接测试：当前系统未开启开发者模式，测试明确报告 `Creating symlinks requires Windows developer mode`。本轮没有更改该系统设置。

测试生产源码为 `0b57053c2d0cf2d6a1beb0a8ed8e98c253c3d56e`；后续只增加本验证记录。机器上的完整日志保留在工作区外层，未将运行日志加入公共仓库。平台原生编译、安装包签名、真实设备后台与账号验收留待对应 CI 和设备确认，不以此表冒充通过。

## PR #63 审查与平台修复追加

`98e02e8` 的 Codex 审查指出 Apple 前台通知等待系统设置回调时缺少晚到校验。现已为每个请求保留原 Dart guard，在权限设置返回后重新确认，未知、重复、取消或已释放请求均拒绝；专注开始取消旧请求。iOS headless 后台任务仍使用原 generation/run-token 协议。

同轮 macOS CI 的隔离订阅探针因向应用沙盒外写结果而失败。探针现在通过本轮随机 requestId 绑定的标准输出返回结果，宿主校验后写文件；产品沙盒、权限与三项定时器断言保持不变。

组合生产源码为 `0d2eead`，在 Windows / Flutter 3.44.6 上实际执行：

- 完整 `flutter test --no-pub --reporter expanded`：1035 通过、1 跳过、0 失败，02:28，exit 0。跳过项仍为需要 Windows 开发者模式的符号链接测试，未更改该系统设置。
- `flutter analyze --no-pub`：无问题，13.4 秒，exit 0。
- `dart format --output=none --set-exit-if-changed lib test tool/native_subscription_probe.dart`：419 文件、0 改动。
- 新探针驱动 16 项真实合成子进程测试、既有 DMG 验证器 3 项测试，以及 Apple 源码/图标检查通过。
- `git diff --check` 通过。Swift 编译器在本机不可用，新增 gate probe 和 Apple 实际构建必须以修复后的平台 CI 为准。

原候选 `98e02e8` 的 Dart、Android、Windows、Linux 和 iOS 工作均成功，macOS 失败原因如上；这些旧提交结果不替代本次修复后的精确提交检查。本追加记录不代表已合并或发布，也没有真机或真实账号验收。

## 发布历史边界

远端只读核对成功，dev 为 `da0946b98994fea9020a58c870b0ddddcde72a42`，当时目标发布分支不存在。首次受限执行的普通 Git 出现 Schannel `SEC_E_NO_CREDENTIALS`，同一普通 Git 经常规网络执行授权后成功；没有读取、更换或生成凭据，没有修改 TLS 或安全设置。

原候选的最终树已移除先前拒绝上传的 24 张审查图片，但祖先中仍有这些路径的 26 个图片对象。因此保留原候选及补丁完整本地历史，公开分支使用以远端 dev 为父提交的等价最终树快照。必须核对快照与本地组合结果的树相同，并确认待推送历史不包含这 26 个对象；不重复上传已被拒绝的图片。该操作仅针对尚未发布的新分支，不重写远端 dev/master。
