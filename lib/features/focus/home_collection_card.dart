import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/account_collection.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/following_group_service.dart';
import '../profile/app_favorite_detail_page.dart';
import '../profile/app_favorite_folders_page.dart';
import '../profile/favorite_folders_page.dart';
import '../profile/favorite_videos_page.dart';
import '../profile/followed_creators_page.dart';
import '../profile/following_groups_page.dart';
import '../profile/user_profile_page.dart';

/// 首页选择项只保存稳定身份与展示名，不保存会话或远端媒体地址。
class _HomeChoice {
  /// 创建可打开的收藏夹、分组或 UP 主入口。
  const _HomeChoice(this.kind, this.id, this.label);
  final String kind;
  final String id;
  final String label;

  /// 合成跨来源不会碰撞的选择身份。
  String get key => '$kind:$id';

  /// 序列化用户顺序与入口身份。
  Map<String, String> toJson() => {'kind': kind, 'id': id, 'label': label};

  /// 读取本机配置，损坏项使本次读取失败而不覆盖原文件。
  factory _HomeChoice.fromJson(Map<String, dynamic> json) => _HomeChoice(
    json['kind'] as String,
    json['id'] as String,
    json['label'] as String,
  );
}

/// 可由用户主动添加的收藏/关注卡片，支持总览入口与自选内容。
class HomeCollectionCard extends StatefulWidget {
  /// 指定收藏或关注卡片，两类配置独立且按账号隔离。
  const HomeCollectionCard({super.key, required this.favorites});
  final bool favorites;

  /// 创建监听账号切换的卡片状态。
  @override
  State<HomeCollectionCard> createState() => _HomeCollectionCardState();
}

class _HomeCollectionCardState extends State<HomeCollectionCard> {
  final _api = BilibiliAccountDataService();
  final _favorites = AppFavoritesService();
  List<_HomeChoice> _selected = [];
  Map<String, String> _localFolderNames = {};
  int _folderNamesGeneration = 0;
  bool _custom = false;
  bool _loading = true;
  int _mid = 0;
  int _generation = 0;

  /// 返回当前账号和卡片类型的独立键。
  String _key(int mid) =>
      'home_collection.v1.${widget.favorites ? "favorites" : "followings"}.$mid';

  /// 初始读取配置，并订阅账号失效通知以立即隐藏旧账号内容。
  @override
  void initState() {
    super.initState();
    CacheLifecycle.account.addListener(_accountChanged);
    AppFavoritesService.folderNamesRevision.addListener(_loadLocalFolderNames);
    _load();
  }

  /// 退出卡片时解除账号监听，取消尚未完成的读取。
  @override
  void dispose() {
    _generation++;
    _folderNamesGeneration++;
    AppFavoritesService.folderNamesRevision.removeListener(
      _loadLocalFolderNames,
    );
    CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }

  /// 切号先清理视图，再读取新账号专属配置。
  void _accountChanged() {
    if (!mounted) return;
    setState(() {
      _selected = [];
      _custom = false;
      _loading = true;
    });
    _load();
  }

  /// 只接受最后一次账号读取的结果，避免旧请求覆盖新账号。
  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final mid = await _api.currentAccountMid() ?? 0;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(mid));
      final config = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final selected = (config['items'] as List? ?? [])
          .map((e) => _HomeChoice.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (selected.any((choice) => choice.kind == 'local')) {
        await _loadLocalFolderNames();
      }
      if (mounted && generation == _generation) {
        setState(() {
          _mid = mid;
          _custom = config['custom'] == true;
          _selected = selected;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  /// 本机名称独立刷新，不取消正在编辑的配置，也不回写保存的入口快照。
  Future<void> _loadLocalFolderNames() async {
    if (!widget.favorites) return;
    final generation = ++_folderNamesGeneration;
    try {
      final folders = await _favorites.loadFolders();
      if (mounted && generation == _folderNamesGeneration) {
        setState(() {
          _localFolderNames = {
            for (final folder in folders) folder.id: folder.name,
          };
        });
      }
    } catch (_) {
      // 损坏或不可读的收藏数据不应隐藏入口，继续显示最后成功名称或保存的名称。
    }
  }

  /// 仅本机收藏夹按稳定 ID 取当前名称，其他来源及已删除入口保留快照。
  String _label(_HomeChoice choice) => choice.kind == 'local'
      ? _localFolderNames[choice.id] ?? choice.label
      : choice.label;

  /// 显示短反馈，保留当前成功配置。
  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 统一打开页面，返回后刷新名称与账号配置。
  Future<void> _push(Widget page) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => page));
    if (mounted) await _load();
  }

  /// 收藏总览提供本机与 B 站两条直接路径，关注直接打开现有总览。
  Future<void> _overview() async {
    if (!widget.favorites) {
      await _push(const FollowedCreatorsPage());
      return;
    }
    final local = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('我的收藏'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('本机收藏夹'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('B 站收藏夹'),
          ),
        ],
      ),
    );
    if (local != null && mounted) {
      await _push(
        local ? const AppFavoriteFoldersPage() : const FavoriteFoldersPage(),
      );
    }
  }

  /// 按稳定编号解析入口，已删除或失效内容只反馈，不跳到其他项目。
  Future<void> _open(_HomeChoice choice) async {
    try {
      if (choice.kind != 'local' && await _api.currentAccountMid() != _mid) {
        _accountChanged();
        throw StateError('账号已变化，请重试');
      }
      if (!mounted) return;
      switch (choice.kind) {
        case 'local':
          final matches = (await _favorites.loadFolders()).where(
            (f) => f.id == choice.id,
          );
          if (matches.isEmpty) throw StateError('收藏夹已删除，请重新自定义');
          if (mounted) {
            await _push(AppFavoriteDetailPage(folder: matches.first));
          }
        case 'remote':
          await _push(
            FavoriteVideosPage(
              folder: FavoriteFolder(
                mediaId: int.parse(choice.id),
                title: choice.label,
                coverUrl: '',
                mediaCount: 0,
                isAvailable: true,
              ),
            ),
          );
        case 'group':
          final matches = (await FollowingGroupService.instance.load(
            _mid,
          )).where((g) => g.id == choice.id);
          if (matches.isEmpty) throw StateError('分组已删除，请重新自定义');
          if (mounted) await _push(FollowingGroupsPage(groupId: choice.id));
        case 'creator':
          await _push(
            UserProfilePage(
              mid: int.parse(choice.id),
              initialName: choice.label,
            ),
          );
      }
    } catch (e) {
      _message('$e');
    }
  }

  /// 收集可选内容，网络失败中止配置打开，不把部分列表写为新配置。
  Future<void> _configure() async {
    if (_loading) return;
    setState(() => _loading = true);
    final generation = _generation;
    try {
      final mid = await _api.currentAccountMid() ?? 0;
      final choices = <_HomeChoice>[];
      if (widget.favorites) {
        for (final folder in await _favorites.loadFolders()) {
          choices.add(_HomeChoice('local', folder.id, folder.name));
        }
        if (mid > 0) {
          final page = await _api.loadFavoriteFolders();
          if (!page.isSuccess) throw StateError(page.message ?? '读取收藏夹失败');
          for (final folder in page.items) {
            choices.add(
              _HomeChoice('remote', '${folder.mediaId}', folder.title),
            );
          }
        }
      } else if (mid > 0) {
        for (final group in await FollowingGroupService.instance.load(mid)) {
          choices.add(_HomeChoice('group', group.id, group.name));
        }
        final seen = <int>{};
        for (var page = 1; ; page++) {
          if (page > 1000) throw StateError('关注列表过大');
          final result = await _api.loadFollowedCreators(page: page);
          if (!result.isSuccess) throw StateError(result.message ?? '读取关注失败');
          final previous = seen.length;
          for (final creator in result.items) {
            if (seen.add(creator.mid)) {
              choices.add(
                _HomeChoice('creator', '${creator.mid}', creator.name),
              );
            }
          }
          if (!result.hasMore) break;
          if (seen.length == previous) throw StateError('关注分页异常');
        }
      }
      if (!mounted ||
          generation != _generation ||
          (await _api.currentAccountMid() ?? 0) != mid) {
        return;
      }
      if (!mounted) return;
      final config = await Navigator.of(context)
          .push<(bool, List<_HomeChoice>)>(
            MaterialPageRoute(
              builder: (_) => _HomeChoiceEditor(
                title: widget.favorites ? '我的收藏' : '我的关注',
                choices: choices,
                selected: mid == _mid
                    ? _selected
                          .map(
                            (item) =>
                                _HomeChoice(item.kind, item.id, _label(item)),
                          )
                          .toList()
                    : [],
                custom: mid == _mid && _custom,
              ),
            ),
          );
      if (config == null || !mounted || generation != _generation) return;
      if ((await _api.currentAccountMid() ?? 0) != mid) {
        throw StateError('账号已变化，配置未保存');
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        _key(mid),
        jsonEncode({
          'custom': config.$1,
          'items': config.$2.map((item) => item.toJson()).toList(),
        }),
      )) {
        throw StateError('保存失败');
      }
      if (mounted) {
        setState(() {
          _mid = mid;
          _custom = config.$1;
          _selected = config.$2;
        });
      }
    } catch (e) {
      _message('$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 卡片只呈现标题与入口，不增加常驻操作说明。
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              widget.favorites
                  ? Icons.bookmarks_outlined
                  : Icons.people_outline,
            ),
            title: Text(widget.favorites ? '我的收藏' : '我的关注'),
            onTap: _overview,
            trailing: IconButton(
              tooltip: '自定义内容',
              onPressed: _loading ? null : _configure,
              icon: const Icon(Icons.tune_rounded),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_custom && !_loading) ...[
            if (_selected.isEmpty)
              TextButton(onPressed: _configure, child: const Text('选择内容')),
            for (final choice in _selected)
              ListTile(
                dense: true,
                title: Text(_label(choice)),
                leading: Icon(
                  choice.kind == 'creator'
                      ? Icons.person_outline
                      : Icons.folder_outlined,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(choice),
              ),
          ],
        ],
      ),
    ),
  );
}

/// 独立编辑草稿，选择顺序由列表排序手柄决定。
class _HomeChoiceEditor extends StatefulWidget {
  /// 接收当前可用内容与已保存顺序，不在编辑过程中落盘。
  const _HomeChoiceEditor({
    required this.title,
    required this.choices,
    required this.selected,
    required this.custom,
  });
  final String title;
  final List<_HomeChoice> choices;
  final List<_HomeChoice> selected;
  final bool custom;

  /// 创建模式、选择与排序草稿。
  @override
  State<_HomeChoiceEditor> createState() => _HomeChoiceEditorState();
}

class _HomeChoiceEditorState extends State<_HomeChoiceEditor> {
  late bool _custom = widget.custom;
  late final List<_HomeChoice> _selected = [...widget.selected];
  String _query = '';

  /// 修改草稿中的选择，取消后不影响已保存配置。
  void _toggle(_HomeChoice choice, bool value) => setState(() {
    _selected.removeWhere((item) => item.key == choice.key);
    if (value) _selected.add(choice);
  });

  /// 保存选择顺序，移动操作只影响本次草稿。
  void _reorder(int oldIndex, int newIndex) => setState(() {
    _selected.insert(newIndex, _selected.removeAt(oldIndex));
  });

  /// 用单一滚动区域展示模式、可排序选择与搜索结果。
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (_custom, _selected)),
          child: const Text('保存'),
        ),
      ],
    ),
    body: ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('入口')),
              ButtonSegment(value: true, label: Text('自选内容')),
            ],
            selected: {_custom},
            onSelectionChanged: (value) =>
                setState(() => _custom = value.single),
          ),
        ),
        if (_custom) ...[
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: _reorder,
            itemCount: _selected.length,
            itemBuilder: (context, index) {
              final choice = _selected[index];
              return ListTile(
                key: ValueKey(choice.key),
                title: Text(choice.label),
                leading: IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _toggle(choice, false),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索可选内容',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          for (final choice in widget.choices.where(
            (item) =>
                !_selected.any((s) => s.key == item.key) &&
                item.label.toLowerCase().contains(_query.toLowerCase()),
          ))
            ListTile(
              title: Text(choice.label),
              leading: Icon(
                choice.kind == 'creator'
                    ? Icons.person_outline
                    : choice.kind == 'remote'
                    ? Icons.cloud_outlined
                    : Icons.folder_outlined,
              ),
              trailing: const Icon(Icons.add),
              onTap: () => _toggle(choice, true),
            ),
        ],
      ],
    ),
  );
}
