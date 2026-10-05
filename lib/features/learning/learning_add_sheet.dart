import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/video_preview.dart';
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
    VideoPart? currentPart,
    Duration position = Duration.zero,
  }) => _showParts(
    context,
    [video],
    service,
    currentPart: currentPart,
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
    if (selected == null || selected.isEmpty || !context.mounted) return null;
    final details = await showDialog<_LoadedCollection>(
      context: context,
      builder: (_) =>
          _CollectionDetailLoader(items: selected, service: videoService),
    );
    if (details == null || !context.mounted) return null;
    final videos = details.videos, failed = details.failed;
    if (failed.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('部分视频详情读取失败'),
          content: SingleChildScrollView(
            child: Text(
              '${failed.length} 支失败：${failed.join('、')}\n可继续选择已读取的 ${videos.length} 支视频，失败项不会加入。',
            ),
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
    return _showParts(context, videos, service);
  }

  static Future<LearningBatchResult?> _showParts(
    BuildContext context,
    List<VideoPreview> videos,
    LearningListService service, {
    VideoPart? currentPart,
    Duration position = Duration.zero,
  }) async {
    final entries = await service.loadEntries();
    if (!context.mounted) return null;
    return showModalBottomSheet<LearningBatchResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PartSelection(
        videos: videos,
        service: service,
        existingIds: entries.map((e) => e.stableId).toSet(),
        count: entries.length,
        currentPart: currentPart,
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
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final videos = <VideoPreview>[], failed = <String>[];
    // Canceling the dialog stops new requests and discards the current result.
    for (final item in widget.items) {
      if (!mounted) return;
      try {
        final video = await widget.service
            .lookupVideo(item.bvid)
            .timeout(const Duration(seconds: 30));
        if (!mounted) return;
        videos.add(video);
      } catch (_) {
        if (!mounted) return;
        failed.add(item.title);
      }
      setState(() => _finished++);
    }
    if (mounted) Navigator.pop(context, _LoadedCollection(videos, failed));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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

class _PartSelection extends StatefulWidget {
  const _PartSelection({
    required this.videos,
    required this.service,
    required this.existingIds,
    required this.count,
    this.currentPart,
    required this.position,
  });
  final List<VideoPreview> videos;
  final LearningListService service;
  final Set<String> existingIds;
  final int count;
  final VideoPart? currentPart;
  final Duration position;
  @override
  State<_PartSelection> createState() => _PartSelectionState();
}

class _PartSelectionState extends State<_PartSelection> {
  final Set<String> _selected = {};
  bool _saving = false;
  String? _error;
  String _id(VideoPreview video, VideoPart part) => '${video.bvid}:${part.cid}';
  @override
  void initState() {
    super.initState();
    for (final video in widget.videos) {
      _selected.add(_id(video, widget.currentPart ?? video.initialPart));
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.service.addBatch([
      for (final video in widget.videos)
        for (final part in video.parts)
          if (_selected.contains(_id(video, part)))
            LearningPartSelection(
              video,
              part,
              position: widget.currentPart?.cid == part.cid
                  ? widget.position
                  : Duration.zero,
            ),
    ]);
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
            : '部分分 P 已失效，请重新读取详情。';
      });
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
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('加入学习清单', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '新增 $added · 已存在 $duplicate · 剩余容量 $remaining\n已存在任务保留进度、状态和顺序。',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _selected.clear();
                                for (final video in widget.videos) {
                                  _selected.add(
                                    _id(
                                      video,
                                      widget.currentPart ?? video.initialPart,
                                    ),
                                  );
                                }
                              }),
                        child: Text(
                          widget.currentPart == null ? '默认 P' : '当前 P',
                        ),
                      ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _selected.clear();
                                for (final video in widget.videos) {
                                  for (final part in video.parts) {
                                    _selected.add(_id(video, part));
                                  }
                                }
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
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final video in widget.videos) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        video.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    for (final part in video.parts)
                      CheckboxListTile(
                        value: _selected.contains(_id(video, part)),
                        title: Text('P${part.pageNumber} ${part.title}'),
                        subtitle: widget.existingIds.contains(_id(video, part))
                            ? const Text('已存在 · 保留学习进度')
                            : null,
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(_id(video, part));
                                } else {
                                  _selected.remove(_id(video, part));
                                }
                              }),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
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
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('合集：先选择视频，再选择各视频的 P'),
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
