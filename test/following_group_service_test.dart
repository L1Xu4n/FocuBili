import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/following_group_service.dart';

/// 构造无凭据成员，验证导入只依赖公开身份。
FollowedCreator member(int id) => FollowedCreator(
  mid: id,
  name: 'UP$id',
  avatarUrl: '',
  sign: '',
  officialDescription: '',
  followedAt: null,
);

FollowingGroup remote(int id, String name, List<int> mids) => FollowingGroup(
  id: 'remote_$id',
  remoteId: id,
  name: name,
  members: mids.map(member),
);

/// 覆盖重复导入保留编辑、账号隔离，以及损坏数据不被覆盖。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'merge preserves rename, member removal, order and deleted groups per account',
    () async {
      final service = FollowingGroupService();
      final imported = FollowingGroupImport(7, [
        FollowingGroup(
          id: 'remote_1',
          remoteId: 1,
          name: '远端',
          members: [member(1), member(2)],
        ),
      ]);
      await service.merge(imported);
      final first = (await service.load(7)).single;
      await service.save(7, [
        first.copyWith(name: '本机名称', members: [member(2)], excluded: [1]),
      ]);
      await service.merge(imported);
      final result = (await service.load(7)).single;
      expect(result.name, '本机名称');
      expect(result.members.map((m) => m.mid), [2]);
      expect(await service.load(8), isEmpty);
      await service.save(7, []);
      await service.merge(imported);
      expect(await service.load(7), isEmpty);
    },
  );
  test(
    'setting is isolated per UID and survives group edits and merge',
    () async {
      final service = FollowingGroupService();
      expect((await service.loadState(7)).autoSync, isFalse);
      await service.saveAutoSync(7, true);
      await service.save(7, [FollowingGroup(id: 'local_a', name: '本地')]);
      await service.merge(FollowingGroupImport(7, []));
      final reopened = FollowingGroupService();
      expect((await reopened.loadState(7)).autoSync, isTrue);
      expect((await reopened.loadState(8)).autoSync, isFalse);
      expect((await reopened.load(7)).single.name, '本地');
    },
  );

  test('invalidated auto sync never writes its queued snapshot', () async {
    final service = FollowingGroupService();
    final change = service.mirrorFromBilibili(
      FollowingGroupImport(7, [
        FollowingGroup(id: 'remote_1', name: '远端', remoteId: 1),
      ]),
      isCurrent: () => false,
    );
    await expectLater(change, throwsStateError);
    expect(await service.load(7), isEmpty);
  });

  test(
    'manual merge only restores explicitly selected groups for this UID',
    () async {
      final service = FollowingGroupService();
      final old = remote(1, '旧组', [1]);
      final other = remote(2, '另一个旧组', [2]);
      final fresh = remote(3, '新组', [3]);
      for (final mid in [7, 8]) {
        await service.merge(FollowingGroupImport(mid, [old, other]));
        await service.save(mid, []);
      }
      expect(await service.deletedRemoteIds(7), {1, 2});
      final snapshot = FollowingGroupImport(7, [old, other, fresh]);

      final skipped = await service.mergeManually(
        snapshot,
        restoreRemoteIds: {},
      );
      expect(skipped.groups.map((g) => g.remoteId), [3]);
      expect(skipped.skippedDeletedGroups, 2);
      expect(skipped.addedGroups, 1);
      expect(skipped.restoredGroups, 0);
      await expectLater(
        service.mergeManually(
          snapshot,
          restoreRemoteIds: {1},
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(await service.deletedRemoteIds(7), {1, 2});
      final restored = await service.mergeManually(
        snapshot,
        restoreRemoteIds: {1},
      );
      expect(restored.groups.map((g) => g.remoteId), [3, 1]);
      expect(restored.addedGroups, 0);
      expect(restored.restoredGroups, 1);
      expect(restored.skippedDeletedGroups, 1);
      expect(await service.deletedRemoteIds(7), {2});
      expect(await service.deletedRemoteIds(8), {1, 2});
      expect(await service.load(8), isEmpty);

      final repeated = await service.mergeManually(
        snapshot,
        restoreRemoteIds: {1},
      );
      expect(repeated.groups.map((g) => g.remoteId), [3, 1]);
      expect(repeated.addedGroups, 0);
      expect(repeated.restoredGroups, 0);
      expect(repeated.addedMembers, 0);
    },
  );

  test(
    'manual merge adds members without replacing local edits or removing groups',
    () async {
      final service = FollowingGroupService();
      await service.save(7, [
        remote(1, '之前导入', [10, 90]).copyWith(name: '本机名称', excluded: [11]),
        remote(2, '远端后来删除', [20]),
      ]);
      final result = await service.mergeManually(
        FollowingGroupImport(7, [
          remote(1, '远端改名', [10, 11, 12]),
        ]),
        restoreRemoteIds: {},
      );
      expect(result.groups.map((g) => g.name), ['本机名称', '远端后来删除']);
      expect(result.groups.first.members.map((m) => m.mid), [10, 90, 12]);
      expect(result.groups.first.excluded, {11});
      expect(result.addedMembers, 1);
    },
  );

  test(
    'automatic mirror restores, renames, updates, and removes linked groups',
    () async {
      final service = FollowingGroupService();
      final localA = FollowingGroup(
        id: 'local_a',
        name: '本机自建 A',
        members: [member(91)],
      );
      final localB = FollowingGroup(
        id: 'local_b',
        name: '本机自建 B',
        members: [member(92)],
      );
      final linkedA = FollowingGroup(
        id: 'stable_home_reference',
        remoteId: 1,
        name: '本机改过名称',
        members: [member(90)],
        excluded: [11],
      );
      final linkedB = remote(2, '远端随后也删除', [21]);
      final linkedC = remote(3, '本机随后删除', [31]);
      final linkedD = remote(4, '另一个留存分组', [41]);
      await service.save(7, [
        linkedA,
        localA,
        linkedB,
        localB,
        linkedC,
        linkedD,
      ]);
      await service.save(7, [linkedA, localA, linkedB, localB, linkedD]);
      expect(await service.deletedRemoteIds(7), {3});
      await service.save(8, [linkedB]);

      final result = await service.mirrorFromBilibili(
        FollowingGroupImport(7, [
          remote(4, '远端 D', [41]),
          remote(3, '远端 C', [31]),
          remote(1, '远端 A', [10, 11]),
        ]),
      );
      expect(result.where((g) => g.remoteId != null).map((g) => g.remoteId), [
        4,
        3,
        1,
      ]);
      expect(result.where((g) => g.remoteId == null).map((g) => g.toJson()), [
        localA.toJson(),
        localB.toJson(),
      ]);
      final a = result.singleWhere((g) => g.remoteId == 1);
      expect(a.id, 'stable_home_reference');
      expect(a.name, '远端 A');
      expect(a.members.map((m) => m.mid), [10, 11]);
      expect(a.excluded, isEmpty);
      expect(await service.deletedRemoteIds(7), isEmpty);
      expect((await service.load(8)).single.remoteId, 2);

      final empty = await service.mirrorFromBilibili(
        FollowingGroupImport(7, []),
      );
      expect(empty.map((g) => g.id), ['local_a', 'local_b']);
      expect((await service.load(7)).map((g) => g.id), ['local_a', 'local_b']);
    },
  );

  test(
    'invalid automatic snapshots and canceled empty sync leave all groups untouched',
    () async {
      final service = FollowingGroupService();
      final linked = remote(1, '已导入', [11]);
      await service.save(7, [linked]);
      for (final snapshot in [
        FollowingGroupImport(7, [linked, linked]),
        FollowingGroupImport(7, [
          FollowingGroup(id: 'local_unknown', name: '未关联'),
        ]),
      ]) {
        await expectLater(
          service.mirrorFromBilibili(snapshot),
          throwsStateError,
        );
      }
      await expectLater(
        service.mirrorFromBilibili(
          FollowingGroupImport(7, []),
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect((await service.load(7)).single.toJson(), linked.toJson());
    },
  );

  test('malformed storage is never replaced by an import', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(FollowingGroupService.storageKey(7), 'broken');
    final service = FollowingGroupService();
    await expectLater(
      service.merge(FollowingGroupImport(7, [])),
      throwsFormatException,
    );
    expect(prefs.getString(FollowingGroupService.storageKey(7)), 'broken');
  });
}
