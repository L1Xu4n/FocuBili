import 'dart:async';
import 'package:flutter/material.dart';

import '../../models/video_preview.dart';
import '../../platform/app_platform.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/course_cache_library.dart';
import 'course_cache_playback_page.dart';

/// Private cache is deliberately separate from normal video's disk index and export.
class CourseCachePage extends StatefulWidget {
  const CourseCachePage({
    super.key,
    this.video,
    this.part,
    this.quality = 64,
    this.library,
  });
  final VideoPreview? video;
  final VideoPart? part;
  final int quality;
  final CourseCacheLibrary? library;
  static bool supported(AppPlatform p) =>
      p == AppPlatform.android || p == AppPlatform.windows;
  @override
  State<CourseCachePage> createState() => _CourseCachePageState();
}

class _CourseCachePageState extends State<CourseCachePage>
    with WidgetsBindingObserver {
  late final store = widget.library ?? CourseCacheLibrary.instance;
  List<CourseCacheEntry> rows = const [];
  bool loading = true, suspended = false, accountChanged = false;
  String? error;
  int generation = 0, version = -1;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CacheLifecycle.account.addListener(_switch);
    store.addListener(_listen);
    unawaited(_load());
  }

  void _listen() {
    if (!mounted || suspended) return;
    if (store.listVersion != version) {
      unawaited(_load());
    } else {
      setState(() {});
    }
  }

  void _switch() {
    generation++;
    if (!mounted) return;
    setState(() {
      accountChanged = true;
      rows = const [];
      error = null;
      loading = true;
    });
    if (!suspended) unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      suspended = true;
      generation++;
      setState(() {
        rows = const [];
        loading = true;
        error = null;
      });
    } else if (state == AppLifecycleState.resumed && suspended) {
      suspended = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    CacheLifecycle.account.removeListener(_switch);
    store.removeListener(_listen);
    super.dispose();
  }

  Future<void> _load() async {
    final g = ++generation;
    version = store.listVersion;
    try {
      final found = await store.entries();
      if (mounted && g == generation) {
        setState(() {
          rows = found;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && g == generation) {
        setState(() {
          rows = const [];
          error = e is CourseCacheFailure ? e.message : '无法读取本账号的课程缓存。';
          loading = false;
        });
      }
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    final rev = CacheLifecycle.account.value;
    try {
      await action();
    } catch (e) {
      if (mounted && rev == CacheLifecycle.account.value && !suspended) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is CourseCacheFailure ? e.message : '操作未完成，请重试。'),
          ),
        );
      }
    }
  }

  Future<void> _remove(CourseCacheEntry e) async {
    final old = generation;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除章节缓存？'),
        content: const Text('只删除本机的课程媒体，不影响购买记录、进度或笔记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted && old == generation) {
      await _act(() => store.remove(e));
    }
  }

  Future<void> _open(CourseCacheEntry row) async {
    final old = generation;
    await _act(() async {
      final validated = await store.open(row);
      if (!mounted || old != generation) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              CourseCachePlaybackPage(library: store, entry: validated.entry),
        ),
      );
      if (mounted) await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final video = accountChanged ? null : widget.video, part = widget.part;
    final key =
        '${video?.courseSeasonId}-${part?.courseEpisodeId}-${part?.courseAid}-${part?.cid}';
    final selected = rows.where((e) => e.id == key).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程缓存'),
        actions: [
          IconButton(
            tooltip: '刷新课程缓存',
            onPressed: suspended ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('仅在课程方允许离线时使用。缓存只供当前购买账号使用，不支持导出；试看和受保护章节不可缓存。'),
            if (loading || suspended)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(error!),
              )
            else ...[
              if (video != null && part != null && selected == null) ...[
                const SizedBox(height: 16),
                Text(
                  part.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('cache-this-course-chapter'),
                    onPressed: store.busy
                        ? null
                        : () => _act(
                            () => store.start(
                              video,
                              part,
                              quality: widget.quality,
                            ),
                          ),
                    icon: const Icon(Icons.download),
                    label: const Text('缓存本章'),
                  ),
                ),
              ],
              if (store.busy && store.activeId != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: store.total != null && store.total! > 0
                      ? (store.received / store.total!).clamp(0, 1)
                      : null,
                ),
                TextButton.icon(
                  onPressed: () => _act(store.pause),
                  icon: const Icon(Icons.pause),
                  label: Text(
                    '暂停缓存 · ${(store.received / 1048576).toStringAsFixed(1)} MB',
                  ),
                ),
              ],
              if (store.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    store.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Text('本机章节', style: Theme.of(context).textTheme.titleMedium),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text('暂无章节缓存。可在已购课程播放器中选择「缓存本章」。'),
                ),
              for (final row in rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.courseTitle,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(row.chapterTitle),
                        Text(
                          !row.complete
                              ? '未完成，可联网继续'
                              : row.usableAt(DateTime.now())
                              ? '已缓存 · ${((row.videoBytes + row.audioBytes) / 1048576).toStringAsFixed(1)} MB'
                              : '校验已到期，需重新联网缓存',
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (row.usableAt(DateTime.now()))
                              TextButton.icon(
                                onPressed: () => _open(row),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('离线播放'),
                              )
                            else
                              TextButton.icon(
                                onPressed: store.busy
                                    ? null
                                    : () => _act(
                                        () => store.start(
                                          row.video,
                                          row.part,
                                          quality: row.quality,
                                        ),
                                      ),
                                icon: const Icon(Icons.download),
                                label: Text(row.complete ? '重新缓存' : '继续缓存'),
                              ),
                            TextButton(
                              onPressed: store.busy ? null : () => _remove(row),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
