part of 'player_page.dart';

/// Manages local favorites and offline actions without growing the main details view.
extension _PlayerLocalLibrary on _PlayerPageState {
  /// Loads offline membership for the exact part and discards stale lookup results.
  Future<void> _loadOfflineState() async {
    final generation = ++_offlineStateGeneration;
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    try {
      final downloaded = await _offlineVideoService.isDownloaded(
        bvid,
        cid: cid,
      );
      if (mounted &&
          generation == _offlineStateGeneration &&
          _activeVideo.bvid == bvid &&
          _currentPart.cid == cid) {
        _updatePlayerState(() => _currentVideoDownloaded = downloaded);
      }
    } catch (_) {
      /* Storage errors must not prevent online playback. */
    }
  }

  /// Selects an available quality before queuing a captured part, with a timed shortcut.
  Future<void> _toggleOfflineDownload() async {
    if (_offlineDownloading) return;
    final video = _activeVideo;
    final part = _currentPart;
    _updatePlayerState(() => _offlineDownloading = true);
    try {
      final downloaded = await _offlineVideoService.isDownloaded(
        video.bvid,
        cid: part.cid,
      );
      if (!mounted) return;
      if (downloaded) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除离线缓存'),
            content: Text('删除 P${part.pageNumber} 的离线文件？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await _offlineVideoService.delete(video.bvid, cid: part.cid);
        await _downloadQueue.reconcileCompleted();
        if (mounted) _showTransientSnackBar('已删除该分 P 的离线缓存');
      } else {
        final qualities = await _offlineVideoService.availableQualities(
          video,
          part,
        );
        if (!mounted) return;
        final quality = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('下载清晰度'),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('仅显示当前视频和账号可下载的清晰度'),
              ),
              for (final quality in qualities)
                SimpleDialogOption(
                  key: Key('download-quality-${quality.id}'),
                  onPressed: () => Navigator.pop(context, quality.id),
                  child: Text(quality.label),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        if (quality == null || !mounted) return;
        final task = await _downloadQueue.enqueue(
          video,
          part: part,
          quality: quality,
        );
        unawaited(DownloadNotificationService.instance.requestPermission());
        if (mounted) {
          final message =
              task.status.name == 'queued' || task.status.name == 'downloading'
              ? '已加入下载队列'
              : '下载任务已存在';
          if (_fullscreen ||
              AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context))) {
            _playerNotices.show(
              message,
              duration: const Duration(seconds: 4),
              actionLabel: '查看队列',
              onAction: () => unawaited(_openDownloadQueue()),
            );
          } else {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 4),
                  persist: false,
                  content: Text(message),
                  action: SnackBarAction(
                    label: '查看队列',
                    onPressed: () => unawaited(_openDownloadQueue()),
                  ),
                ),
              );
          }
        }
      }
      if (mounted) await _loadOfflineState();
    } catch (error) {
      if (mounted) {
        _showTransientSnackBar(
          error is OfflineVideoException ? error.message : '离线操作失败，请重试。',
        );
      }
    } finally {
      if (mounted) _updatePlayerState(() => _offlineDownloading = false);
    }
  }

  /// Opens queue management without allowing the covered player to keep playing.
  Future<void> _openDownloadQueue() async {
    await _playbackService.pause();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => OfflineVideosPage(
          initialQueue: true,
          downloadQueue: _downloadQueue,
          offlineVideoService: _offlineVideoService,
        ),
      ),
    );
    if (!mounted) return;
    await _restorePlaybackAfterNestedPlayer(shouldResume: false);
    await _loadOfflineState();
  }

  /// 创建“离线缓存”按钮，并根据下载状态切换图标与文字。
  Widget _buildOfflineDownloadButton() {
    return PlayerLibraryAction(
      tooltip: _currentVideoDownloaded ? '删除离线缓存' : '下载离线缓存',
      key: const Key('current-video-offline-download-button'),
      busy: _offlineDownloading,
      selected: _currentVideoDownloaded,
      onPressed: _offlineDownloading
          ? null
          : () => unawaited(_toggleOfflineDownload()),
      icon: _currentVideoDownloaded
          ? Icons.offline_pin_rounded
          : Icons.download_for_offline_outlined,
      label: _offlineDownloading
          ? '加入中…'
          : _currentVideoDownloaded
          ? '已缓存'
          : '离线缓存',
    );
  }

  /// 读取当前视频在软件收藏夹中的收藏状态，失败时保持未收藏显示。
  Future<void> _loadAppFavoriteState() async {
    final String bvid = _activeVideo.bvid;
    if (bvid.isEmpty) {
      return;
    }
    if (mounted) {
      _updatePlayerState(() => _appFavoriteLoading = true);
    }
    try {
      final List<AppFavoriteFolder> folders = await _appFavoritesService
          .loadFolders();
      final Set<String> containing = <String>{};
      for (final AppFavoriteFolder folder in folders) {
        final List<AppFavoriteItem> items = await _appFavoritesService
            .loadItems(folder.id);
        if (items.any((AppFavoriteItem item) => item.bvid == bvid)) {
          containing.add(folder.id);
        }
      }
      if (mounted && _activeVideo.bvid == bvid) {
        _updatePlayerState(() {
          _appFavoriteFolderIds = containing;
        });
      }
    } on Object {
      // 本机收藏读取失败时保持未收藏显示，不影响播放器其他功能。
    } finally {
      if (mounted) {
        _updatePlayerState(() => _appFavoriteLoading = false);
      }
    }
  }

  /// 显示可多选的软件收藏夹面板，并保留当前已包含视频的预选状态。
  Future<_AppFavoriteFolderSelection?> _showAppFavoriteFolderSheet(
    List<AppFavoriteFolder> folders, {
    required Set<String> selectedIds,
  }) {
    final Set<String> selected = Set<String>.of(selectedIds);
    return showModalBottomSheet<_AppFavoriteFolderSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.76,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '收藏到软件收藏夹',
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key(
                            'create-app-favorite-folder-from-player',
                          ),
                          onPressed: () => Navigator.of(sheetContext).pop(
                            _AppFavoriteFolderSelection(
                              selectedIds: selected,
                              createNewFolder: true,
                            ),
                          ),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('新建收藏夹'),
                        ),
                      ],
                    ),
                  ),
                  if (folders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Text('当前还没有软件收藏夹，可以先创建一个。'),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        itemCount: folders.length,
                        itemBuilder: (BuildContext context, int index) {
                          final AppFavoriteFolder folder = folders[index];
                          final bool checked = selected.contains(folder.id);
                          return CheckboxListTile(
                            key: Key('app-favorite-folder-${folder.id}'),
                            value: checked,
                            controlAffinity: ListTileControlAffinity.trailing,
                            title: Text(folder.name),
                            onChanged: (bool? value) {
                              setSheetState(() {
                                if (value ?? false) {
                                  selected.add(folder.id);
                                } else {
                                  selected.remove(folder.id);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const Key('confirm-app-favorite-folders'),
                          onPressed: () => Navigator.of(sheetContext).pop(
                            _AppFavoriteFolderSelection(selectedIds: selected),
                          ),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 请求输入新软件收藏夹名称，空名称时禁用创建按钮。
  Future<String?> _showCreateAppFavoriteFolderDialog() {
    String title = '';
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          return AlertDialog(
            title: const Text('创建软件收藏夹'),
            content: TextField(
              key: const Key('app-favorite-folder-name-input'),
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(hintText: '输入收藏夹名称'),
              onChanged: (String value) {
                setDialogState(() => title = value.trim());
              },
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('confirm-create-app-favorite-folder'),
                onPressed: title.isEmpty
                    ? null
                    : () => Navigator.of(dialogContext).pop(title),
                child: const Text('创建'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Saves membership for a captured BV and only reflects successful writes.
  Future<void> _toggleAppFavorite() async {
    if (_appFavoriteBusy || _activeVideo.bvid.isEmpty) return;
    final video = _activeVideo;
    final durationText = _formatDurationText(_displayDuration);
    _updatePlayerState(() => _appFavoriteBusy = true);
    try {
      final folders = await _appFavoritesService.loadFolders();
      final initial = <String>{};
      for (final folder in folders) {
        if ((await _appFavoritesService.loadItems(
          folder.id,
        )).any((e) => e.bvid == video.bvid)) {
          initial.add(folder.id);
        }
      }
      if (!mounted || _activeVideo.bvid != video.bvid) return;
      final selection = await _showAppFavoriteFolderSheet(
        folders,
        selectedIds: initial,
      );
      if (!mounted || selection == null) return;
      final selected = selection.selectedIds.toSet();
      if (selection.createNewFolder) {
        final name = await _showCreateAppFavoriteFolderDialog();
        if (!mounted || name == null) return;
        final folder = await _appFavoritesService.createFolder(name);
        if (folder == null) throw StateError('Folder was not saved');
        selected.add(folder.id);
      }
      bool failed = false;
      for (final id in selected.difference(initial)) {
        if (!await _appFavoritesService.addItem(
          AppFavoriteItem(
            folderId: id,
            bvid: video.bvid,
            title: video.title,
            coverUrl: video.thumbnailUrl,
            ownerName: video.ownerName,
            durationText: durationText,
            addedAt: DateTime.now(),
            partCount: video.parts.length,
          ),
        )) {
          failed = true;
        }
      }
      for (final id in initial.difference(selected)) {
        if (!await _appFavoritesService.removeItem(id, video.bvid)) {
          failed = true;
        }
      }
      if (mounted) {
        await _loadAppFavoriteState();
        if (mounted) {
          _showTransientSnackBar(failed ? '部分收藏操作失败，请检查后重试。' : '软件收藏夹已更新');
        }
      }
    } catch (_) {
      if (mounted) {
        await _loadAppFavoriteState();
        if (mounted) _showTransientSnackBar('软件收藏夹操作失败，原数据已保留。');
      }
    } finally {
      if (mounted) _updatePlayerState(() => _appFavoriteBusy = false);
    }
  }

  /// 把时长格式化为小时分钟秒文本，未知时长返回空字符串。
  String _formatDurationText(Duration duration) {
    if (duration <= Duration.zero) {
      return '';
    }
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes % 60;
    final int seconds = duration.inSeconds % 60;
    final String minuteText = minutes.toString().padLeft(2, '0');
    final String secondText = seconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minutes:$secondText';
  }

  /// 创建“收藏到软件收藏夹”按钮，并根据已收藏状态切换图标与文字。
  Widget _buildAppFavoriteButton() {
    final bool busy = _appFavoriteLoading || _appFavoriteBusy;
    final bool favorited = _appFavoriteFolderIds.isNotEmpty;
    return PlayerLibraryAction(
      tooltip: favorited ? '已加入软件收藏夹' : '收藏到软件收藏夹',
      key: const Key('current-video-app-favorite-button'),
      busy: busy,
      selected: favorited,
      onPressed: busy ? null : () => unawaited(_toggleAppFavorite()),
      icon: favorited ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
      label: favorited ? '已收藏' : '软件收藏',
    );
  }
}
