import 'package:flutter/material.dart';
import '../../models/account_collection.dart';
import '../../models/following_group.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/following_group_service.dart';
import '../../services/cache_lifecycle.dart';
import 'user_profile_page.dart';

/// 当前账号的本机分组编辑与只读导入入口。
class FollowingGroupsPage extends StatefulWidget {
  /// 可指定直接打开的分组，首页自选卡片复用此入口。
  const FollowingGroupsPage({super.key, this.accountDataService, this.groupId});
  final BilibiliAccountDataService? accountDataService;
  final String? groupId;

  /// 创建维护本机编辑快照的页面状态。
  @override
  State<FollowingGroupsPage> createState() => _FollowingGroupsPageState();
}

class _FollowingGroupsPageState extends State<FollowingGroupsPage> {
  late final _api = widget.accountDataService ?? BilibiliAccountDataService();
  final _store = FollowingGroupService.instance;
  List<FollowingGroup> _groups = [];
  int? _mid;
  bool _busy = true;
  String? _error;
  bool _invalidated = false;

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
      final mid = await _checkAccount();
      final groups = await _store.load(mid);
      if (mounted && !_invalidated) {
        setState(() {
          _mid = mid;
          _groups = groups;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 提交一个完整本机快照，保存成功后才更新界面。
  Future<void> _save(List<FollowingGroup> groups) async {
    if (_busy) return;
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
    setState(() => _busy = true);
    try {
      final mid = await _checkAccount();
      final snapshot = await _api.loadFollowingGroups();
      if (!mounted || snapshot.mid != mid) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从 B 站导入分组'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (snapshot.groups.isEmpty) const Text('没有可导入的分组'),
                  for (final group in snapshot.groups)
                    ListTile(
                      title: Text(group.name),
                      trailing: Text('${group.members.length} 位'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: snapshot.groups.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('合并到本机'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (await _checkAccount() != snapshot.mid) throw StateError('账号已变化');
      final groups = await _store.merge(snapshot);
      if (mounted && !_invalidated) setState(() => _groups = groups);
    } catch (e) {
      _message('$e');
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
    if (_busy) return;
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
          onPressed: _busy || _mid == null ? null : _import,
          icon: const Icon(Icons.download_outlined),
        ),
        IconButton(
          tooltip: '新建分组',
          onPressed: _busy || _mid == null ? null : _rename,
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
              if (_busy) const LinearProgressIndicator(),
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
                            leading: ReorderableDragStartListener(
                              index: index,
                              enabled: !_busy,
                              child: const Icon(Icons.drag_handle),
                            ),
                            trailing: PopupMenuButton<String>(
                              enabled: !_busy,
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
    final visible = widget.creators
        .where((m) => m.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
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
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (_, index) {
                final member = visible[index];
                return CheckboxListTile(
                  title: Text(member.name),
                  value: _selected.contains(member.mid),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(member.mid);
                    } else {
                      _selected.remove(member.mid);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
