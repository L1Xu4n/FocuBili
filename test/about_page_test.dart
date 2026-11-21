import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 为关于页测试提供固定的已安装版本。
class _VersionProvider implements AppVersionProvider {
  /// 返回低于测试 Release 的版本，确保页面显示可更新状态。
  @override
  Future<String> loadVersion() async => '0.2.2';
}

/// 为关于页测试提供不访问真实设备的更新检查开关。
class _Preferences extends AppUpdatePreferencesService {
  @override
  Future<String?> loadIgnoredUpdate() async => null;
  @override
  Future<void> saveIgnoredUpdate(String? identity) async {}

  /// 测试默认允许执行更新检查。
  @override
  Future<bool> loadEnabled() async => true;

  /// 测试不验证开关存储，因此保存操作保持为空。
  @override
  Future<void> saveEnabled(bool enabled) async {}
}

/// 验证关于页版本、更新摘要、项目入口和 QQ 群入口。
void main() {
  /// 验证页面内容完整，Release 和 QQ 群按钮分别打开正确的外部链接。
  testWidgets('关于页展示版本、负责人和新版本 Release 入口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final AppUpdateController controller = AppUpdateController(
      versionProvider: _VersionProvider(),
      preferencesService: _Preferences(),
      updateService: AppUpdateService(
        targetPlatform: AppUpdateTargetPlatform.windows,
        releaseLoader: () async => <String, Object?>{
          'tag_name': 'v0.3.0',
          'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v0.3.0',
          'assets': <Map<String, Object?>>[
            <String, Object?>{
              'name': 'FocuBili-v0.3.0-x64.msix',
              'browser_download_url':
                  'https://github.com/L1Xu4n/FocuBili/releases/download/v0.3.0/FocuBili-v0.3.0-x64.msix',
            },
          ],
          'body': '''
<!-- focubili-update-summary:start -->
- 优化平板播放器空间利用
- 修复画幅设置
- 增加启动更新提醒
- 改进安装包下载入口
- 第五条更新简报
<!-- focubili-update-summary:end -->
''',
        },
      ),
    );
    await controller.initialize(checkOnStart: true);
    final openedUris = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: AboutPage(
          controller: controller,
          externalUrlLauncher: (Uri uri) async {
            openedUris.add(uri);
            return true;
          },
        ),
      ),
    );

    expect(find.text('版本 0.2.2'), findsOneWidget);
    expect(find.text('@L1Xu4n'), findsOneWidget);
    expect(find.byKey(const Key('about-update-dot')), findsOneWidget);
    expect(find.byKey(const Key('about-update-highlights')), findsOneWidget);
    expect(find.text('优化平板播放器空间利用'), findsOneWidget);
    expect(find.text('修复画幅设置'), findsOneWidget);
    expect(find.text('增加启动更新提醒'), findsOneWidget);
    expect(find.text('改进安装包下载入口'), findsOneWidget);
    expect(find.text('第五条更新简报'), findsOneWidget);
    expect(find.text('下载 Windows 安装包'), findsOneWidget);
    final qq = find.byKey(const Key('open-project-qq-group'));
    final support = find.byKey(const Key('open-support-focubili'));
    final diagnostics = find.byKey(const Key('open-problem-diagnostics'));
    final projectLinks = find.ancestor(of: qq, matching: find.byType(Card));
    expect(diagnostics, findsOneWidget);
    expect(
      find.descendant(of: projectLinks, matching: support),
      findsOneWidget,
    );
    expect(
      find.descendant(of: support, matching: find.text('支持焦点哔哩')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: support, matching: find.text('给焦点哔哩的宣传视频投个币吧~')),
      findsOneWidget,
    );
    expect(tester.getTopLeft(qq).dy, lessThan(tester.getTopLeft(support).dy));
    expect(
      tester.getTopLeft(support).dy,
      lessThan(tester.getTopLeft(diagnostics).dy),
    );

    Future<void> open(Finder target) async {
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
    }

    await open(find.text('项目地址'));
    await open(find.text('项目负责人'));
    await open(qq);
    expect(openedUris, [
      Uri.parse('https://github.com/L1Xu4n/FocuBili'),
      Uri.parse('https://github.com/L1Xu4n'),
      Uri.parse('https://qm.qq.com/q/szv665wx7W'),
    ]);
    await open(support);
    expect(openedUris, hasLength(4));
    expect(
      openedUris.last,
      Uri.parse('https://www.bilibili.com/video/BV1dyaG6kEAu'),
    );

    await open(find.byKey(const Key('open-release-page')));
    expect(openedUris.last.path, endsWith('/FocuBili-v0.3.0-x64.msix'));
    controller.dispose();
  });
  testWidgets('正式版关于页显示完整版本和构建号', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: '焦点哔哩',
      packageName: 'com.focubili.app',
      version: '1.9.0',
      buildNumber: '2038',
      buildSignature: '',
    );
    final controller = AppUpdateController(
      versionProvider: const PlatformAppVersionProvider(),
      preferencesService: _Preferences(),
    );
    await controller.initialize(checkOnStart: false);
    await tester.pumpWidget(
      MaterialApp(home: AboutPage(controller: controller)),
    );
    expect(find.text('版本 1.9.0+2038'), findsOneWidget);
    expect(controller.result.currentVersion, '1.9.0+2038');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
