import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_folders_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'app_favorites_backup_ui_test.dart' show MemoryFavorites;

class _SignedOut extends BilibiliAccountDataService {
  int loads = 0;
  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async {
    loads++;
    return AccountDataPage<FavoriteFolder>.signedOut();
  }
}

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(320, 480),
    const Size(568, 280),
  ]) {
    for (final local in [true, false]) {
      testWidgets('${local ? '本机空收藏' : 'B站未登录'} $size 可滚到操作并返回', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _SignedOut();
        final favorites = MemoryFavorites();
        final scale = size.width == 320
            ? 2.4
            : size.height == 280
            ? 2.0
            : 1.0;
        await tester.pumpWidget(
          MaterialApp(
            theme: size.width == 390 ? AppTheme.light() : AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => local
                          ? AppFavoriteFoldersPage(favoritesService: favorites)
                          : FavoriteFoldersPage(accountDataService: service),
                    ),
                  ),
                  child: const Text('打开收藏'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开收藏'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scroll = find.byKey(
          Key(
            local
                ? 'app-favorites-empty-scroll'
                : 'favorite-folders-status-scroll',
          ),
        );
        final action = local
            ? find.widgetWithText(FilledButton, '新建收藏夹')
            : find.byKey(const Key('favorite-folders-retry'));
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        );
        if (size.width == 390) {
          expect(scrollable.position.maxScrollExtent, 0);
          final content = find
              .descendant(of: scroll, matching: find.byType(Column))
              .first;
          final center = find
              .ancestor(of: scroll, matching: find.byType(Center))
              .first;
          expect(
            tester.getCenter(content).dy,
            closeTo(tester.getCenter(center).dy, 0.01),
          );
        } else {
          final message = find.text(local ? '还没有软件收藏夹' : '请先登录后查看。');
          await Scrollable.ensureVisible(
            tester.element(message),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          final viewport = tester.getRect(scroll);
          final textRect = tester.getRect(message);
          if (textRect.height <= viewport.height) {
            expect(textRect.top, greaterThanOrEqualTo(viewport.top));
            expect(textRect.bottom, lessThanOrEqualTo(viewport.bottom));
          } else {
            // 极短窗口也允许分别滚到文字首尾，不靠缩小用户字体解决。
            await Scrollable.ensureVisible(
              tester.element(message),
              alignment: 0,
            );
            await tester.pumpAndSettle();
            expect(tester.getRect(message).top, closeTo(viewport.top, 0.01));
            await Scrollable.ensureVisible(
              tester.element(message),
              alignment: 1,
            );
            await tester.pumpAndSettle();
            expect(
              tester.getRect(message).bottom,
              closeTo(viewport.bottom, 0.01),
            );
          }
          await tester.drag(scroll, const Offset(0, -500));
          await tester.pumpAndSettle();
        }
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
        if (local) {
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(await favorites.loadFolders(), isEmpty);
        } else {
          expect(service.loads, 2);
          expect(find.text('请先登录后查看。'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('打开收藏'), findsOneWidget);
      });
    }
  }
}
