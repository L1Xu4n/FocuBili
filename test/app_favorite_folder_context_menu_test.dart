import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('右键和键盘可打开当前本机收藏夹的管理菜单', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1120, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final service = AppFavoritesService();
    final first = (await service.createFolder('数学收藏夹'))!;
    final second = (await service.createFolder('英语收藏夹'))!;
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(favoritesService: service)),
    );
    await tester.pumpAndSettle();

    final row = find.text(second.name);
    final rename = find.byKey(Key('rename-app-favorite-${second.id}'));
    final wrong = find.byKey(Key('rename-app-favorite-${first.id}'));
    final rightClick = await tester.startGesture(
      tester.getCenter(row),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(rename, findsOneWidget);
    expect(wrong, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(rename, findsNothing);

    Focus.of(tester.element(row)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(rename, findsOneWidget);
    expect(wrong, findsNothing);
    expect(find.byType(AppFavoriteDetailPage), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    Focus.of(tester.element(row)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
    expect((await service.loadFolders()).map((folder) => folder.id), [
      first.id,
      second.id,
    ]);
  });
}
