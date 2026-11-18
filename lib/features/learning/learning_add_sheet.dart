import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/widgets/drag_checkbox_list.dart';
import '../../models/video_preview.dart';
import '../../models/learning_subject_folder.dart';
import '../../models/public_profile.dart';
import '../../services/bilibili_service.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/learning_list_service.dart';

/// Shared explicit selection and capacity preview for every learning entry point.
abstract final class LearningAddSheet {
  static Future<LearningBatchResult?> show(
    BuildContext context, {
    required VideoPreview video,
    required LearningListService service,
    bool Function()? canConfirm,
    VideoPart? currentPart,
    VideoPart? recentPart,
    Duration position = Duration.zero,
  }) => _showParts(
    context,
    [video],
    service,
    canConfirm: canConfirm,
    currentPart: currentPart,
    recentPart: recentPart,
    position: position,
  );

  static Future<LearningBatchResult?> showCollection(
    BuildContext context, {
    required int ownerMid,
    required int collectionId,
    required BilibiliPublicContentService contentService,
    required BilibiliService videoService,
    required LearningListService service,
  }) async {
    final selected = await showModalBottomSheet<List<CreatorVideo>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CollectionSelection(
        ownerMid: ownerMid,
        collectionId: collectionId,
        service: contentService,
      ),
    );
    if (selected == null || !context.mounted) return null;
    return showSelectedVideos(
      context,
      items: selected,
      videoService: videoService,
      service: service,
    );
  }

  /// 从已经勾选的独立视频开始：仍由用户决定分 P、学科分组与容量，不重选视频。
  static Future<LearningBatchResult?> showSelectedVideos(
    BuildContext context, {
    required List<CreatorVideo> items,
    bool Function()? canConfirm,
    required BilibiliService videoService,
    required LearningListService service,
  }) async {
    final seen = <String>{};
    final selected = items
        .where((e) => e.bvid.isNotEmpty && seen.add(e.bvid))
        .toList(growable: false);
    if (selected.isEmpty || canConfirm?.call() == false) return null;
    final details = await showDialog<_LoadedCollection>(
      context: context,
      builder: (_) =>
          _CollectionDetailLoader(items: selected, service: videoService),
    );
    if (details == null || !context.mounted || canConfirm?.call() == false) {
      return null;
    }
    final videos = details.videos, failed = details.failed;
    if (failed.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('部分视频详情读取失败'),
          content: Text(
            '${failed.length} 支失败：${failed.join('、')}\n可继续选择已读取的 ${videos.length} 支视频，失败项不会加入。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: videos.isEmpty
                  ? null
                  : () => Navigator.pop(dialog, true),
              child: const Text('继续选择成功项'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return null;
    }
    if (videos.isEmpty) return null;
    return _showParts(context, videos, service, canConfirm: canConfirm);
  }

  static Future<LearningBatchResult?> _showParts(
    BuildContext context,
    List<VideoPreview> videos,
    LearningListService service, {
    bool Function()? canConfirm,
    VideoPart? currentPart,
    VideoPart? recentPart,
    Duration position = Duration.zero,
  }) async {
    final state = await service.loadState();
    if (!context.mounted || canConfirm?.call() == false) return null;
    if (service.readFailed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('学习清单读取失败，原数据保留。请重试。')));
      return null;
    }
    final entries = state.entries;
    return showModalBottomSheet<LearningBatchResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // This form can still be canceled explicitly or with Back; a swipe
      // must not dismiss it while the confirmed write is committing.
      enableDrag: false,
      isDismissible: false,
      builder: (_) => _PartSelection(
        videos: videos,
        canConfirm: canConfirm,
        service: service,
        existingIds: entries.map((e) => e.stableId).toSet(),
        count: entries.length,
        folders: state.folders,
        currentPart: currentPart,
        recentPart: recentPart,
        position: position,
      ),
    );
  }
}

class _LoadedCollection {
  const _LoadedCollection(this.videos, this.failed);
  final List<VideoPreview> videos;
  final List<String> failed;
}

class _CollectionDetailLoader extends StatefulWidget {
  const _CollectionDetailLoader({required this.items, required this.service});
  final List<CreatorVideo> items;
  final BilibiliService service;
  @override
  State<_CollectionDetailLoader> createState() =>
      _CollectionDetailLoaderState();
}

class _CollectionDetailLoaderState extends State<_CollectionDetailLoader> {
  int _finished = 0;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    _route = ModalRoute.of(context);
    unawaited(_load());
  }

  // A popped route stays mounted during its exit animation. Do not issue
  // another request or pop the route below it if a reply arrives meanwhile.
  bool get _isOpen => mounted && _route?.isCurrent == true;

  Future<void> _load() async {
    final videos = <VideoPreview>[], failed = <String>[];
    // Canceling the dialog stops new requests and discards the current result.
    for (final item in widget.items) {
      if (!_isOpen) return;
      try {
        final video = await widget.service
            .lookupVideo(item.bvid)
            .timeout(const Duration(seconds: 30));
        if (!_isOpen) return;
        videos.add(video);
      } catch (_) {
        if (!_isOpen) return;
        failed.add(item.title);
      }
      setState(() => _finished++);
    }
    if (mounted && _route?.isCurrent == true) {
      Navigator.pop(context, _LoadedCollection(videos, failed));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('读取所选视频分 P'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(value: _finished / widget.items.length),
        const SizedBox(height: 12),
        Text('已读取 $_finished / ${widget.items.length}，此时尚未加入学习清单。'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

class _LearningPartChoice {
  const _LearningPartChoice(this.video, this.part, {required this.startsGroup});

  final VideoPreview video;
  final VideoPart part;
  final bool startsGroup;

  static String idFor(VideoPreview video, VideoPart part) =>
      '${video.bvid.trim()}:${part.cid}';

  String get id => idFor(video, part);
}

class _PartSelection extends StatefulWidget {
  const _PartSelection({
    required this.videos,
    this.canConfirm,
    required this.service,
    required this.existingIds,
    required this.count,
    required this.folders,
    this.currentPart,
    this.recentPart,
    required this.position,
  });
  final List<VideoPreview> videos;
  final bool Function()? canConfirm;
  final LearningListService service;
  final Set<String> existingIds;
  final int count;
  final List<LearningSubjectFolder> folders;
  final VideoPart? currentPart;
  final VideoPart? recentPart;
  final Duration position;
  @override
  State<_PartSelection> createState() => _PartSelectionState();
}

class _PartSelectionState extends State<_PartSelection> {
  final Set<String> _selected = {};
  final ScrollController _options = ScrollController();
  late final List<_LearningPartChoice> _parts;
  bool _saving = false;
  String? _folderId;
  String? _error;
  @override
  void initState() {
    super.initState();
    _parts = [
      for (final video in widget.videos)
        for (var i = 0; i < video.parts.length; i++)
          _LearningPartChoice(video, video.parts[i], startsGroup: i == 0),
    ];
    _resetDefaults();
  }

  VideoPart? get _referencePart => widget.currentPart ?? widget.recentPart;

  void _resetDefaults() {
    _selected
      ..clear()
      ..addAll(
        _parts
            .where((option) => widget.existingIds.contains(option.id))
            .map((option) => option.id),
      );
    for (final video in widget.videos) {
      final reference = _referencePart ?? video.initialPart;
      _selected.add(_LearningPartChoice.idFor(video, reference));
    }
  }

  void _setSelectionRange(int first, int last, bool selected) {
    if (_saving) return;
    setState(() {
      for (var i = first; i <= last; i++) {
        final id = _parts[i].id;
        if (selected) {
          _selected.add(id);
        } else {
          _selected.remove(id);
        }
      }
    });
  }

  @override
  void dispose() {
    _options.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (widget.canConfirm?.call() == false) {
      setState(() => _error = '来源列表的规则或状态已变化，暂未加入学习清单。');
      if (_options.hasClients) _options.jumpTo(0);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.service.addBatch([
      for (final option in _parts)
        if (_selected.contains(option.id))
          LearningPartSelection(
            option.video,
            option.part,
            position: _referencePart?.cid == option.part.cid
                ? widget.position
                : Duration.zero,
          ),
    ], folderId: _folderId);
    if (!mounted) return;
    if (!result.persisted ||
        result.capacityExceeded ||
        result.failedItems.isNotEmpty) {
      setState(() {
        _saving = false;
        _error = !result.persisted
            ? '未保存，请检查设备存储后重试。'
            : result.capacityExceeded
            ? '容量已变化或选择超限，请先减少选择；原任务均已保留。'
            : '部分分 P 已失效，未加入任务。请重新读取详情。';
      });
      if (_options.hasClients) _options.jumpTo(0);
      return;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final duplicate = _selected.intersection(widget.existingIds).length;
    final added = _selected.length - duplicate;
    final remaining = LearningListService.maximumEntries - widget.count;
    return PopScope(
      canPop: !_saving,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Column(
          children: [
            Expanded(
              child: DragCheckboxList(
                scrollViewKey: const Key('learning-part-options'),
                controller: _options,
                itemCount: _parts.length,
                labelAt: (index) {
                  final part = _parts[index].part;
                  return 'P${part.pageNumber} ${part.title}';
                },
                checkedAt: (index) => _selected.contains(_parts[index].id),
                groupTitleAt: (index) {
                  final option = _parts[index];
                  return option.startsGroup ? option.video.title : null;
                },
                enabled: !_saving,
                onRangeChanged: _setSelectionRange,
                header: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '加入学习清单',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text('剩余容量 $remaining'),
                          if (widget.folders.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              key: const Key('add-learning-folder'),
                              initialValue: '',
                              isExpanded: true,
                              isDense: false,
                              itemHeight: null,
                              decoration: const InputDecoration(
                                labelText: '新增任务的学科分组',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('未分组'),
                                ),
                                for (final folder in widget.folders)
                                  DropdownMenuItem(
                                    value: folder.id,
                                    child: Text(
                                      folder.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(
                                      () => _folderId = value == ''
                                          ? null
                                          : value,
                                    ),
                            ),
                          ],
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(_resetDefaults),
                                child: Text(
                                  widget.currentPart != null
                                      ? '当前 P'
                                      : widget.recentPart != null
                                      ? '上次观看的 P'
                                      : '默认 P',
                                ),
                              ),
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() {
                                        _selected.clear();
                                        _selected.addAll(
                                          _parts.map((option) => option.id),
                                        );
                                      }),
                                child: const Text('全部 P'),
                              ),
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(_selected.clear),
                                child: const Text('清空选择'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _saving || _selected.isEmpty || added > remaining
                        ? null
                        : _save,
                    child: Text(
                      _saving
                          ? '正在保存…'
                          : added > remaining
                          ? '超过100条上限'
                          : '确认加入',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionSelection extends StatefulWidget {
  const _CollectionSelection({
    required this.ownerMid,
    required this.collectionId,
    required this.service,
  });
  final int ownerMid, collectionId;
  final BilibiliPublicContentService service;
  @override
  State<_CollectionSelection> createState() => _CollectionSelectionState();
}

class _CollectionSelectionState extends State<_CollectionSelection> {
  final List<CreatorVideo> _videos = [];
  final Set<String> _selected = {};
  int _page = 1;
  bool _hasMore = true, _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.service
          .loadCollectionVideos(
            widget.ownerMid,
            widget.collectionId,
            page: _page,
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        final seen = _videos.map((e) => e.bvid).toSet();
        _videos.addAll(page.items.where((e) => seen.add(e.bvid)));
        _page++;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取失败，请重试；未读取的页面不会被选中。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .85,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Expanded(child: Text('合集：先选择视频，再选择各视频的 P')),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭合集选择',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final video in _videos)
                CheckboxListTile(
                  value: _selected.contains(video.bvid),
                  title: Text(video.title),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(video.bvid);
                    } else {
                      _selected.remove(video.bvid);
                    }
                  }),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!),
                ),
              if (_hasMore)
                TextButton(
                  onPressed: _loading ? null : _load,
                  child: Text(_loading ? '读取中…' : '加载下一页'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _selected.addAll(_videos.map((e) => e.bvid));
                }),
                child: const Text('选择已加载视频'),
              ),
              FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.pop(
                        context,
                        _videos
                            .where((e) => _selected.contains(e.bvid))
                            .toList(),
                      ),
                child: Text('下一步（${_selected.length} 支）'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
