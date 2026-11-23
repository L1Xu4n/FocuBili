# FocuBili 开发规则

- 遵循 [CONTRIBUTING.md](CONTRIBUTING.md)。普通 PR 以 `dev` 为目标；每个 PR 只处理一个主要问题，不要顺手格式化无关文件。
- **开 PR 前，以及每次推送更新到已有 PR 前，都要检查这次实际要推的代码。** 以目标分支的 [CI 工作流](.github/workflows/ci.yml)为准，使用 CI 固定的 Flutter SDK（目前 3.44.6）及其自带的 Dart，不要混用 PATH 上的独立 Dart。先执行 `flutter pub get`，再跑 `dart format --output=none --set-exit-if-changed lib test` 和 `flutter analyze --no-pub`。如果格式检查失败，只格式化涉及本次改动的文件，然后重跑检查。
- **测试范围随改动扩大。** 修 Bug 要跑对应回归测试；改动跨模块或涉及播放器、缓存、数据迁移等共用逻辑时，跑完整 `flutter test --no-pub`。如果 PR 会触发 Linux CI，再用 [Linux 工作流](.github/workflows/linux-build.yml)指定的 Flutter SDK 自带 Dart 跑格式检查（目前 Flutter 3.47.5，命令为 `dart format --output=none --set-exit-if-changed lib test tool/linux_runtime_probe.dart`）。改打包或发布流程时，跑 CI 对应的发布工具测试。
- **记录真实结果。** PR 描述里列出使用的 Flutter/Dart 版本、实际执行的命令、结果和未验证项。改动后旧结果不算数，重跑受影响的检查。已知失败先修再推，不为过检查而跳过测试或放宽断言。环境确实跑不了的检查，写清原因并标为未验证；远端必需检查通过后再合入。
