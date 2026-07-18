import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/services/app_update_service.dart';

class _VersionProvider implements AppVersionProvider {
  @override
  Future<String> loadVersion() async => '0.2.2';
}

class _Preferences extends AppUpdatePreferencesService {
  @override
  Future<bool> loadEnabled() async => true;

  @override
  Future<void> saveEnabled(bool enabled) async {}
}

void main() {
  testWidgets('关于页展示版本、负责人和新版本 Release 入口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final AppUpdateController controller = AppUpdateController(
      versionProvider: _VersionProvider(),
      preferencesService: _Preferences(),
      updateService: AppUpdateService(
        releaseLoader: () async => <String, Object?>{
          'tag_name': 'v0.3.0',
          'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v0.3.0',
        },
      ),
    );
    await controller.initialize(checkOnStart: true);
    Uri? openedUri;

    await tester.pumpWidget(
      MaterialApp(
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
    await tester.tap(find.byKey(const Key('open-release-page')));
    await tester.pump();
    expect(openedUri?.path, contains('/releases/tag/v0.3.0'));
    controller.dispose();
  });
}
