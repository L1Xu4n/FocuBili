import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/following_groups_page.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends BilibiliAccountDataService {
  int mid = 7;
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

FollowingGroupImport _snapshot(int mid, String name) => FollowingGroupImport(
  mid,
  [FollowingGroup(id: 'remote_1', name: name, remoteId: 1)],
);

final _toggle = find.widgetWithText(SwitchListTile, '自动同步 B 站分组');

Future<void> _open(WidgetTester tester, _Api api) async {
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
    expect(find.text('自动同步失败，本机分组未改变'), findsOneWidget);
    expect(find.text('首次同步'), findsOneWidget);
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
