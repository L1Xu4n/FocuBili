# 正式 1.8 发布后的 Beta CI capability 引导候选

临时基线为 `2ca0b6e38b722c88ff8611717ce1f58eb8f8c3ed`，独立分支 `codex/v18-beta-ci-bootstrap`。该基线包含 macOS stdout 订阅探针、Apple foreground 晚到 guard、iOS 设置预览方向修复及 Apple 质量作业新增的 Python 测试。准备期间发布副本已推进至阈值修复 `bdc9470`；本候选不回移该 Dart 改动，后续应把本候选的唯一新增提交重定位到 **1.8 真实发布后的最终 master**，不得把临时基线当作最终发布 SHA。

只移植已审查 producer `d998eb843046d8694f268e07b27b11c1985c12db` 和 launcher 修复 `36b4bdc703b2615df09f6d12c10e737e6c58b342` 的文件内容与受控 hunks。没有 fetch/merge/cherry-pick 1.9 分支历史，也没有导入原来被拒的图片对象。

## 补丁范围与 1.8 默认行为

共九个文本文件：新增 `beta-release.yml`、`tool/beta_release.py`、`tool/test_beta_release.py` 和本记录；对 `release-build.yml`、`apple-build.yml`、`linux-build.yml` 增加 reusable 输入及 Beta 条件分支；对 `tool/package_linux.sh` 增加显式 Beta 包版本参数；对 Gradle 增加显式 `focubili.betaNumber` 属性与 **release build type** 中的 `.preview`/版本后缀。

- 三个 reusable workflow 仅声明 `source_sha`、`beta_number` 两个受控字符串输入；签名工作流仅声明/转发原来的四个 `ANDROID_RELEASE_*` secrets。签名前重复核对固定仓库、dev/master 手动调用或 master push、完整 SHA、实际 checkout 及远端受信分支祖先关系。没有 PR 取密钥入口，也没有新凭据。
- 未提供 Beta 参数时，现有正式构建命令和稳定包 `com.focubili.app` 不变，原有 release 签名强制检查保留。1.8 debug 的 `-preview` 后缀逐字保留，未带入 1.9 的 debug `-beta.1`。
- `pubspec.yaml` 仍为 `1.8.0+26`；`pubspec.lock`、全部 `lib/`、iOS/Apple 原生源码、原生探针、方向策略、`ci.yml`、`publish-release.yml` 与临时基线均无差异。没有 1.9 功能、更新消费者、用户数据或发布说明改动。
- 新 Beta APK 复用现有公开 65EF release 证书身份，保留 `.preview`。这不能覆盖归档 5BD1 Beta3/4/5 安装；不做卸载或数据迁移。Windows/macOS/Linux/iOS 现有包身份与数据路径仍共享稳定版，不能视作隔离安装。

归档 Beta3/4/5 的实际已记录 versionCode 分别为 2023/2024/**2025**。选定 1.9 源码必须提交至少 2026 的明确计数，并高于 live inventory 中所有已发稳定/预发布 APK 的实际 aapt 码；CI 向每个平台注入同一个 `--build-number`。不使用 workflow `run_number` 偏移。本候选的 1.8 版本不会通过 1.9 Beta preflight，这是预期边界。

## master 调用与源码、产物路径核对

默认分支是 **master**。GitHub 要求手动 workflow 存在于默认分支，所以仅向 dev 放置 Beta workflow 不足以 dispatch。引导后从 master 手动调用，`source_sha` 则选择已审核、已推送且具有精确 SHA CI 成功证据的 **1.9 dev 源码**。本地没有执行 dispatch。 [GitHub 手动工作流](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

`./.github/workflows/...` reusable 定义来自调用者同一提交，即完成引导的 master；不是隐式来自所选 1.9 SHA。三个 reusable 工作流及 prepare/assemble/publish 都显式 checkout `inputs.source_sha`，普通未传参事件仍使用 `github.sha`。各验证器和 `write_build_metadata.dart` 从实际 `git rev-parse HEAD` 生成 source evidence，不把调用者 master 的 `GITHUB_SHA` 当成 1.9 源码。输入 SHA 要求在获取后的 origin/dev 或 origin/master 可达。 [GitHub reusable workflow 版本规则](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)

产物均取同一 caller run，不传跨 run 的下载 ID：

| 上传名 | 下载目录 | assembler 实际读取 |
| --- | --- | --- |
| `focubili-beta-metadata` | `metadata/` | plan、精确源码的 CI run IDs |
| `focubili-release-android` | `staging/android/` | `app-release.apk`；下载后重新 aapt/apksigner 验证 |
| `focubili-release-windows` | `staging/windows/` | 两个包及 `windows-package-verification.json` |
| `focubili-apple-macos-SOURCE_SHA` | `staging/macos/` | 真实 DMG 及原 `macos-package-verification.json` |
| `focubili-apple-ios-SOURCE_SHA` | `staging/ios/` | unsigned IPA 及 Beta bundle 验证记录 |
| `focubili-linux-SOURCE_SHA` | `staging/linux/` | DEB/tar 及 Beta 验证记录 |
| `focubili-beta-candidate-SOURCE_SHA` | 最终作业 `release/` | 七个二进制、manifest、SHA256SUMS |

上传路径的共同目录分别为 flutter-apk、installer、build/apple、linux-packages；没有要求下载时再嵌套这些原始目录。按名称下载单个 artifact 直接解包到指定目录，未设置跨 run 参数时取当前 run。 [上传目录规则](https://github.com/actions/upload-artifact#upload-using-multiple-paths-and-exclusions)、[下载目录规则](https://github.com/actions/download-artifact#download-single-artifact)

Apple/Linux 名称显式使用输入 SHA，不用调用者 master SHA。assembler 的每个平台 source/version/build/字节/hash 验证阻止错源或缺失产物；callee 任一作业失败都会阻断 assembler。既有 Apple 新增质量 Python 步骤、stdout 采集和原生运行检查保留。

`publish=false` 默认为只构建/验证/上传候选 Actions artifact，不创建 tag/release；它仍需要真实 CI 签名和原生构建。只有显式 `publish=true` 的最后作业具有 contents write，取得与正式 publisher 相同的 `focubili-publish-refs/heads/master` 锁后重查全局 APK 最大码。存在 release/draft 即拒绝，不覆写资产、不移动 tag；新建 draft prerelease，经服务端 bytes/digest 核对后才公开，始终 `latest=false`，并比较稳定 latest 的 ID/tag 前后相同。没有改正式发布入口。

## 本地验证与未完成门槛

已在本独立树实际执行：

```text
python -X utf8 -B -m unittest discover -s tool -p test_beta_release.py -v
# 33 passed，全部 API/原生工具输出与二进制为合成夹具。
python -X utf8 -B -m unittest discover -s tool -p test_native_subscription_probe.py -v
# 16 passed，包含真实合成子进程的 macOS stdout/requestId 门禁。
python -X utf8 -B -m unittest discover -s tool -p test_verify_macos_dmg.py -v
# 3 passed，不是实际 macOS hdiutil/codesign 执行。
python -X utf8 -B tool/check_apple_sources.py
# Apple source/metadata checks passed。
```

四份 YAML 解析成功，与 `2ca0b6e` 比较既有 push/PR 触发器完全相同；50 个 Bash 和 4 个 PowerShell run block 仅语法解析通过。新 orchestrator 和两个 Python helper/test 与已审查 `36b4bdc` 内容完全相同。Gradle debug scope 与 1.8 基线逐字相同。

实际 Windows launcher 探测使用本树的同一个 helper：

```powershell
python -X utf8 -B -c 'import sys; sys.path.insert(0, "tool"); import beta_release as beta; print("Resolved Flutter:", beta.shutil.which("flutter"), flush=True); beta.run_flutter(["--version"])'
# C:\Users\L1XU4N\flutter\bin\flutter.BAT
# Exit 0，Flutter 3.44.6 / framework ee80f08bbf / Dart 3.12.2。
```

该探测通过 `shutil.which` 解析实际 BAT，保持参数列表与 `shell=False`。没有运行 Flutter 构建、读取密钥、启动账户或应用、GitHub 写操作、创建 PR、dispatch、push、tag 或 release。没有以合成测试冒充 Android/Windows/Apple/Linux 的真实 CI 产物验证或设备升级验收。

后续须先完成正式 1.8 发布，再把此 CI-only 提交重定位到真正 master 并重新核对默认构建、最新探针和新增基线修复；由父任务另行准备引导 PR。1.9 producer/consumer、源码计数和对应 release notes 必须位于另一个已审核的 1.9 源码提交。首次候选应以 `publish=false` 取得真实全平台 CI/manifest/升级身份检查证据后再审查公开发布；本记录不表示引导 PR 或任何 Beta 已发布。
