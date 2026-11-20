import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/widgets/drag_checkbox_options.dart';
import '../../models/app_favorite.dart';
import '../../models/public_profile.dart';
import '../../models/account_collection.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_interaction_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/cache_lifecycle.dart';

/// 本机和 B 站是不同的存储目标。先选夹，明确按“加入”才开始写。
class VideoFavoritesBatchDialog extends StatefulWidget {
  const VideoFavoritesBatchDialog({
    super.key,
    required this.items,
    required this.ownerName,
    required this.local,
    required this.account,
    required this.interactions,
    required this.details,
    this.sourceIsCurrent,
  });
  final List<CreatorVideo> items;
  final String ownerName;
  final AppFavoritesService local;
  final BilibiliAccountDataService account;
  final BilibiliInteractionService interactions;
  final BilibiliService details;
  final bool Function()? sourceIsCurrent;
  @override
  State<VideoFavoritesBatchDialog> createState() =>
      _VideoFavoritesBatchDialogState();
}

class _VideoFavoritesBatchDialogState extends State<VideoFavoritesBatchDialog> {
  bool _remote = false, _loading = true, _saving = false, _stop = false;
  int _loadId = 0, _added = 0, _existing = 0;
  List<AppFavoriteFolder> _locals = [];
  List<FavoriteFolder> _remotes = [];
  String? _newName, _message;
  int? _mid;
  final _localIds = <String>{};
  final _remoteIds = <int>{};
  final _localDone = <String>{};
  final _remoteDone = <(String, int)>{};

  int get _doneCount =>
      _remote ? _remoteDone.length : _localDone.length * widget.items.length;
  int get _targetCount => _remote
      ? _remoteIds.length
      : _localIds.length + (_newName == null ? 0 : 1);
  int get _totalCount => _targetCount * widget.items.length;
  @override
  void initState() {
    super.initState();
    CacheLifecycle.account.addListener(_accountChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _loadId++;
    CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }

  void _accountChanged() {
    if (!mounted || !_remote) return;
    _loadId++;
    setState(() {
      _stop = true;
      _mid = null;
      _remotes = [];
      _loading = false;
      _message = '账号已变化。请退出并重新选择收藏夹。';
    });
  }

  Future<void> _load() async {
    final id = ++_loadId;
    setState(() {
      _loading = true;
      _message = null;
      _localIds.clear();
      _newName = null;
      _remoteIds.clear();
      _mid = null;
      _remotes = [];
    });
    try {
      if (!_remote) {
        final folders = await widget.local.loadFolders();
        if (mounted && id == _loadId) setState(() => _locals = folders);
        return;
      }
      final rev = CacheLifecycle.account.value;
      final mid = await widget.account.currentAccountMid();
      if (!mounted || id != _loadId) return;
      if (mid == null || mid <= 0) {
        setState(() => _message = '请先登录 B 站；也可以收藏到本机。');
        return;
      }
      final page = await widget.account.loadFavoriteFolders();
      final active = await widget.account.currentAccountMid();
      if (!mounted || id != _loadId) return;
      if (mid != active || rev != CacheLifecycle.account.value) {
        _accountChanged();
        return;
      }
      if (!page.isSuccess) {
        setState(() => _message = page.message ?? 'B 站收藏夹读取失败。');
        return;
      }
      setState(() {
        _mid = mid;
        _remotes = page.items
            .where((e) => e.isAvailable)
            .toList(growable: false);
      });
    } catch (_) {
      if (mounted && id == _loadId) setState(() => _message = '收藏夹读取失败，请重试。');
    } finally {
      if (mounted && id == _loadId) setState(() => _loading = false);
    }
  }

  Future<void> _stageNewFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewName(),
    );
    if (name != null && mounted) {
      setState(() {
        _newName = name;
        _message = null;
      });
    }
  }

  String _duration(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0'),
        m = d.inMinutes % 60;
    return d.inHours == 0
        ? '$m:$s'
        : '${d.inHours}:${m.toString().padLeft(2, "0")}:$s';
  }

  String _counts(int added, int existing) {
    final unit = _targetCount == 1 ? '支' : '项';
    return '新增 $added $unit、已有 $existing $unit';
  }

  void _success() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已加入 $_targetCount 个${_remote ? "B 站" : "本机"}收藏夹：'
          '${_counts(_added, _existing)}。',
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  bool _sourceCurrent() => mounted && widget.sourceIsCurrent?.call() != false;

  void _unfinished(String heading, int total) {
    final unit = _targetCount == 1 ? '支' : '项';
    setState(
      () => _message =
          '$heading：${_counts(_added, _existing)}、剩余 ${total - _doneCount} $unit。',
    );
  }

  Future<void> _save() async {
    if (_saving || _loading || _totalCount == 0) return;
    if (!_sourceCurrent()) {
      setState(() => _message = '来源或筛选已变化，请取消并重新选择。');
      return;
    }
    final total = _totalCount;
    setState(() {
      _saving = true;
      _stop = false;
      _message = null;
    });
    try {
      if (!_remote) {
        if (_newName case final String name) {
          final folder = await widget.local.createFolder(name);
          if (folder == null) throw StateError('new folder failed');
          if (!mounted) return;
          setState(() {
            _localIds.add(folder.id);
            _newName = null;
            _locals = [..._locals, folder];
          });
        }
        final now = DateTime.now();
        for (final id in _localIds) {
          if (_localDone.contains(id)) continue;
          if (!_sourceCurrent() || _stop) break;
          final items = [
            for (final (i, v) in widget.items.indexed)
              AppFavoriteItem(
                folderId: id,
                bvid: v.bvid,
                title: v.title,
                coverUrl: v.coverUrl,
                ownerName: v.ownerName.trim().isEmpty
                    ? widget.ownerName
                    : v.ownerName,
                durationText: _duration(v.duration),
                addedAt: now.subtract(Duration(microseconds: i)),
                partCount: v.partCount > 1 ? v.partCount : null,
              ),
          ];
          final count = await widget.local.addItems(id, items);
          if (count == null) throw StateError('folder or save unavailable');
          if (!mounted) return;
          setState(() {
            _localDone.add(id);
            _added += count;
            _existing += items.length - count;
          });
        }
        if (!mounted) return;
        if (_doneCount == total) {
          _success();
        } else {
          _unfinished('已停止', total);
        }
        return;
      }

      final mid = _mid;
      final revision = CacheLifecycle.account.value;
      bool valid() =>
          _sourceCurrent() &&
          !_stop &&
          _mid == mid &&
          CacheLifecycle.account.value == revision;
      if (mid == null) return;
      final folders = _remoteIds.toList(growable: false);
      videos:
      for (final item in widget.items) {
        final remaining = folders.where(
          (folder) => !_remoteDone.contains((item.bvid, folder)),
        );
        if (remaining.isEmpty) continue;
        if (!valid()) break;
        if (await widget.account.currentAccountMid() != mid) {
          if (mounted) _accountChanged();
          break;
        }
        if (!valid()) break;
        final video = await widget.details
            .lookupVideo(item.bvid)
            .timeout(const Duration(seconds: 30));
        if (!valid()) break;
        if (video.aid <= 0 ||
            video.bvid.toLowerCase() != item.bvid.toLowerCase()) {
          throw StateError('mismatched or unavailable video');
        }
        for (final folder in remaining) {
          if (!valid()) break videos;
          final added = await widget.interactions.addToVerifiedFavoriteFolder(
            aid: video.aid,
            mediaId: folder,
            expectedMid: mid,
            isCurrent: valid,
          );
          if (!mounted) return;
          setState(() {
            _remoteDone.add((item.bvid, folder));
            if (added) {
              _added++;
            } else {
              _existing++;
            }
          });
        }
      }
      if (!mounted) return;
      if (valid() && _doneCount == total) {
        _success();
      } else {
        _unfinished('已停止', total);
      }
    } catch (_) {
      if (mounted) _unfinished(_stop ? '已停止' : '未全部完成', total);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectionLocked = _saving || _doneCount > 0;
    final hasTarget = _targetCount > 0 && (!_remote || _mid != null);
    final isRemote = _remote;
    final choices = isRemote
        ? [for (final f in _remotes) (f.mediaId.toString(), f.title)]
        : [for (final f in _locals) (f.id, f.name)];
    final showDraft = !_remote && _newName != null;
    final loadId = _loadId;
    final selectable = !_loading && !selectionLocked;

    bool checkedAt(int index) {
      final id = choices[index].$1;
      return isRemote
          ? _remoteIds.contains(int.parse(id))
          : _localIds.contains(id);
    }

    void setChecked(int first, int last, bool checked) {
      if (_loading || _saving || _doneCount > 0 || loadId != _loadId) return;
      setState(() {
        _message = null;
        for (var index = first; index <= last; index++) {
          final id = choices[index].$1;
          if (isRemote) {
            final folder = int.parse(id);
            checked ? _remoteIds.add(folder) : _remoteIds.remove(folder);
          } else {
            checked ? _localIds.add(id) : _localIds.remove(id);
          }
        }
      });
    }

    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('选择收藏夹'),
        titlePadding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        actionsPadding: const EdgeInsetsDirectional.fromSTEB(20, 10, 20, 14),
        scrollable: true,
        content: SizedBox(
          width: 350,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final src in [false, true])
                    ChoiceChip(
                      avatar: Icon(
                        src ? Icons.cloud_outlined : Icons.folder_outlined,
                        size: 16,
                      ),
                      showCheckmark: false,
                      side: BorderSide.none,
                      backgroundColor: colors.surfaceContainerHigh,
                      selectedColor: colors.primaryContainer,
                      label: Text(src ? 'B 站' : '本机'),
                      selected: _remote == src,
                      onSelected: selectionLocked
                          ? null
                          : (selected) {
                              if (selected && src != _remote) {
                                setState(() => _remote = src);
                                unawaited(_load());
                              }
                            },
                    ),
                  Text(
                    '${widget.items.length} 支视频 · 已选 $_targetCount 个',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_loading) const LinearProgressIndicator(),
              if (!_loading &&
                  choices.isEmpty &&
                  !showDraft &&
                  _message == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_remote ? '没有可用收藏夹' : '还没有本机收藏夹'),
                ),
              if (choices.isNotEmpty || showDraft)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (MediaQuery.sizeOf(context).height * .58).clamp(
                      76.0,
                      520.0,
                    ),
                  ),
                  child: DragCheckboxOptions(
                    key: ValueKey(loadId),
                    itemCount: choices.length,
                    checkedAt: checkedAt,
                    onRangeChanged: setChecked,
                    enabled: selectable,
                    builder: (context, controller, physics) =>
                        SingleChildScrollView(
                          key: const Key('batch-favorite-folder-list'),
                          controller: controller,
                          physics: physics,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final (index, (_, title)) in choices.indexed)
                                _folderOption(
                                  context,
                                  index: index,
                                  title: title,
                                  selected: checkedAt(index),
                                  onChanged: !selectable
                                      ? null
                                      : (checked) =>
                                            setChecked(index, index, checked),
                                ),
                              if (showDraft)
                                _folderOption(
                                  context,
                                  title: '新建：$_newName',
                                  selected: true,
                                  onChanged: selectionLocked
                                      ? null
                                      : (_) => setState(() => _newName = null),
                                ),
                            ],
                          ),
                        ),
                  ),
                ),
              if (!_remote && !_loading)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: selectionLocked ? null : _stageNewFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('新建本机收藏夹'),
                  ),
                ),
              if (_message case final message?) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(message, style: TextStyle(color: colors.error)),
                ),
                if (!selectionLocked && !hasTarget)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: _load,
                      child: const Text('重新读取'),
                    ),
                  ),
              ],
              if (_saving && _totalCount > 0) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _doneCount / _totalCount),
                Text('已处理 $_doneCount / $_totalCount'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? (_stop ? null : () => setState(() => _stop = true))
                : () => Navigator.pop(context, false),
            child: Text(_saving ? '停止后续' : '取消'),
          ),
          FilledButton(
            onPressed: _loading || _saving || !hasTarget ? null : _save,
            child: Text(
              _saving
                  ? '正在加入…'
                  : _doneCount > 0
                  ? '继续剩余项'
                  : '加入收藏夹',
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderOption(
    BuildContext context, {
    required String title,
    required bool selected,
    required ValueChanged<bool>? onChanged,
    int? index,
  }) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: DragCheckboxTile(
          index: index,
          shape: shape,
          dense: true,
          contentPadding: const EdgeInsetsDirectional.only(start: 10, end: 6),
          value: selected,
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          leading: Icon(
            _remote ? Icons.cloud_outlined : Icons.folder_outlined,
            size: 18,
            color: selected
                ? colors.onPrimaryContainer
                : colors.onSurfaceVariant,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _NewName extends StatefulWidget {
  const _NewName();
  @override
  State<_NewName> createState() => _NewNameState();
}

class _NewNameState extends State<_NewName> {
  String _name = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('新建本机收藏夹'),
    content: TextField(
      autofocus: true,
      decoration: const InputDecoration(labelText: '名称'),
      onChanged: (s) => setState(() => _name = s.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.isEmpty ? null : () => Navigator.pop(context, _name),
        child: const Text('使用此名称'),
      ),
    ],
  );
}
