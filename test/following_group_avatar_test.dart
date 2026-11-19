import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:focubili/features/common/following_group_avatar.dart';
import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/features/profile/following_groups_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/following_group_service.dart';

import 'home_collection_preview_test.dart'
    show Api, choice, creator, key, seed, settle, tap;

const _first = 'https://i0.hdslb.com/focu-a.jpg';
const _second = 'https://i0.hdslb.com/focu-b.jpg';
const _third = 'https://i1.biliimg.com/focu-c.jpg';
const _other = 'https://i0.hdslb.com/focu-other.jpg';

FollowingGroup _group(String id, String name, Iterable<String> urls) =>
    FollowingGroup(
      id: id,
      name: name,
      members: [
        for (final (index, url) in urls.indexed)
          creator(index + 1, '成员 ${index + 1}', url),
      ],
    );

Future<void> _saveGroups(int mid, List<FollowingGroup> groups) async {
  await (await SharedPreferences.getInstance()).setString(
    FollowingGroupService.storageKey(mid),
    jsonEncode({
      'groups': groups.map((group) => group.toJson()).toList(),
      'deleted': <int>[],
    }),
  );
}

List<String> _renderedImages(WidgetTester tester, Finder ancestor) => tester
    .widgetList<AppNetworkImage>(
      find.descendant(of: ancestor, matching: find.byType(AppNetworkImage)),
    )
    .map((image) => image.imageUrl)
    .toList();

Finder _homeRow(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ListTile));

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FollowingGroupService.instance.load(1);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('头像预览最多三张去重的公开 CDN 地址', () {
    FollowedCreator member(int i, String url) => creator(i, 'UP $i', url);
    expect(
      followingGroupAvatarUrls([
        member(1, 'file:///foo.png'),
        member(2, 'https://me:password@i0.hdslb.com/foo.png'),
        member(3, 'https://i0.hdslb.com/a.png?token=secret'),
        member(4, 'https://i0.hdslb.com:8080/a.png'),
        member(5, 'https://i0.hdslb.com.example.invalid/avatar.png'),
        member(6, '//i0.hdslb.com/focu-a.jpg'),
        member(7, _first),
        member(8, 'http://i0.hdslb.com/focu-b.jpg'),
        member(9, _third),
        member(10, _other),
      ]),
      [_first, _second, _third],
    );
  });

  testWidgets('首页与编辑两处显示分组头像，更新为空、切账号时不留旧图', (tester) async {
    final api = Api();
    final groups = FollowingGroupService();
    await seed(api, [choice('group', 'saved', '已选甲')]);
    await _saveGroups(101, [
      _group('saved', '已选甲', [_first, _second, _third, _other]),
      _group('candidate', '候选乙', [_other]),
      _group('empty', '空分组', const []),
    ]);
    api.mid = 202;
    await seed(api, [choice('group', 'saved', '另一账号')]);
    await _saveGroups(202, [
      _group('saved', '另一账号', [_other]),
    ]);
    api.mid = 101;
    final prefs = await SharedPreferences.getInstance();
    final original = prefs.getString(key(api, false));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCollectionCard(
            favorites: false,
            showCustomization: true,
            accountDataService: api,
            localGroups: groups,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(_renderedImages(tester, _homeRow('已选甲')), [_first, _second, _third]);
    expect(api.calls, 0);

    await tap(tester, find.byTooltip('自定义内容'));
    await tap(tester, find.byKey(const ValueKey('home-mode-custom')));
    final selected = find.byKey(const ValueKey('preview-group:saved'));
    final candidate = find.byKey(const ValueKey('preview-group:candidate'));
    final empty = find.byKey(const ValueKey('preview-group:empty'));
    expect(_renderedImages(tester, selected), [_first, _second, _third]);
    expect(_renderedImages(tester, candidate), [_other]);
    expect(
      find.descendant(of: empty, matching: find.byIcon(Icons.groups_outlined)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reorder-group:saved')), findsOneWidget);
    expect(api.calls, 1); // Original followed candidates, not avatar lookups.

    await tap(tester, find.byKey(const ValueKey('home-mode-back')));
    await groups.save(101, [_group('saved', '已选甲', const [])]);
    await tap(tester, find.byKey(const ValueKey('home-mode-custom')));
    expect(_renderedImages(tester, selected), isEmpty);
    expect(
      find.descendant(
        of: selected,
        matching: find.byIcon(Icons.groups_outlined),
      ),
      findsOneWidget,
    );
    expect(prefs.getString(key(api, false)), original);

    api.mid = 202;
    CacheLifecycle.accountChanged();
    await settle(tester);
    expect(find.text('账号已变化，请返回后重新打开'), findsOneWidget);
    expect(find.byType(FollowingGroupAvatar), findsNothing);
    await tester.pageBack();
    await settle(tester);
    expect(find.text('已选甲'), findsNothing);
    expect(_renderedImages(tester, _homeRow('另一账号')), [_other]);
  });

  testWidgets('关注分组总览显示头像，保留拖动与展开，账号失效时清空', (tester) async {
    final api = Api();
    await _saveGroups(101, [
      _group('with', '总览分组', [_first, _second]),
      _group('empty', '总览空组', const []),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: FollowingGroupsPage(accountDataService: api)),
    );
    await settle(tester);
    final group = find.byKey(const ValueKey('with'));
    final empty = find.byKey(const ValueKey('empty'));
    expect(_renderedImages(tester, group), [_first, _second]);
    expect(
      find.descendant(
        of: group,
        matching: find.byType(ReorderableDragStartListener),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: empty, matching: find.byIcon(Icons.groups_outlined)),
      findsOneWidget,
    );
    await tap(tester, find.text('总览分组'));
    expect(find.text('成员 1'), findsOneWidget);
    expect(api.calls, 0);
    CacheLifecycle.accountChanged();
    await settle(tester);
    expect(find.byType(FollowingGroupAvatar), findsNothing);
    expect(find.text('总览分组'), findsNothing);
  });
}
