import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/services/app_update_service.dart';

/// 为关于页测试提供固定的已安装版本。
class _VersionProvider implements AppVersionProvider {
  /// 返回低于测试 Release 的版本，确保页面显示可更新状态。
  @override
  Future<String> loadVersion() async => '0.2.2';
}

/// 为关于页测试提供不访问真实设备的更新检查开关。
class _Preferences extends AppUpdatePreferencesService {
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
    Uri? openedUri;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: AboutPage(
          controller: controller,
          externalUrlLauncher: (Uri uri) async {
            openedUri = uri;
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
    expect(find.byKey(const Key('open-problem-diagnostics')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('open-project-qq-group')));
    await tester.tap(find.byKey(const Key('open-project-qq-group')));
    await tester.pump();
    expect(openedUri, Uri.parse('https://qm.qq.com/q/szv665wx7W'));
    await tester.tap(find.byKey(const Key('open-release-page')));
    await tester.pump();
    expect(openedUri?.path, endsWith('/FocuBili-v0.3.0-x64.msix'));
    controller.dispose();
  });
}
