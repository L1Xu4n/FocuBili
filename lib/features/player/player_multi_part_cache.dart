part of 'player_page.dart';

typedef _PartCacheOutcome = ({VideoPart part, String result});

/// Selection and quality planning for ordinary submissions only.
extension _PlayerMultiPartCache on _PlayerPageState {
  Future<void> _selectOfflineParts(VideoPreview video) async {
    final route = ModalRoute.of(context);
    bool current() =>
        mounted && _activeVideo.bvid == video.bvid && route?.isCurrent != false;

    await _downloadQueue.initialize();
    if (!current()) return;
    final cachedIds = {
      for (final download in await _offlineVideoService.loadDownloads())
        if (download.bvid == video.bvid) download.cid,
    };
    if (!current()) return;
    final tasks = {
      for (final task in _downloadQueue.tasks)
        if (task.courseMid == null && task.video.bvid == video.bvid)
          task.part.cid: task.status,
    };
    final seen = <int>{};
    final parts = [
      for (final part in video.parts)
        if (part.cid > 0 && seen.add(part.cid)) part,
    ];
    final unavailable = <int, String>{
      for (final part in parts)
        if (cachedIds.contains(part.cid))
          part.cid: '已缓存'
        else if (tasks[part.cid] case final status?)
          part.cid: switch (status) {
            DownloadTaskStatus.queued => '已在队列',
            DownloadTaskStatus.downloading => '下载中',
            DownloadTaskStatus.paused => '已暂停',
            DownloadTaskStatus.failed => '任务失败 · 可在队列处理',
            DownloadTaskStatus.completed => '已有任务 · 可在队列查看',
          },
    };
    if (!mounted) return;
    final selectedParts = await _OfflinePartPicker.show(
      context,
      videoTitle: video.title,
      wide: _appPlatform.isDesktop || MediaQuery.sizeOf(context).width >= 700,
      parts: parts,
      unavailable: unavailable,
      initialCid: _currentPart.cid,
    );
    if (selectedParts == null || selectedParts.isEmpty || !current()) return;

    // Resolve bounded groups to keep one very long playlist from flooding
    // playurl, while a slow first part doesn't serialize all lookups.
    final available = <int, Set<int>>{};
    Future<void> readQuality(VideoPart part) async {
      try {
        final choices = await _offlineVideoService.availableQualities(
          video,
          part,
        );
        available[part.cid] = {for (final option in choices) option.id};
      } catch (_) {
        available[part.cid] = const {};
      }
    }

    const parallel = 3;
    for (var start = 0; start < selectedParts.length; start += parallel) {
      if (!current()) return;
      await Future.wait(
        selectedParts.skip(start).take(parallel).map(readQuality),
      );
    }
    if (!current()) return;
    final qualityIds = {for (final ids in available.values) ...ids};
    final qualities =
        PreferredPlaybackQuality.values
            .where((quality) => qualityIds.contains(quality.id))
            .toList()
          ..sort((a, b) => b.id.compareTo(a.id));
    if (qualities.isEmpty) {
      _showPartCacheResults('未加入：${selectedParts.length} 个分P无法读取下载清晰度', [
        for (final part in selectedParts) (part: part, result: '无法读取下载清晰度，未加入'),
      ]);
      return;
    }
    if (!mounted) return;
    final requested = await showDialog<PreferredPlaybackQuality>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('下载清晰度'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('分P不支持所选档位时，改用它支持的最高较低档位。'),
          ),
          for (final quality in qualities)
            SimpleDialogOption(
              key: Key('download-quality-${quality.id}'),
              onPressed: () => Navigator.pop(context, quality),
              child: Text(quality.label),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (requested == null || !current()) return;

    var added = 0, skipped = 0, failed = 0;
    final outcomes = <_PartCacheOutcome>[];
    final fallbacks = <String>[];
    for (final part in selectedParts) {
      if (!current()) return;
      final ids = available[part.cid] ?? const <int>{};
      final effective = PreferredPlaybackQuality.values
          .where((q) => q.id <= requested.id && ids.contains(q.id))
          .fold<PreferredPlaybackQuality?>(
            null,
            (best, q) => best == null || q.id > best.id ? q : best,
          );
      if (effective == null) {
        failed++;
        outcomes.add((
          part: part,
          result: ids.isEmpty ? '无法读取下载清晰度，未加入' : '所选和更低档位均不可用，未加入',
        ));
        continue;
      }

      try {
        final task = await _downloadQueue.enqueueOrdinaryIfMissing(
          video,
          part: part,
          quality: effective.id,
        );
        if (task == null) {
          skipped++;
          outcomes.add((part: part, result: '已有任务或缓存，已跳过'));
          continue;
        }
        added++;
        // Report the quality persisted in the task, not a successful transfer.
        // If a source changes later, the downloader fails the task rather than
        // silently accepting a lower-quality file.
        final queuedQuality = PreferredPlaybackQuality.fromId(task.quality);
        if (task.quality < requested.id) {
          fallbacks.add('P${part.pageNumber} → ${queuedQuality.label}');
          outcomes.add((part: part, result: '改为 ${queuedQuality.label} 加入队列'));
        }
      } catch (_) {
        failed++;
        outcomes.add((part: part, result: '未能加入队列，可重试'));
      }
    }
    if (added > 0) {
      unawaited(DownloadNotificationService.instance.requestPermission());
    }
    if (!current()) return;
    final summary = [
      '已加入 $added 个分P',
      if (skipped > 0) '跳过 $skipped 个',
      if (failed > 0) '未加入 $failed 个',
    ].join('，');
    if (outcomes.isEmpty) {
      _showOfflineQueueNotice(summary);
    } else {
      final fallbackSummary = fallbacks.length <= 2
          ? fallbacks.join('、')
          : '${fallbacks.length} 个分P改用较低档位';
      _showPartCacheResults(
        fallbackSummary.isEmpty ? summary : '$summary；$fallbackSummary',
        outcomes,
      );
    }
  }

  void _showPartCacheResults(String summary, List<_PartCacheOutcome> results) {
    _showOfflineNotice(
      summary,
      actionLabel: '查看详情',
      duration: const Duration(seconds: 6),
      onAction: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('分P下载结果'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in results)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('P${row.part.pageNumber} · ${row.result}'),
                  ),
                const Text('加入队列不代表下载完成，请在下载队列查看进度。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  unawaited(_openDownloadQueue());
                },
                child: const Text('查看队列'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflinePartPicker extends StatefulWidget {
  const _OfflinePartPicker({
    required this.videoTitle,
    required this.parts,
    required this.unavailable,
    required this.initialCid,
  });

  final String videoTitle;
  final List<VideoPart> parts;
  final Map<int, String> unavailable;
  final int initialCid;

  static Future<List<VideoPart>?> show(
    BuildContext context, {
    required String videoTitle,
    required bool wide,
    required List<VideoPart> parts,
    required Map<int, String> unavailable,
    required int initialCid,
  }) {
    final height = (250 + parts.length * 62)
        .clamp(0, MediaQuery.sizeOf(context).height * .90)
        .toDouble();
    Widget picker() => SizedBox(
      height: height,
      child: _OfflinePartPicker(
        videoTitle: videoTitle,
        parts: parts,
        unavailable: unavailable,
        initialCid: initialCid,
      ),
    );

    if (wide) {
      return showDialog<List<VideoPart>>(
        context: context,
        builder: (_) => Dialog(
          key: const Key('offline-part-dialog'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 16,
          ),
          constraints: const BoxConstraints(maxWidth: 800),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 800, child: picker()),
        ),
      );
    }
    return showModalBottomSheet<List<VideoPart>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => picker(),
    );
  }

  @override
  State<_OfflinePartPicker> createState() => _OfflinePartPickerState();
}

class _OfflinePartPickerState extends State<_OfflinePartPicker> {
  late final Set<int> _eligible = {
    for (final part in widget.parts)
      if (!widget.unavailable.containsKey(part.cid)) part.cid,
  };

  late final Set<int> _checked = {
    if (_eligible.contains(widget.initialCid)) widget.initialCid,
  };

  void _setChecked(int first, int last, bool checked) => setState(() {
    for (var i = first; i <= last; i++) {
      final cid = widget.parts[i].cid;
      if (!_eligible.contains(cid)) continue;
      if (checked) {
        _checked.add(cid);
      } else {
        _checked.remove(cid);
      }
    }
  });

  void _replaceSelection(Iterable<int> cids) => setState(() {
    _checked
      ..clear()
      ..addAll(cids);
  });

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('选择缓存分P', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: 5),
          Text(
            '已选择 ${_checked.length} 个分 P',
            style: theme.textTheme.bodyMedium,
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: const Key('offline-part-select-current'),
                onPressed: _eligible.contains(widget.initialCid)
                    ? () => _replaceSelection([widget.initialCid])
                    : null,
                child: const Text('当前 P'),
              ),
              TextButton(
                key: const Key('offline-part-select-all'),
                onPressed: _eligible.isEmpty
                    ? null
                    : () => _replaceSelection(_eligible),
                child: const Text('全部 P'),
              ),
              TextButton(
                key: const Key('offline-part-clear-selection'),
                onPressed: _checked.isEmpty
                    ? null
                    : () => _replaceSelection(const []),
                child: const Text('清空选择'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: Text(
              widget.videoTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DragCheckboxOptions(
            itemCount: widget.parts.length,
            checkedAt: (index) => _checked.contains(widget.parts[index].cid),
            onRangeChanged: _setChecked,
            builder: (context, controller, physics) => Scrollbar(
              controller: controller,
              child: ListView.builder(
                key: const Key('offline-part-options'),
                controller: controller,
                physics: physics,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: widget.parts.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) return _header(context);
                  final part = widget.parts[index - 1];
                  final status = widget.unavailable[part.cid];
                  return DragCheckboxTile(
                    key: Key('offline-part-${part.cid}'),
                    index: index - 1,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    value: status == '已缓存' || _checked.contains(part.cid),
                    title: Text('P${part.pageNumber}  ${part.title}'),
                    subtitle: status == null
                        ? null
                        : Text(
                            status,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                    onChanged: status != null
                        ? null
                        : (checked) =>
                              _setChecked(index - 1, index - 1, checked),
                  );
                },
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
          child: OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('confirm-offline-parts'),
                onPressed: _checked.isEmpty
                    ? null
                    : () => Navigator.pop(context, [
                        for (final part in widget.parts)
                          if (_checked.contains(part.cid)) part,
                      ]),
                child: const Text('选择清晰度'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
