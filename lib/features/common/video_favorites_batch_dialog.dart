import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
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
  });
  final List<CreatorVideo> items;
  final String ownerName;
  final AppFavoritesService local;
  final BilibiliAccountDataService account;
  final BilibiliInteractionService interactions;
  final BilibiliService details;
  @override
  State<VideoFavoritesBatchDialog> createState() =>
      _VideoFavoritesBatchDialogState();
}

class _VideoFavoritesBatchDialogState extends State<VideoFavoritesBatchDialog> {
  bool _remote = false, _loading = true, _saving = false, _stop = false;
  int _loadId = 0, _added = 0, _existing = 0;
  List<AppFavoriteFolder> _locals = [];
  List<FavoriteFolder> _remotes = [];
  String? _localId, _newName, _message;
  int? _remoteId, _mid;
  final _done = <String>{};
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
      _remoteId = null;
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
      _localId = null;
      _newName = null;
      _remoteId = null;
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
        _localId = null;
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

  void _success(int added, int existing) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已加入${_remote ? "B 站" : "本机"}收藏夹：新增 $added 支、已有 $existing 支。',
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() {
      _saving = true;
      _stop = false;
      _message = null;
    });
    try {
      if (!_remote) {
        var folderId = _localId;
        if (folderId == null && _newName != null) {
          final folder = await widget.local.createFolder(_newName!);
          if (folder == null) throw StateError('new folder failed');
          folderId = folder.id;
          if (!mounted) return;
          setState(() {
            _localId = folder.id;
            _newName = null;
            _locals = [..._locals, folder];
          });
        }
        if (folderId == null || !mounted) return;
        final now = DateTime.now();
        final items = [
          for (final (i, v) in widget.items.indexed)
            AppFavoriteItem(
              folderId: folderId,
              bvid: v.bvid,
              title: v.title,
              coverUrl: v.coverUrl,
              ownerName: widget.ownerName,
              durationText: _duration(v.duration),
              addedAt: now.subtract(Duration(microseconds: i)),
              partCount: v.partCount > 1 ? v.partCount : null,
            ),
        ];
        final n = await widget.local.addItems(folderId, items);
        if (n == null) throw StateError('folder or save unavailable');
        _success(n, items.length - n);
        return;
      }
      final mid = _mid,
          folder = _remoteId,
          revision = CacheLifecycle.account.value;
      bool valid() =>
          mounted &&
          !_stop &&
          _mid == mid &&
          CacheLifecycle.account.value == revision;
      if (mid == null || folder == null) return;
      for (final item in widget.items) {
        if (_done.contains(item.bvid)) continue;
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
        final added = await widget.interactions.addToVerifiedFavoriteFolder(
          aid: video.aid,
          mediaId: folder,
          expectedMid: mid,
          isCurrent: valid,
        );
        if (!mounted) return;
        setState(() {
          _done.add(item.bvid);
          if (added) {
            _added++;
          } else {
            _existing++;
          }
        });
      }
      if (!mounted) return;
      if (valid() && _done.length == widget.items.length) {
        _success(_added, _existing);
        return;
      }
      setState(
        () => _message =
            '已停止：新增 $_added 支、已有 $_existing 支、剩余 ${widget.items.length - _done.length} 支。',
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = _remote
              ? '未全部完成：新增 $_added 支、已有 $_existing 支、剩余 ${widget.items.length - _done.length} 支。确认账号和网络后可重试剩余项。'
              : '未能加入本机收藏，请检查收藏夹是否仍存在后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _loading || _saving;
    final hasTarget = _remote
        ? _mid != null && _remoteId != null
        : _localId != null || _newName != null;
    final choices = _remote
        ? [for (final f in _remotes) (f.mediaId.toString(), f.title)]
        : [for (final f in _locals) (f.id, f.name)];
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('选择收藏夹'),
        scrollable: true,
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('将 ${widget.items.length} 支视频加入同一个收藏夹。'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final src in [false, true])
                    ChoiceChip(
                      label: Text(src ? 'B 站' : '本机'),
                      selected: _remote == src,
                      onSelected: _saving || _done.isNotEmpty
                          ? null
                          : (_) {
                              if (src != _remote) {
                                setState(() => _remote = src);
                                unawaited(_load());
                              }
                            },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loading) const LinearProgressIndicator(),
              if (!_loading && choices.isEmpty && _message == null)
                Text(_remote ? '没有可用的 B 站收藏夹。' : '还没有本机收藏夹。'),
              if (choices.isNotEmpty)
                SizedBox(
                  width: double.maxFinite,
                  height: math.min(
                    MediaQuery.sizeOf(context).height * .28,
                    choices.length *
                        math.max(
                          56.0,
                          MediaQuery.textScalerOf(context).scale(18) + 30,
                        ),
                  ),
                  child: ListView.builder(
                    primary: false,
                    itemCount: choices.length,
                    itemBuilder: (context, i) {
                      final c = choices[i],
                          selected = _remote
                              ? _remoteId.toString() == c.$1
                              : _localId == c.$1;
                      return ListTile(
                        selected: selected,
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(c.$2),
                        onTap: _saving || _done.isNotEmpty
                            ? null
                            : () => setState(() {
                                _message = null;
                                if (_remote) {
                                  _remoteId = int.tryParse(c.$1);
                                } else {
                                  _localId = c.$1;
                                  _newName = null;
                                }
                              }),
                      );
                    },
                  ),
                ),
              if (!_remote && !_loading)
                TextButton.icon(
                  onPressed: _saving ? null : _stageNewFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: Text(_newName == null ? '新建本机收藏夹' : '新建：$_newName'),
                ),
              if (_message != null) ...[
                Text(
                  _message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (!_saving && !hasTarget && _done.isEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: _load,
                      child: const Text('重新读取'),
                    ),
                  ),
              ],
              if (_saving && _remote) ...[
                LinearProgressIndicator(
                  value: _done.length / widget.items.length,
                ),
                Text('已处理 ${_done.length} / ${widget.items.length}'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? (_remote && !_stop
                      ? () => setState(() => _stop = true)
                      : null)
                : () => Navigator.pop(context, false),
            child: Text(_saving && _remote ? '停止后续' : '取消'),
          ),
          FilledButton(
            onPressed: blocked || !hasTarget ? null : _save,
            child: Text(
              _saving
                  ? '正在加入…'
                  : _done.isNotEmpty
                  ? '继续剩余项'
                  : '加入收藏夹',
            ),
          ),
        ],
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
