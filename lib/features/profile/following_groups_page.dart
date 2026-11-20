import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/widgets/drag_checkbox_options.dart';
import '../../models/account_collection.dart';
import '../../models/following_group.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/following_group_service.dart';
import '../../services/cache_lifecycle.dart';
import '../common/following_group_avatar.dart';
import 'user_profile_page.dart';

/// 当前账号的本机分组编辑与只读导入入口。
class FollowingGroupsPage extends StatefulWidget {
  /// 可指定直接打开的分组，首页自选卡片复用此入口。
  const FollowingGroupsPage({
    super.key,
    this.accountDataService,
    this.groupId,
    this.groupService,
  });
  final BilibiliAccountDataService? accountDataService;
  final String? groupId;
  final FollowingGroupService? groupService;

  /// 创建维护本机编辑快照的页面状态。
  @override
  State<FollowingGroupsPage> createState() => _FollowingGroupsPageState();
}

class _FollowingGroupsPageState extends State<FollowingGroupsPage> {
  late final _api = widget.accountDataService ?? BilibiliAccountDataService();
  late final _store = widget.groupService ?? FollowingGroupService.instance;
  List<FollowingGroup> _groups = [];
  int? _mid;
  bool _busy = true;
  String? _error;
  bool _invalidated = false;
  bool _autoSync = false;
  bool _savingAutoSync = false;
  bool _autoSyncRunning = false;
  int _syncRevision = 0;

  bool get _activeAutoSync => _autoSync && _autoSyncRunning;
  bool get _editingBlocked =>
      _busy || _activeAutoSync || _savingAutoSync || _invalidated;

  bool _isCurrentAccount(int mid, int revision) =>
      mounted &&
      !_invalidated &&
      _mid == mid &&
      CacheLifecycle.account.value == revision;

  /// 进入页面时检查身份并加载本机分组。
  @override
  void initState() {
    super.initState();
    CacheLifecycle.account.addListener(_accountChanged);
    _load();
  }

  /// 账号变化立即清空旧分组，阻止后台页面继续展示前一账号资料。
  void _accountChanged() {
    if (mounted && _mid != null) {
      setState(() {
        _invalidated = true;
        _syncRevision++;
        _groups = [];
        _error = '账号已变化，请返回后重新打开';
      });
    }
  }

  /// 页面退出时解除账号监听。
  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }

  /// 核验当前身份；每次操作重查，切号时清空旧内容。
  Future<int> _checkAccount() async {
    final mid = await _api.currentAccountMid();
    if (_invalidated || mid == null || (_mid != null && mid != _mid)) {
      if (mounted) {
        setState(() {
          _invalidated = true;
          _groups = [];
        });
      }
      throw StateError('请返回并重新打开当前账号的分组');
    }
    return mid;
  }

  /// 加载失败保留错误提示，只有有效账号才能新建或导入。
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final revision = CacheLifecycle.account.value;
      final mid = await _checkAccount();
      final (:groups, :autoSync) = await _store.loadState(mid);
      if (mounted && !_invalidated) {
        if (revision != CacheLifecycle.account.value) {
          setState(() {
            _invalidated = true;
            _groups = [];
            _error = '账号已变化，请返回后重新打开';
          });
          return;
        }
        setState(() {
          _mid = mid;
          _groups = groups;
          _autoSync = autoSync;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_error == null) unawaited(_syncAutomatically());
  }

  Future<void> _setAutoSync(bool enabled) async {
    if (_savingAutoSync || _busy || _invalidated || _mid == null) return;
    final mid = _mid!;
    setState(() {
      _savingAutoSync = true;
      if (!enabled) _syncRevision++;
    });
    try {
      // Saving the preference is local; B 站 need not be reachable to turn it off.
      await _store.saveAutoSync(mid, enabled);
      if (mounted && !_invalidated) setState(() => _autoSync = enabled);
    } catch (_) {
      _message('没能保存自动同步设置，请重试');
    } finally {
      if (mounted) setState(() => _savingAutoSync = false);
    }
    if (enabled) unawaited(_syncAutomatically());
  }

  Future<void> _syncAutomatically() async {
    if (!mounted ||
        !_autoSync ||
        _invalidated ||
        _busy ||
        _savingAutoSync ||
        _autoSyncRunning ||
        _mid == null) {
      return;
    }
    final mid = _mid!;
    final revision = _syncRevision;
    final accountRevision = CacheLifecycle.account.value;
    bool isCurrent() =>
        _isCurrentAccount(mid, accountRevision) &&
        _autoSync &&
        revision == _syncRevision;

    setState(() => _autoSyncRunning = true);
    try {
      final snapshot = await _api.loadFollowingGroups(
        verifyMemberPagination: true,
      );
      if (!isCurrent()) return;
      if (snapshot.mid != mid) throw StateError('账号已变化');
      final groups = await _store.mirrorFromBilibili(
        snapshot,
        isCurrent: isCurrent,
      );
      if (isCurrent()) setState(() => _groups = groups);
    } catch (e) {
      if (isCurrent()) _showImportFailure(e, automatic: true);
    } finally {
      if (mounted) setState(() => _autoSyncRunning = false);
      // If re-enabled while the previous request was pending, wait for that
      // request to finish before starting a fresh read.
      if (revision != _syncRevision) unawaited(_syncAutomatically());
    }
  }

  /// 提交一个完整本机快照，保存成功后才更新界面。
  Future<void> _save(List<FollowingGroup> groups) async {
    if (_editingBlocked) return;
    setState(() => _busy = true);
    try {
      final mid = await _checkAccount();
      await _store.save(mid, groups);
      if (mounted && !_invalidated) setState(() => _groups = groups);
    } catch (e) {
      _message('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用短反馈报告操作失败，避免页面常驻额外说明。
  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _showImportFailure(Object error, {required bool automatic}) {
    final action = automatic ? '自动同步失败' : '导入失败';
    final detail = error is StateError ? '：${error.message}' : '';
    _message('$action，本机分组未改变$detail');
  }

  void _showImportResult(FollowingGroupMergeResult result) {
    final changes = [
      if (result.addedGroups > 0) '新增 ${result.addedGroups} 个分组',
      if (result.restoredGroups > 0) '恢复 ${result.restoredGroups} 个分组',
      if (result.addedMembers > 0) '向已有分组补充 ${result.addedMembers} 位成员',
    ];
    final headline = changes.isEmpty ? '本机分组没有变化' : changes.join('，');
    final skipped = result.skippedDeletedGroups;
    _message(skipped == 0 ? headline : '$headline。跳过 $skipped 个本机删除过的分组。');
  }

  /// 新建或重命名本机分组，不修改 B 站原分组。
  Future<void> _rename([FollowingGroup? group]) async {
    final controller = TextEditingController(text: group?.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(group == null ? '新建分组' : '重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 等待退出动画卸载输入框后再释放控制器。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    await _save(
      group == null
          ? [
              ..._groups,
              FollowingGroup(
                id: 'local_${DateTime.now().microsecondsSinceEpoch}',
                name: name,
              ),
            ]
          : [
              for (final item in _groups)
                if (item.id == group.id) item.copyWith(name: name) else item,
            ],
    );
  }

  /// 展示远端完整快照，用户确认后合并，任何失败都保持本地资料。
  Future<void> _import() async {
    final mid = _mid;
    if (_editingBlocked || mid == null) return;
    final revision = CacheLifecycle.account.value;
    bool isCurrent() => _isCurrentAccount(mid, revision);
    setState(() => _busy = true);
    try {
      final snapshot = await _api.loadFollowingGroups();
      if (!mounted || !isCurrent()) return;
      if (snapshot.mid != mid) throw StateError('账号已变化，请重新导入');
      final deleted = await _store.deletedRemoteIds(mid);
      if (!mounted || !isCurrent()) return;
      final groups = snapshot.groups;
      final selected = <int>{};
      final restoreRemoteIds = await showDialog<Set<int>>(
        context: context,
        builder: (context) => ValueListenableBuilder(
          valueListenable: CacheLifecycle.account,
          builder: (context, _, _) => StatefulBuilder(
            builder: (context, update) {
              final current = isCurrent();
              void setChecked(int first, int last, bool checked) {
                if (!isCurrent()) return;
                update(() {
                  for (var i = first; i <= last; i++) {
                    final id = groups[i].remoteId;
                    if (id == null || !deleted.contains(id)) continue;
                    if (checked) {
                      selected.add(id);
                    } else {
                      selected.remove(id);
                    }
                  }
                });
              }

              return AlertDialog(
                title: const Text('从 B 站导入分组'),
                content: current
                    ? SizedBox(
                        width: 420,
                        child: DragCheckboxOptions(
                          itemCount: groups.length,
                          checkedAt: (index) =>
                              selected.contains(groups[index].remoteId),
                          onRangeChanged: setChecked,
                          builder: (context, controller, physics) =>
                              SingleChildScrollView(
                                controller: controller,
                                physics: physics,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (groups.isEmpty) const Text('没有可导入的分组'),
                                    for (final (index, group) in groups.indexed)
                                      if (deleted.contains(group.remoteId))
                                        DragCheckboxTile(
                                          index: index,
                                          title: Text(group.name),
                                          subtitle: Text(
                                            '已从本机删除，勾选后恢复（${group.members.length} 位）',
                                          ),
                                          value: selected.contains(
                                            group.remoteId,
                                          ),
                                          onChanged: (checked) =>
                                              setChecked(index, index, checked),
                                        )
                                      else
                                        ListTile(
                                          title: Text(group.name),
                                          trailing: Text(
                                            '${group.members.length} 位',
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                        ),
                      )
                    : const Text('账号已变化，请重新导入'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: !current || snapshot.groups.isEmpty
                        ? null
                        : () => Navigator.pop(context, Set<int>.of(selected)),
                    child: const Text('合并到本机'),
                  ),
                ],
              );
            },
          ),
        ),
      );
      if (restoreRemoteIds == null || !isCurrent()) return;
      final currentMid = await _api.currentAccountMid();
      if (!isCurrent()) return;
      if (currentMid == null) throw StateError('暂时无法确认当前账号，请重试');
      if (currentMid != mid) {
        _accountChanged();
        return;
      }
      final result = await _store.mergeManually(
        snapshot,
        restoreRemoteIds: restoreRemoteIds,
        isCurrent: isCurrent,
      );
      if (isCurrent()) {
        setState(() => _groups = result.groups);
        _showImportResult(result);
      }
    } catch (e) {
      if (isCurrent()) _showImportFailure(e, automatic: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 读取全部关注分页供成员选择；失败时不打开不完整的编辑器。
  Future<void> _editMembers(FollowingGroup group) async {
    setState(() => _busy = true);
    try {
      await _checkAccount();
      final creators = {for (final member in group.members) member.mid: member};
      for (var page = 1; ; page++) {
        if (page > 1000) throw StateError('关注列表过大');
        final result = await _api.loadFollowedCreators(page: page);
        if (!result.isSuccess) throw StateError(result.message ?? '读取关注失败');
        for (final member in result.items) {
          creators[member.mid] = member;
        }
        if (!result.hasMore) break;
        if (result.items.isEmpty) throw StateError('关注分页异常');
      }
      await _checkAccount();
      if (!mounted) return;
      final selected = await Navigator.of(context).push<List<FollowedCreator>>(
        MaterialPageRoute(
          builder: (_) => _GroupMembersPicker(
            creators: creators.values.toList(),
            selected: group.members.map((m) => m.mid).toSet(),
          ),
        ),
      );
      if (selected == null || !mounted) return;
      final selectedIds = selected.map((m) => m.mid).toSet();
      final excluded = {...group.excluded, ...group.members.map((m) => m.mid)}
        ..removeAll(selectedIds);
      setState(() => _busy = false);
      await _save([
        for (final item in _groups)
          if (item.id == group.id)
            item.copyWith(members: selected, excluded: excluded)
          else
            item,
      ]);
    } catch (e) {
      _message('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除分组前确认，只删除本地容器，不取消关注成员。
  Future<void> _delete(FollowingGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${group.name}”？'),
        content: const Text('不会取消关注其中的 UP 主。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _save(_groups.where((g) => g.id != group.id).toList());
    }
  }

  /// 调整本机分组顺序，保留其他分组与成员。
  void _reorder(int oldIndex, int newIndex) {
    if (_editingBlocked) return;
    final next = [..._groups];
    next.insert(newIndex, next.removeAt(oldIndex));
    _save(next);
  }

  /// 用可展开列表呈现成员、编辑菜单与排序手柄。
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('关注分组'),
      actions: [
        IconButton(
          tooltip: '从 B 站导入分组',
          onPressed: _editingBlocked || _mid == null ? null : _import,
          icon: const Icon(Icons.download_outlined),
        ),
        IconButton(
          tooltip: '新建分组',
          onPressed: _editingBlocked || _mid == null ? null : _rename,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: _error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        : Column(
            children: [
              if (_mid != null)
                SwitchListTile(
                  title: const Text('自动同步 B 站分组'),
                  subtitle: const Text('进入此页时以 B 站分组为准，本机自建分组保留'),
                  value: _autoSync,
                  onChanged: _busy || _savingAutoSync ? null : _setAutoSync,
                ),
              if (_busy || _activeAutoSync) const LinearProgressIndicator(),
              Expanded(
                child: _groups.isEmpty
                    ? const Center(child: Text('还没有本机分组'))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        onReorderItem: _reorder,
                        itemCount: _groups.length,
                        itemBuilder: (context, index) {
                          final group = _groups[index];
                          return ExpansionTile(
                            key: ValueKey(group.id),
                            initiallyExpanded: widget.groupId == group.id,
                            title: Text(group.name),
                            subtitle: Text('${group.members.length} 位 UP 主'),
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ReorderableDragStartListener(
                                  index: index,
                                  enabled: !_editingBlocked,
                                  child: const Icon(Icons.drag_handle),
                                ),
                                const SizedBox(width: 8),
                                FollowingGroupAvatar(
                                  urls: followingGroupAvatarUrls(group.members),
                                ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              enabled: !_editingBlocked,
                              onSelected: (value) {
                                switch (value) {
                                  case 'name':
                                    _rename(group);
                                  case 'members':
                                    _editMembers(group);
                                  case 'delete':
                                    _delete(group);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'members',
                                  child: Text('调整成员'),
                                ),
                                PopupMenuItem(
                                  value: 'name',
                                  child: Text('重命名'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                            children: [
                              for (final member in group.members)
                                ListTile(
                                  leading: FollowingGroupMemberAvatar(
                                    member: member,
                                  ),
                                  title: Text(member.name),
                                  onTap: () => Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) => UserProfilePage(
                                        mid: member.mid,
                                        initialName: member.name,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
  );
}

/// 在独立全屏列表选择成员，小屏与大字号都能滚动。
class _GroupMembersPicker extends StatefulWidget {
  /// 接收完整关注快照及当前组选中的 UID。
  const _GroupMembersPicker({required this.creators, required this.selected});
  final List<FollowedCreator> creators;
  final Set<int> selected;

  /// 创建独立草稿，返回前不修改分组。
  @override
  State<_GroupMembersPicker> createState() => _GroupMembersPickerState();
}

class _GroupMembersPickerState extends State<_GroupMembersPicker> {
  late final _selected = {...widget.selected};
  String _query = '';

  /// 搜索并切换成员，保存时一次返回完整选择。
  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final visible = widget.creators
        .where((m) => m.name.toLowerCase().contains(query))
        .toList();
    void setChecked(int first, int last, bool checked) {
      setState(() {
        for (var i = first; i <= last; i++) {
          final mid = visible[i].mid;
          if (checked) {
            _selected.add(mid);
          } else {
            _selected.remove(mid);
          }
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('调整成员'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              widget.creators.where((m) => _selected.contains(m.mid)).toList(),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索 UP 主',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: DragCheckboxOptions(
              key: ValueKey(query),
              itemCount: visible.length,
              checkedAt: (index) => _selected.contains(visible[index].mid),
              onRangeChanged: setChecked,
              builder: (context, controller, physics) => ListView.builder(
                controller: controller,
                physics: physics,
                itemCount: visible.length,
                itemBuilder: (_, index) {
                  final member = visible[index];
                  return DragCheckboxTile(
                    key: ValueKey(member.mid),
                    index: index,
                    leading: FollowingGroupMemberAvatar(member: member),
                    title: Text(member.name),
                    value: _selected.contains(member.mid),
                    onChanged: (checked) => setChecked(index, index, checked),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
