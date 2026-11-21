import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/unified_export_page.dart';

void main() {
  const captureDir = String.fromEnvironment('V19_CAPTURE_DIR');
  for (final (name, size, dark, scale) in [
    ('export-mobile', const Size(430, 900), false, 1.0),
    ('export-desktop-dark', const Size(1280, 900), true, 1.0),
    ('export-large-text', const Size(320, 800), false, 1.6),
  ]) {
    testWidgets('$name layout is scrollable without overflow', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          for (final entry in {
            'V19Review': r'C:\Windows\Fonts\msyh.ttc',
            'MaterialIcons':
                r'C:\Users\L1XU4N\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
          }.entries) {
            final bytes = await File(entry.value).readAsBytes();
            await (FontLoader(
              entry.key,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
      }
      final boundaryKey = GlobalKey();
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: captureDir.isEmpty
                ? theme
                : theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'V19Review'),
                    primaryTextTheme: theme.primaryTextTheme.apply(
                      fontFamily: 'V19Review',
                    ),
                  ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const UnifiedExportPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(captureDir).create(recursive: true);
          await File(
            '$captureDir/$name.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.scrollUntilVisible(
        find.byKey(const Key('unified-export-save')),
        300,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('unified-export-save')), findsOneWidget);
    });
  }
}
