import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/features/profile/data_transfer_page.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/app_update_service.dart';

/// 直接渲染实际页面生成可复核截图；使用合成偏好，不访问用户账号和安全存储。
void main() {
  testWidgets('capture v1.8 settings on compact and tablet layouts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot == null) throw StateError('请提供用于截图的 FLUTTER_ROOT');
      for (final entry in {
        'V18Review': Platform.isWindows
            ? '${Platform.environment['WINDIR'] ?? r'C:\Windows'}/Fonts/msyh.ttc'
            : Platform.isMacOS
            ? '/System/Library/Fonts/PingFang.ttc'
            : '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        'MaterialIcons':
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final bytes = await File(entry.value).readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
    PackageInfo.setMockInitialValues(
      appName: 'FocuBili',
      packageName: 'com.focubili.app',
      version: '1.8.0',
      buildNumber: '26',
      buildSignature: 'synthetic',
    );
    final controller = AppUpdateController();
    await controller.initialize(checkOnStart: false);
    final folder = Directory('docs/reviews/v1.8');
    folder.createSync(recursive: true);

    // 每张截图使用真实主题与页面，检查布局异常并保留PNG证据。
    Future<void> capture(String name, Widget page, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final boundaryKey = GlobalKey();
      final theme = AppTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'V18Review'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'V18Review',
            ),
          ),
          home: RepaintBoundary(key: boundaryKey, child: page),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    }

    await capture(
      'about-mobile',
      AboutPage(controller: controller),
      const Size(360, 800),
    );
    await capture(
      'data-transfer-mobile',
      const DataTransferPage(),
      const Size(360, 800),
    );
    await capture(
      'layout-tablet',
      const PersonalizationSettingsPage(
        appPlatform: AppPlatform.android,
        showLayoutSettings: true,
      ),
      const Size(1280, 800),
    );
    controller.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
