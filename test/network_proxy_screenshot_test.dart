// Opt-in documentation capture, not native-device verification.
// Example: FOCUBILI_PROXY_SCREENSHOT_FONT=/path/NotoSansCJK-Regular.ttc \
//   flutter test test/network_proxy_screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/network_proxy_page.dart';
import 'package:focubili/models/network_proxy_settings.dart';
import 'package:focubili/services/network_proxy_service.dart';

class _ScreenshotService extends NetworkProxyService {
  _ScreenshotService(this.settings);
  final NetworkProxySettings settings;
  @override
  Future<NetworkProxySettings> load() async => settings;
}

void main() {
  final fontPath = Platform.environment['FOCUBILI_PROXY_SCREENSHOT_FONT'];
  Future<void> capture(WidgetTester tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('ProxyScreenshotFont');
      loader.addFont(File(fontPath!).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = AppTheme.light();
    for (final entry in <String, NetworkProxySettings>{
      'system': const NetworkProxySettings(),
      'manual': const NetworkProxySettings(
        mode: NetworkProxyMode.manual,
        host: '127.0.0.1',
        port: 7890,
      ),
    }.entries) {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(
                fontFamily: 'ProxyScreenshotFont',
              ),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: 'ProxyScreenshotFont',
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => NetworkProxyPage(
                        service: _ScreenshotService(entry.value),
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('docs/images/proxy-settings-${entry.key}.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }

  testWidgets(
    'capture narrow proxy settings widgets for documentation',
    capture,
    skip: fontPath == null,
  );
}
