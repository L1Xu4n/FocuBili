import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/following_group.dart';

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
  Future<List<FollowingGroup>> load(int mid) async {
    await _pending;
    final data = await _read(mid);
    return (data['groups'] as List)
        .map(
          (e) => FollowingGroup.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  /// 排队执行一项本地变更；底层失败时回退缓存，不写远端。
  Future<void> _change(int mid, void Function(Map<String, dynamic>) change) {
    final result = _pending.then((_) async {
      final data = await _read(mid);
      final previous = jsonEncode(data);
      change(data);
      final prefs = await _loader();
      try {
        if (!await prefs.setString(storageKey(mid), jsonEncode(data))) {
          throw StateError('保存分组失败');
        }
        _fallback.remove(mid);
      } catch (_) {
        _fallback[mid] = previous;
        rethrow;
      }
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
  Future<List<FollowingGroup>> merge(FollowingGroupImport snapshot) async {
    late List<FollowingGroup> saved;
    await _change(snapshot.mid, (data) {
      final groups = (data['groups'] as List)
          .map(
            (e) => FollowingGroup.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      final deleted = (data['deleted'] as List).cast<int>().toSet();
      for (final remote in snapshot.groups) {
        if (deleted.contains(remote.remoteId)) continue;
        final index = groups.indexWhere((g) => g.remoteId == remote.remoteId);
        if (index < 0) {
          groups.add(remote);
          continue;
        }
        final local = groups[index];
        final members = {
          for (final member in local.members) member.mid: member,
        };
        for (final member in remote.members) {
          if (!local.excluded.contains(member.mid)) {
            members.putIfAbsent(member.mid, () => member);
          }
        }
        groups[index] = local.copyWith(members: members.values);
      }
      data['groups'] = groups.map((g) => g.toJson()).toList();
      saved = List.unmodifiable(groups);
    });
    return saved;
  }
}
