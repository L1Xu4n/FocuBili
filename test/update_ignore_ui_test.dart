import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/profile_page.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';

class _Version implements AppVersionProvider {
  @override
  Future<String> loadVersion() async => '1.7.0';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppUpdateController> ready({bool available = true}) async {
    final controller = AppUpdateController(
      versionProvider: _Version(),
      updateService: AppUpdateService(
        targetPlatform: AppUpdateTargetPlatform.android,
        releaseLoader: () async => {
          'tag_name': available ? 'v1.7.1' : 'v1.7.0',
          'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v1.7.1',
          'assets': [
            {
              'name': 'FocuBili-v1.7.1-android.apk',
              'browser_download_url':
                  'https://github.com/L1Xu4n/FocuBili/releases/download/v1.7.1/FocuBili-v1.7.1-android.apk',
            },
          ],
          'body':
              '<!-- focubili-update-summary:start -->\n- 修复部分高清画质切换问题\n- 支持忽略本次更新红点\n<!-- focubili-update-summary:end -->',
        },
      ),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> show(
    WidgetTester tester,
    AppUpdateController controller,
    Widget page, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    final appTheme = brightness == Brightness.dark
        ? AppTheme.dark()
        : AppTheme.light();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('update-ui-capture'),
        child: MaterialApp(
          key: UniqueKey(),
          debugShowCheckedModeBanner: false,
          theme: appTheme.copyWith(
            textTheme: appTheme.textTheme.apply(
              fontFamily: 'UpdateScreenshotFont',
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: AppUpdateScope(controller: controller, child: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['FOCUBILI_UPDATE_UI_OUTPUT'];
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('update-ui-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('关于页忽略保留下载与详情，个人中心和设置红点同步消失', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 940));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (Platform.environment.containsKey('FOCUBILI_UPDATE_UI_OUTPUT')) {
      await tester.runAsync(() async {
        final font = FontLoader('UpdateScreenshotFont')
          ..addFont(
            File(
              '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '${Platform.environment['FLUTTER_ROOT'] ?? '/workspace/toolchains/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await icons.load();
      });
    }
    final controller = await ready();
    Uri? opened;
    await show(
      tester,
      controller,
      AboutPage(
        externalUrlLauncher: (uri) async {
          opened = uri;
          return true;
        },
      ),
    );
    final ignore = find.byKey(const Key('ignore-current-update'));
    await tester.ensureVisible(ignore);
    await tester.pumpAndSettle();
    await capture(tester, 'about-update-before');
    await tester.tap(ignore);
    await tester.pumpAndSettle();
    expect(controller.showUpdateBadge, isFalse);
    expect(find.text('发现新版本 1.7.1'), findsOneWidget);
    expect(find.byKey(const Key('about-update-highlights')), findsOneWidget);
    expect(tester.widget<TextButton>(ignore).onPressed, isNull);
    await tester.ensureVisible(find.byKey(const Key('open-release-page')));
    await tester.pumpAndSettle();
    await capture(tester, 'about-update-ignored');
    await tester.tap(find.byKey(const Key('open-release-page')));
    expect(opened?.path, endsWith('.apk'));
    expect(tester.takeException(), isNull);

    await show(
      tester,
      controller,
      ProfilePage(
        authService: BilibiliAuthService(
          cookieStore: const UnavailableBilibiliCookieStore(),
        ),
      ),
    );
    expect(find.byKey(const Key('profile-settings-update-dot')), findsNothing);
    await show(tester, controller, const PersonalizationSettingsPage());
    final category = find.byKey(
      const Key('open-appearance-application-settings'),
    );
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('open-about-page')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-update-dot')), findsNothing);
    expect(find.text('新版本：修复部分高清画质切换问题'), findsOneWidget);
    await controller.checkNow();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-update-dot')), findsOneWidget);
    await show(
      tester,
      controller,
      ProfilePage(
        authService: BilibiliAuthService(
          cookieStore: const UnavailableBilibiliCookieStore(),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-settings-update-dot')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const Key('profile-settings-update-dot')),
      findsOneWidget,
    );
  });

  testWidgets('无更新时忽略按钮禁用，深色窄屏大字布局可操作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await ready(available: false);
    await show(
      tester,
      controller,
      const AboutPage(),
      brightness: Brightness.dark,
      scale: 1.4,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('ignore-current-update')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('ignore-current-update')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('open-release-page')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
