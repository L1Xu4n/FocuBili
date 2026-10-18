import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/unified_export_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'fixtures/settings_runtime_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  UnifiedExportService service() => UnifiedExportService(
    settingsRuntimeAdapter: const FixtureSettingsRuntimeAdapter(),
    subscriptionLoader: () async => {'sources': []},
    subtitleLoader: () => [],
    diagnosticsLoader: () async => 'Fixture diagnostics',
  );

  testWidgets('empty scope disables export and cancel never reports success', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedExportPage(
          service: service(),
          saveService: LocalExportService(
            platform: AppPlatform.android,
            saveDialog: (_) async => null,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('unified-export-select-all')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('unified-export-save')),
      300,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('unified-export-save')))
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('unified-export-settings')),
      -300,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unified-export-settings')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('unified-export-save')),
      300,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unified-export-save')));
    await tester.pumpAndSettle();
    expect(find.text('已取消保存。'), findsOneWidget);
    expect(find.textContaining('已导出'), findsNothing);
  });

  testWidgets('save failures display safe platform diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedExportPage(
          service: service(),
          saveService: LocalExportService(
            platform: AppPlatform.macos,
            saveDialog: (_) async =>
                throw const FileSystemException('PRIVATE_PATH'),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('unified-export-save')),
      300,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unified-export-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('macos/save/io_unknown'), findsOneWidget);
    expect(find.textContaining('PRIVATE_PATH'), findsNothing);
    expect(find.textContaining('已导出'), findsNothing);
  });
}
