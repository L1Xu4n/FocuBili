import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/following_group.dart';

/// 一次手动合并实际应用的结果，用于区分新增、恢复和无变化。
class FollowingGroupMergeResult {
  const FollowingGroupMergeResult({
    required this.groups,
    required this.addedGroups,
    required this.restoredGroups,
    required this.addedMembers,
    required this.skippedDeletedGroups,
  });

  final List<FollowingGroup> groups;
  final int addedGroups;
  final int restoredGroups;
  final int addedMembers;
  final int skippedDeletedGroups;
}

/// 按账号 UID 隔离本地分组；串行读改写，失败保留最后成功快照。
class FollowingGroupService {
  /// 注入偏好存储便于验证账号隔离与导入合并。
  FollowingGroupService({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _loader = preferencesLoader ?? SharedPreferences.getInstance;
  static final instance = FollowingGroupService();
  final Future<SharedPreferences> Function() _loader;
  Future<void> _pending = Future.value();
  final Map<int, String?> _fallback = {};
  final _changes = ValueNotifier<({int mid, int revision})?>(null);

  /// 通知本次成功落盘的账号，不广播分组内容。
  ValueListenable<({int mid, int revision})?> get changes => _changes;

  /// 仅接受登录账号，避免所有访客共用一个分组空间。
  static String storageKey(int mid) {
    if (mid <= 0) throw StateError('请先登录 B 站账号');
    return 'following_groups.v1.$mid';
  }

  /// 读取当前账号的完整本地文档，失败时拒绝把损坏数据当作空列表。
  Future<Map<String, dynamic>> _read(int mid) async {
    final prefs = await _loader();
    final raw = _fallback.containsKey(mid)
        ? _fallback[mid]
        : prefs.getString(storageKey(mid));
    return raw == null
        ? {'groups': <dynamic>[], 'deleted': <dynamic>[]}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  /// 等待已提交操作后返回不可变分组快照。
  Future<List<FollowingGroup>> load(int mid) async =>
      (await loadState(mid)).groups;

  /// 打开页面时同时读取分组和开关，旧文档默认关闭。
  Future<({List<FollowingGroup> groups, bool autoSync})> loadState(
    int mid,
  ) async {
    await _pending;
    final data = await _read(mid);
    return (groups: _groupsFrom(data), autoSync: data['autoSync'] == true);
  }

  Future<void> saveAutoSync(int mid, bool enabled) =>
      _change(mid, (data) => data['autoSync'] = enabled);

  /// 预览只读取当前账号主动删除过的远端分组，不改变任何本机数据。
  Future<Set<int>> deletedRemoteIds(int mid) async {
    await _pending;
    final data = await _read(mid);
    return Set.unmodifiable((data['deleted'] as List).cast<int>());
  }

  /// 排队执行一项本地变更；底层失败时回退缓存，不写远端。
  Future<void> _change(
    int mid,
    void Function(Map<String, dynamic>) change, {
    bool Function()? isCurrent,
  }) {
    final result = _pending.then((_) async {
      final data = await _read(mid);
      final previous = jsonEncode(data);
      change(data);
      final prefs = await _loader();
      if (isCurrent?.call() == false) throw StateError('同步已取消');
      try {
        if (!await prefs.setString(storageKey(mid), jsonEncode(data))) {
          throw StateError('保存分组失败');
        }
        _fallback.remove(mid);
      } catch (_) {
        _fallback[mid] = previous;
        rethrow;
      }
      _changes.value = (
        mid: mid,
        revision: (_changes.value?.revision ?? 0) + 1,
      );
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 保存当前顺序与编辑结果，并记住删除的远端分组，重复导入不使它复活。
  Future<void> save(int mid, List<FollowingGroup> groups) =>
      _change(mid, (data) {
        final ids = groups.map((g) => g.id).toSet();
        final deleted = (data['deleted'] as List).cast<int>().toSet();
        for (final raw in data['groups'] as List) {
          final old = FollowingGroup.fromJson(
            Map<String, dynamic>.from(raw as Map),
          );
          if (!ids.contains(old.id) && old.remoteId != null) {
            deleted.add(old.remoteId!);
          }
        }
        data['groups'] = groups.map((g) => g.toJson()).toList();
        data['deleted'] = deleted.toList();
      });

  /// 一次合并完整导入结果，保留本地名称、顺序、删除记录与成员改动。
  Future<List<FollowingGroup>> merge(
    FollowingGroupImport snapshot, {
    bool Function()? isCurrent,
  }) async => (await _merge(snapshot, isCurrent: isCurrent)).groups;

  /// 只有显式勾选的分组可以撤销本机删除；其他分组沿用正常合并规则。
  Future<FollowingGroupMergeResult> mergeManually(
    FollowingGroupImport snapshot, {
    required Set<int> restoreRemoteIds,
    bool Function()? isCurrent,
  }) => _merge(
    snapshot,
    restoreRemoteIds: Set.of(restoreRemoteIds),
    isCurrent: isCurrent,
  );

  /// 完整、已验号的远端快照是自动同步的唯一来源；本机自建分组不受影响。
  Future<List<FollowingGroup>> mirrorFromBilibili(
    FollowingGroupImport snapshot, {
    bool Function()? isCurrent,
  }) async {
    late List<FollowingGroup> saved;
    await _change(snapshot.mid, (data) {
      final previous = _groupsFrom(data);
      final previousByRemoteId = {
        for (final group in previous)
          if (group.remoteId != null) group.remoteId!: group,
      };
      final remoteIds = <int>{};
      final matching = <FollowingGroup>[];
      for (final remote in snapshot.groups) {
        final id = remote.remoteId;
        if (id == null || !remoteIds.add(id)) {
          throw StateError('B 站分组资料不完整，请重试');
        }
        final existing = previousByRemoteId[id];
        // 保留本机稳定 ID，避免已有首页卡片丢失关联。
        matching.add(
          existing?.copyWith(
                name: remote.name,
                members: remote.members,
                excluded: const [],
              ) ??
              remote,
        );
      }
      var nextRemote = 0;
      final groups = [
        for (final group in previous)
          if (group.remoteId == null)
            group
          else if (nextRemote < matching.length)
            matching[nextRemote++],
        ...matching.skip(nextRemote),
      ];
      data['groups'] = groups.map((g) => g.toJson()).toList();
      data['deleted'] = (data['deleted'] as List)
          .cast<int>()
          .where((id) => !remoteIds.contains(id))
          .toList();
      saved = List.unmodifiable(groups);
    }, isCurrent: isCurrent);
    return saved;
  }

  List<FollowingGroup> _groupsFrom(Map<String, dynamic> data) =>
      (data['groups'] as List)
          .map(
            (e) => FollowingGroup.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();

  Future<FollowingGroupMergeResult> _merge(
    FollowingGroupImport snapshot, {
    Set<int> restoreRemoteIds = const {},
    bool Function()? isCurrent,
  }) async {
    late FollowingGroupMergeResult result;
    await _change(snapshot.mid, (data) {
      final groups = _groupsFrom(data);
      final deleted = (data['deleted'] as List).cast<int>().toSet();
      var addedGroups = 0;
      var restoredGroups = 0;
      var addedMembers = 0;
      var skippedDeletedGroups = 0;
      for (final remote in snapshot.groups) {
        final remoteId = remote.remoteId;
        final wasDeleted = remoteId != null && deleted.contains(remoteId);
        if (wasDeleted && !restoreRemoteIds.contains(remoteId)) {
          skippedDeletedGroups++;
          continue;
        }
        if (wasDeleted) {
          deleted.remove(remoteId);
          restoredGroups++;
        }
        final index = groups.indexWhere((g) => g.remoteId == remote.remoteId);
        if (index < 0) {
          groups.add(remote);
          if (!wasDeleted) addedGroups++;
          continue;
        }
        final local = groups[index];
        final members = {
          for (final member in local.members) member.mid: member,
        };
        for (final member in remote.members) {
          if (!local.excluded.contains(member.mid)) {
            members.putIfAbsent(member.mid, () {
              addedMembers++;
              return member;
            });
          }
        }
        groups[index] = local.copyWith(members: members.values);
      }
      data['groups'] = groups.map((g) => g.toJson()).toList();
      if (restoredGroups > 0) data['deleted'] = deleted.toList();
      result = FollowingGroupMergeResult(
        groups: List.unmodifiable(groups),
        addedGroups: addedGroups,
        restoredGroups: restoredGroups,
        addedMembers: addedMembers,
        skippedDeletedGroups: skippedDeletedGroups,
      );
    }, isCurrent: isCurrent);
    return result;
  }
}
