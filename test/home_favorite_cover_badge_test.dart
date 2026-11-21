import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/home_favorite_cover.dart';

void main() {
  testWidgets('首页已知私密仍保留云图标，锁位于云右边', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HomeFavoriteCover(
              coverUrl: '',
              remote: true,
              isPrivate: true,
            ),
          ),
        ),
      ),
    );
    final cloud = tester.getCenter(find.byIcon(Icons.cloud_outlined));
    final lock = tester.getCenter(find.byIcon(Icons.lock_outline_rounded));
    expect(lock.dx - cloud.dx, greaterThan(12));
    expect(find.byTooltip('私密收藏夹'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('收藏夹来源角标保留图标但没有底板：$brightness', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(
            body: Row(
              children: [
                HomeFavoriteCover(coverUrl: '', isPrivate: true),
                HomeFavoriteCover(coverUrl: '', remote: true),
              ],
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
      for (final glyph in [Icons.bookmark_outline, Icons.cloud_outlined]) {
        final icon = find.byIcon(glyph);
        expect(icon, findsOneWidget);
        final badge = tester.widget<Positioned>(
          find.ancestor(of: icon, matching: find.byType(Positioned)),
        );
        expect(badge.child, isA<Icon>());
        expect(badge.right, greaterThan(0));
        expect(badge.bottom, greaterThan(0));
        expect(tester.widget<Icon>(icon).shadows, isNotEmpty);
      }
    });
  }
}
