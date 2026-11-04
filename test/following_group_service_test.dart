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
