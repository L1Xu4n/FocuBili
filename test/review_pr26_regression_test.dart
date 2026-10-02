import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/services/app_favorites_service.dart';

/// Covers folder input state and overlapping writes without account access.
void main() {
  /// Resets preferences before each independent reproduction.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Typing must survive the rebuild that enables the confirm button.
  testWidgets('folder name survives typing', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFavoriteFoldersPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-app-favorite-folder')));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('app-favorite-folder-name-input'));
    await tester.enterText(input, 'Study');
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: input, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      'Study',
    );
  });

  /// Concurrent creations must preserve both successful results.
  test('concurrent folder writes preserve both folders', () async {
    final service = AppFavoritesService();
    final results = await Future.wait([
      service.createFolder('One'),
      service.createFolder('Two'),
    ]);
    expect(results.every((folder) => folder != null), isTrue);
    expect(await service.loadFolders(), hasLength(2));
  });
}
