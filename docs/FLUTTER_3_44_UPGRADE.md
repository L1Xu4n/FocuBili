# Flutter 3.44 升级与维护指南

更新日期：2026-07-18

这份文档记录 FocuBili 从 Flutter 3.16.5 升级到 Flutter 3.44.6 的结果，方便以后换电脑、排查构建问题或继续升级。

## 当前固定工具链

| 组件 | 版本 | 作用 |
| --- | --- | --- |
| Flutter | 3.44.6 stable | 编译 Flutter 界面和调用各平台构建工具 |
| Dart | 3.12.2 | 编译 Dart 业务代码，由 Flutter SDK 自带 |
| JDK | 21 | 运行 Gradle 和 Android 构建插件 |
| Android SDK | 36 | 编译和检查 Android API |
| Android Gradle Plugin | 8.11.1 | 把 Android 源码、资源和 Flutter 产物打包成 APK |
| Gradle | 8.14.3 | 执行 Android 构建任务和解析 Android 依赖 |
| Kotlin | 2.2.20 | 编译项目中的 Android 原生 Kotlin 代码 |
| Android NDK | 28.2.13676358 | 编译 Flutter 插件或引擎使用的原生代码 |

应用的 `compileSdk` 和 `targetSdk` 为 36，`minSdk` 为 24，因此最低支持 Android 7.0。升级 Flutter 后最低 Android 版本从 API 21 提高到 API 24，这是 Flutter 3.44 的平台基线，不是播放器功能主动限制。

## 依赖升级结果

直接依赖约束已经更新为本次验证版本：

- `cached_network_image` 3.4.1：网络图片加载和磁盘缓存。
- `crypto` 3.0.7：生成 WBI 请求所需的 MD5 摘要。
- `shared_preferences` 2.5.5：保存轻量本机设置和记录。
- `webview_flutter` 4.14.1：承载官方网页登录页面。
- `flutter_lints` 6.0.0：提供与新 Dart 版本匹配的静态检查规则。

`pubspec.yaml` 保存允许使用的版本范围，`pubspec.lock` 保存本次实际解析到的完整依赖树。应用项目应提交锁文件，保证不同电脑安装出同一套版本。

少数传递依赖会由 Flutter SDK 自身固定版本。只要 `flutter pub outdated` 显示它们“Latest”较新、但“Resolvable”仍是当前版本，就不要在 `dependency_overrides` 中强行覆盖，否则可能破坏 Flutter SDK 的兼容性。

## 从零配置开发环境

1. 安装 JDK 21、Android SDK 36 和 Android NDK 28.2.13676358。
2. 安装 Flutter 3.44.6 stable，并确保 `where flutter` 的第一项指向该 SDK。
3. 在项目根目录依次运行：

```powershell
flutter --version
flutter doctor -v
flutter pub get --enforce-lockfile
dart analyze
flutter test
flutter build apk --debug
```

`--enforce-lockfile` 会拒绝在锁文件无法满足 `pubspec.yaml` 时偷偷换一套依赖，因此适合日常验证和持续集成。

## 后续升级流程

1. 先阅读目标 Flutter 版本的破坏性变更和 Android 平台要求。
2. 新建分支并保存干净的 Git 状态。
3. 更新 Flutter SDK，然后运行 `flutter pub outdated` 查看可解析版本。
4. 修改直接依赖约束并运行 `flutter pub upgrade`，不要手工改 `pubspec.lock`。
5. 同步检查 Gradle、Android Gradle Plugin、Kotlin、SDK 和 NDK 的兼容矩阵。
6. 依次执行静态检查、完整测试和 Android 构建；出现失败时先修复，再提交锁文件。
7. 更新 README 和本文件中的版本记录。

## 本次兼容修改

- Flutter 3.44 的主题 API 要求 `ThemeData.cardTheme` 使用 `CardThemeData`，因此更新了共享主题构造代码。
- 使用 Flutter 3.44 推荐 API 替换旧 Material 色名、颜色透明度、返回手势回调和滚动缓存参数，避免把弃用问题留给后续版本。
- Android 构建链升级到 Gradle 8.14.3、AGP 8.11.1 和 Kotlin 2.2.20，并使用 SDK 36、NDK 28.2。
- Android 构建继续使用项目现有 Kotlin 插件和旧版 DSL；`android.builtInKotlin=false` 与 `android.newDsl=false` 是迁移期间明确保留兼容行为的开关。
- 项目位于 Windows 中文路径时保留 `android.overridePathCheck=true`。若 Shader 编译仍受路径编码影响，可用 `subst` 临时映射英文盘符后构建。

## 清理原则

升级后可以运行 `flutter clean` 删除项目内旧的构建产物，再用 `flutter pub get --enforce-lockfile` 恢复当前依赖。不要直接清空用户目录中的整个 Pub 或 Gradle 全局缓存，因为这些缓存可能被其他 Flutter、Dart 或 Android 项目共用。

## 2026-07-18 验证结果

- `flutter --version`：Flutter 3.44.6 stable、Dart 3.12.2。
- `flutter pub get --enforce-lockfile`：依赖锁文件可复现。
- `dart analyze`：无问题。
- `flutter test`：129 项全部通过。
- `flutter build apk --debug`：成功生成 `build/app/outputs/flutter-apk/app-debug.apk`。
