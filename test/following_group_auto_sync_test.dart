import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/following_groups_page.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends BilibiliAccountDataService {
  int? mid = 7;
  final requests = <Completer<FollowingGroupImport>>[];

  @override
  Future<int?> currentAccountMid() async => mid;

  @override
  Future<FollowingGroupImport> loadFollowingGroups() {
    final hold = Completer<FollowingGroupImport>();
    requests.add(hold);
    return hold.future;
  }
}

class _GroupReadSession implements BilibiliAccountSessionProvider {
  @override
  Future<BilibiliSessionState> loadCurrentSession() async =>
      const BilibiliSessionState.active(
        BilibiliAccount(mid: 7, name: '测试账号', avatarUrl: ''),
      );

  @override
  Future<String> readCookieHeader() async => 'SESSDATA=fixture';
}

class _GroupReadApi implements BilibiliAccountDataApi {
  int listReads = 0;

  @override
  Future<BilibiliAccountDataResponse> get(Uri endpoint, String _) async {
    if (endpoint.path == '/x/relation/tags') {
      listReads++;
      return BilibiliAccountDataResponse(
        statusCode: 200,
        body:
            '''
          {"code":0,"data":[
            {"tagid":-10,"name":"特别关注","count":0},
            {"tagid":42,"name":"课程","count":$listReads}
          ]}
        ''',
      );
    }
    expect(endpoint.path, '/x/relation/tag');
    expect(endpoint.queryParameters['tagid'], '42');
    expect(endpoint.queryParameters['pn'], '1');
    return BilibiliAccountDataResponse(
      statusCode: 200,
      body: listReads == 1
          ? '{"code":0,"data":[{"mid":11,"uname":"第一位"}]}'
          : '{"code":0,"data":[{"mid":11,"uname":"第一位"},{"mid":12,"uname":"第二位"}]}',
    );
  }
}

FollowingGroupImport _snapshot(int mid, String name, {int id = 1}) =>
    FollowingGroupImport(mid, [
      FollowingGroup(id: 'remote_$id', name: name, remoteId: id),
    ]);

final _toggle = find.widgetWithText(SwitchListTile, '自动同步 B 站分组');

Future<void> _open(WidgetTester tester, BilibiliAccountDataService api) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FollowingGroupsPage(
        accountDataService: api,
        groupService: FollowingGroupService(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _reopen(WidgetTester tester, _Api api) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await _open(tester, api);
}

Future<void> _preview(
  WidgetTester tester,
  _Api api,
  FollowingGroupImport snapshot,
) async {
  await tester.tap(find.byTooltip('从 B 站导入分组'));
  await tester.pump();
  api.requests.last.complete(snapshot);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
  });

  testWidgets('默认关闭；手动导入仍先确认，开启与重进各同步一次', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
    expect(api.requests, isEmpty);
    await tester.tap(find.byTooltip('从 B 站导入分组'));
    await tester.pump();
    api.requests.single.complete(_snapshot(7, '手动预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('合并到本机'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests[1].complete(_snapshot(7, '首次同步'));
    await tester.pumpAndSettle();
    expect(find.text('首次同步'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_toggle).value, isTrue);
    await _reopen(tester, api);
    expect(find.text('首次同步'), findsOneWidget);
    expect(api.requests, hasLength(3));
    api.requests[2].completeError(StateError('测试网络失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('自动同步失败，本机分组未改变'), findsOneWidget);
    expect(find.text('首次同步'), findsOneWidget);
  });

  testWidgets('真实读取服务用于手动确认合并和开启自动同步', (tester) async {
    final network = _GroupReadApi();
    final api = BilibiliAccountDataService(
      sessionProvider: _GroupReadSession(),
      api: network,
    );
    await _open(tester, api);
    final store = FollowingGroupService();
    expect(network.listReads, 0);
    await tester.tap(find.byTooltip('从 B 站导入分组'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('合并到本机'), findsOneWidget);
    expect(await store.load(7), isEmpty);

    await tester.tap(find.text('合并到本机'));
    await tester.pumpAndSettle();
    expect(network.listReads, 1);
    expect(find.text('1 位 UP 主'), findsOneWidget);
    expect((await store.load(7)).last.members.map((m) => m.mid), [11]);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(network.listReads, 2);
    expect(find.text('2 位 UP 主'), findsOneWidget);
    expect((await store.load(7)).last.members.map((m) => m.mid), [11, 12]);
  });

  testWidgets('手动预览默认跳过删除过的组，勾选一个只恢复该组并报告结果', (tester) async {
    final store = FollowingGroupService();
    final a = _snapshot(7, '本机删除 A').groups.single;
    final b = _snapshot(7, '本机删除 B', id: 2).groups.single;
    final snapshot = FollowingGroupImport(7, [a, b]);
    await store.merge(snapshot);
    await store.save(7, []);
    final api = _Api();
    await _open(tester, api);

    final aChoice = find.widgetWithText(CheckboxListTile, '本机删除 A');
    final bChoice = find.widgetWithText(CheckboxListTile, '本机删除 B');
    final confirm = find.widgetWithText(FilledButton, '合并到本机');
    await _preview(tester, api, snapshot);
    expect(find.textContaining('已从本机删除，勾选后恢复'), findsNWidgets(2));
    expect(tester.widget<CheckboxListTile>(aChoice).value, isFalse);
    expect(tester.widget<CheckboxListTile>(bChoice).value, isFalse);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(await store.load(7), isEmpty);
    expect(find.textContaining('本机分组没有变化。跳过 2 个'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _preview(tester, api, snapshot);
    await tester.tap(aChoice);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(aChoice).value, isTrue);
    expect(tester.widget<CheckboxListTile>(bChoice).value, isFalse);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(confirm, findsNothing);
    expect((await store.load(7)).map((g) => g.remoteId), [1]);
    expect(await store.deletedRemoteIds(7), {2});
    expect(find.text('本机删除 A'), findsOneWidget);
    expect(find.text('本机删除 B'), findsNothing);
    expect(find.textContaining('恢复 1 个分组。跳过 1 个'), findsOneWidget);
  });

  testWidgets('完整空快照会清空远端关联组，读取失败不会清空', (tester) async {
    final store = FollowingGroupService();
    final remote = _snapshot(7, '原 B 站分组').groups.single;
    final local = FollowingGroup(id: 'local_a', name: '本机自建分组');
    await store.save(7, [remote, local]);
    await store.saveAutoSync(7, true);
    final api = _Api();
    await _open(tester, api);
    api.requests.single.completeError(StateError('B 站返回不完整'));
    await tester.pumpAndSettle();
    expect(find.text('原 B 站分组'), findsOneWidget);
    expect(find.text('本机自建分组'), findsOneWidget);
    expect((await store.load(7)).map((g) => g.id), ['remote_1', 'local_a']);

    await _reopen(tester, api);
    api.requests.last.complete(FollowingGroupImport(7, []));
    await tester.pumpAndSettle();
    expect(find.text('原 B 站分组'), findsNothing);
    expect(find.text('本机自建分组'), findsOneWidget);
    expect((await store.load(7)).map((g) => g.id), ['local_a']);
  });

  testWidgets('账号切换后手动导入确认不得写入旧分组', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byTooltip('从 B 站导入分组'));
    await tester.pump();
    api.requests.single.complete(_snapshot(7, '旧账号预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('合并到本机'), findsOneWidget);

    api.mid = 8;
    CacheLifecycle.accountChanged();
    await tester.pump();
    expect(find.text('旧账号预览'), findsNothing);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '合并到本机'),
    );
    expect(confirm.onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await FollowingGroupService().load(7), isEmpty);
    expect(await FollowingGroupService().load(8), isEmpty);
  });

  testWidgets('确认时暂时无法验证会话，不擦除本机分组', (tester) async {
    final store = FollowingGroupService();
    await store.save(7, [FollowingGroup(id: 'local_1', name: '原有本机分组')]);
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byTooltip('从 B 站导入分组'));
    await tester.pump();
    api.requests.single.complete(_snapshot(7, '新分组'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    api.mid = null;
    await tester.tap(find.text('合并到本机'));
    await tester.pumpAndSettle();
    expect(find.text('原有本机分组'), findsOneWidget);
    expect(find.text('新分组'), findsNothing);
    expect(find.textContaining('暂时无法确认当前账号'), findsOneWidget);
    expect((await store.load(7)).single.name, '原有本机分组');
  });

  testWidgets('同步期间可关可开；旧响应不落盘，也不并发重读', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(1));
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '新建分组',
            ),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(1));
    api.requests[0].complete(_snapshot(7, '不应该写入'));
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests[1].complete(_snapshot(7, '新请求'));
    await tester.pumpAndSettle();
    expect(find.text('新请求'), findsOneWidget);
    expect(find.text('不应该写入'), findsNothing);
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    await _reopen(tester, api);
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
    expect(api.requests, hasLength(2));
  });

  testWidgets('切账号后丢弃旧请求，开关按 UID 隔离', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(1));
    api.mid = 8;
    CacheLifecycle.accountChanged();
    api.requests[0].complete(_snapshot(7, '上一账号迟到分组'));
    await tester.pumpAndSettle();
    expect(find.text('上一账号迟到分组'), findsNothing);
    expect(await FollowingGroupService().load(7), isEmpty);
    await _reopen(tester, api);
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
    expect(api.requests, hasLength(1));
  });
}
