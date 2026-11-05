import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

const _configKey = 'home_collection.v1.favorites.0';

/// Stores the same legacy label snapshot written by the home editor.
Future<String> _saveChoices(List<Map<String, String>> items) async {
  final raw = jsonEncode({'custom': true, 'items': items});
  await (await SharedPreferences.getInstance()).setString(_configKey, raw);
  return raw;
}

Map<String, String> _choice(String id, String label, {String kind = 'local'}) =>
    {'kind': kind, 'id': id, 'label': label};

Widget _host({bool offstage = false}) => MaterialApp(
  home: Scaffold(
    body: Offstage(
      offstage: offstage,
      child: const HomeCollectionCard(favorites: true),
    ),
  ),
);

/// Drains real service queues before advancing the widget's animation clock.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

/// Starts navigation and its service continuations on the real async queue.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(Duration.zero);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.focubili.app/auth'),
      (call) async => call.method == 'readCookies' ? '' : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    // Initialize the shared account queue outside individual widget fake clocks.
    await BilibiliAuthService().loadCurrentSession();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.focubili.app/auth'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  testWidgets('remount resolves local names by ID without rewriting choices', (
    tester,
  ) async {
    final favorites = AppFavoritesService();
    final first = (await tester.runAsync(
      () => favorites.createFolder('Before'),
    ))!;
    final second = (await tester.runAsync(
      () => favorites.createFolder('Second'),
    ))!;
    final raw = await _saveChoices([
      _choice(second.id, 'Second'),
      _choice(first.id, 'Before'),
      _choice(first.id, 'Remote title', kind: 'remote'),
    ]);
    await tester.pumpWidget(_host());
    await _settle(tester);
    expect(find.text('Before'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      await tester.runAsync(() => favorites.renameFolder(first.id, 'After')),
      isTrue,
    );
    await tester.pumpWidget(_host());
    await _settle(tester);

    expect(find.text('Before'), findsNothing);
    expect(find.text('After'), findsOneWidget);
    expect(find.text('Remote title'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Second')).dy,
      lessThan(tester.getTopLeft(find.text('After')).dy),
    );
    expect((await SharedPreferences.getInstance()).getString(_configKey), raw);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another service refreshes a retained offstage card repeatedly', (
    tester,
  ) async {
    final folder = (await tester.runAsync(
      () => AppFavoritesService().createFolder('Before'),
    ))!;
    final raw = await _saveChoices([_choice(folder.id, folder.name)]);
    await tester.pumpWidget(_host());
    await _settle(tester);
    await tester.pumpWidget(_host(offstage: true));
    await _settle(tester);
    final otherService = AppFavoritesService();
    await tester.runAsync(
      () => Future.wait([
        otherService.renameFolder(folder.id, 'Middle'),
        otherService.renameFolder(folder.id, 'After'),
      ]),
    );
    await _settle(tester);
    await tester.pumpWidget(_host());
    await _settle(tester);

    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
    expect(find.text('Middle'), findsNothing);
    expect((await SharedPreferences.getInstance()).getString(_configKey), raw);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => otherService.renameFolder(folder.id, 'After disposal'),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing or corrupt folders preserve saved labels and choices', (
    tester,
  ) async {
    final raw = await _saveChoices([
      _choice('missing', 'Missing folder'),
      _choice('remote', 'Remote title', kind: 'remote'),
    ]);
    final prefs = await SharedPreferences.getInstance();
    for (final folders in ['[]', 'invalid JSON']) {
      await prefs.setString('app_favorites.folders_v1', folders);
      await tester.pumpWidget(_host());
      await _settle(tester);
      expect(find.text('Missing folder'), findsOneWidget);
      expect(find.text('Remote title'), findsOneWidget);
      expect(prefs.getString(_configKey), raw);
      expect(prefs.getString('app_favorites.folders_v1'), folders);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('rename during customization does not discard editor changes', (
    tester,
  ) async {
    final favorites = AppFavoritesService();
    final first = (await tester.runAsync(
      () => favorites.createFolder('Before'),
    ))!;
    final second = (await tester.runAsync(
      () => favorites.createFolder('Second'),
    ))!;
    await _saveChoices([_choice(first.id, first.name)]);
    await tester.pumpWidget(_host());
    await _settle(tester);
    await _tap(tester, find.byTooltip('自定义内容'));
    await _settle(tester);
    await tester.runAsync(() => favorites.renameFolder(first.id, 'After'));
    await _settle(tester);
    await _tap(tester, find.text('Second'));
    await _settle(tester);
    await _tap(tester, find.text('保存'));
    await _settle(tester);

    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    final saved =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(_configKey)!,
            )
            as Map<String, dynamic>;
    expect(saved['custom'], isTrue);
    expect((saved['items'] as List).map((item) => item['id']), [
      first.id,
      second.id,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rename refresh does not restore selections after account reset',
    (tester) async {
      final favorites = AppFavoritesService();
      final folder = (await tester.runAsync(
        () => favorites.createFolder('Before'),
      ))!;
      await _saveChoices([_choice(folder.id, folder.name)]);
      await tester.pumpWidget(_host());
      await _settle(tester);
      await tester.runAsync(() async {
        final rename = favorites.renameFolder(folder.id, 'After');
        await _saveChoices([]);
        CacheLifecycle.accountChanged();
        await rename;
      });
      await _settle(tester);
      expect(find.text('Before'), findsNothing);
      expect(find.text('After'), findsNothing);
      expect(find.text('选择内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rename cancel and save survive returning from folder overview', (
    tester,
  ) async {
    final folder = (await tester.runAsync(
      () => AppFavoritesService().createFolder('Before'),
    ))!;
    await _saveChoices([_choice(folder.id, folder.name)]);
    await tester.pumpWidget(_host());
    await _settle(tester);
    await _tap(tester, find.text('我的收藏'));
    await _settle(tester);
    await _tap(tester, find.text('本机收藏夹'));
    await _settle(tester);

    for (final save in [false, true]) {
      await _tap(tester, find.byKey(Key('app-favorite-actions-${folder.id}')));
      await _settle(tester);
      await _tap(tester, find.byKey(Key('rename-app-favorite-${folder.id}')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('app-favorite-folder-name-input')),
        'After',
      );
      // Keep the service's shared write queue outside per-test fake clocks.
      await tester.runAsync(() async {
        await tester.tap(
          save
              ? find.byKey(const Key('confirm-app-favorite-folder-name'))
              : find.text('取消'),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await _settle(tester);
      expect(find.text(save ? 'After' : 'Before'), findsOneWidget);
    }
    await tester.pageBack();
    await _settle(tester);
    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
