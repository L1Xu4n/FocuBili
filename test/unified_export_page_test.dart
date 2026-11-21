import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/unified_export_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'fixtures/settings_runtime_fixture.dart';
import 'support/checkbox_sweep.dart';

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

  testWidgets('sweeping the checklist changes scope but never starts export', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1250));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var packageReads = 0;
    var saveDialogs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedExportPage(
          service: UnifiedExportService(
            preferencesLoader: () {
              packageReads++;
              return SharedPreferences.getInstance();
            },
          ),
          saveService: LocalExportService(
            platform: AppPlatform.android,
            saveDialog: (_) async {
              saveDialogs++;
              return null;
            },
          ),
        ),
      ),
    );

    Finder check(UnifiedExportSection section) =>
        checkboxIn(find.byKey(ValueKey('unified-export-${section.name}')));
    Iterable<UnifiedExportSection> selected() =>
        UnifiedExportSection.values.where(
          (section) => tester.widget<Checkbox>(check(section)).value == true,
        );
    final master = find.byKey(const Key('unified-export-select-all'));
    final save = find.byKey(const Key('unified-export-save'));
    final first = check(UnifiedExportSection.settings);
    final third = check(UnifiedExportSection.learning);
    final last = check(UnifiedExportSection.diagnostics);

    expect(selected(), UnifiedExportSection.values);
    expect(find.text('取消全选'), findsOneWidget);
    await sweepCheckboxes(tester, first, third);
    expect(selected(), UnifiedExportSection.values.skip(3));
    expect(find.text('全选'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    await sweepCheckboxes(tester, third, first);
    expect(selected(), UnifiedExportSection.values);
    expect(find.text('取消全选'), findsOneWidget);
    await sweepCheckboxes(tester, first, last);
    expect(selected(), isEmpty);
    expect(find.text('全选'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(master);
    await tester.pumpAndSettle();
    expect(selected(), UnifiedExportSection.values);
    expect(find.text('取消全选'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(packageReads, 0);
    expect(saveDialogs, 0);
  });

  testWidgets('a saved package shows both the toast and export details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedExportPage(
          service: service(),
          saveService: LocalExportService(
            platform: AppPlatform.android,
            saveDialog: (_) async => 'content://fixture/export',
          ),
        ),
      ),
    );
    final save = find.byKey(const Key('unified-export-save'));
    await tester.scrollUntilVisible(save, 300);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('已导出文件'), findsOneWidget);
    expect(find.textContaining(RegExp(r'已导出 \d+ 类资料')), findsOneWidget);
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
