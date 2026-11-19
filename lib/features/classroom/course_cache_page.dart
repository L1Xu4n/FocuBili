import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  Timer? _expiry;
  String? _opening;
  final _needsRecheck = <String, DateTime?>{};

  void _watchExpiry() {
    _expiry?.cancel();
    if (suspended) return;
    Duration? next;
    for (final row in rows) {
      if (!store.isUsable(row)) continue;
      final wait = store.untilExpiry(row);
      if (wait != null && (next == null || wait < next)) next = wait;
    }
    if (next != null && next > Duration.zero) {
      _expiry = Timer(next, () {
        if (!mounted || suspended) return;
        setState(() {});
        _watchExpiry();
      });
    }
  }

  bool _usable(CourseCacheEntry entry) =>
      store.isUsable(entry) && !_needsRecheck.containsKey(entry.id);
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
      _needsRecheck.clear();
      _opening = null;
      rows = const [];
      error = null;
      loading = true;
    });
    _expiry?.cancel();
    if (!suspended) unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      suspended = true;
      _expiry?.cancel();
      generation++;
      setState(() {
        _opening = null;
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
    _expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    CacheLifecycle.account.removeListener(_switch);
    store.removeListener(_listen);
    super.dispose();
  }

  Future<void> _load() async {
    final g = ++generation;
    version = store.listVersion;
    _opening = null;
    try {
      final found = await store.entries();
      if (mounted && g == generation) {
        setState(() {
          rows = found;
          _needsRecheck.removeWhere((id, checked) {
            final next = found.where((e) => e.id == id).firstOrNull;
            return next == null || next.checkedAt != checked;
          });
          _watchExpiry();
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

  Future<void> _copyDiagnostic(String code) async {
    final revision = CacheLifecycle.account.value;
    var message = '已复制诊断代码';
    try {
      await Clipboard.setData(ClipboardData(text: code));
    } catch (_) {
      message = '复制失败，请重试。';
    }
    if (!mounted ||
        suspended ||
        revision != CacheLifecycle.account.value ||
        store.diagnosticCode != code ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
    if (_opening != null) return;
    final old = generation;
    setState(() => _opening = row.id);
    try {
      await _act(() async {
        final ({CourseCacheEntry entry, String video, String? audio}) validated;
        try {
          validated = await store.open(row);
        } on CourseCacheFailure catch (error) {
          if (error.recheckNeeded && mounted && old == generation) {
            setState(() => _needsRecheck[row.id] = row.checkedAt);
          }
          rethrow;
        }
        if (!mounted || old != generation) return;
        setState(() => _opening = null);
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                CourseCachePlaybackPage(library: store, entry: validated.entry),
          ),
        );
        if (mounted) await _load();
      });
    } finally {
      if (mounted && old == generation && _opening == row.id) {
        setState(() => _opening = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = accountChanged ? null : widget.video, part = widget.part;
    final key =
        '${video?.courseSeasonId}-${part?.courseEpisodeId}-${part?.courseAid}-${part?.cid}';
    final selected = rows.where((e) => e.id == key).firstOrNull;
    final diagnostic = store.diagnosticCode;
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
                    store.checking
                        ? '取消联网复核'
                        : '暂停缓存 · ${(store.received / 1048576).toStringAsFixed(1)} MB',
                  ),
                ),
              ],
              if (store.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          store.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      if (diagnostic != null)
                        IconButton(
                          tooltip: '复制诊断代码',
                          onPressed: () => _copyDiagnostic(diagnostic),
                          icon: const Icon(Icons.copy_outlined, size: 18),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              Text('本机章节', style: Theme.of(context).textTheme.titleMedium),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    video != null && part != null
                        ? '暂无缓存'
                        : '暂无缓存，可在课程播放器中缓存章节。',
                  ),
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
                          !row.hasMedia
                              ? '未完成，可联网继续'
                              : _usable(row)
                              ? '已缓存 · ${((row.videoBytes + row.audioBytes) / 1048576).toStringAsFixed(1)} MB'
                              : '需联网复核，必要时重新下载',
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (_usable(row))
                              TextButton.icon(
                                onPressed:
                                    store.activeId == row.id || _opening != null
                                    ? null
                                    : () => _open(row),
                                icon: const Icon(Icons.play_arrow),
                                label: Text(
                                  _opening == row.id ? '正在检查本地文件' : '离线播放',
                                ),
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
                                icon: Icon(
                                  row.hasMedia
                                      ? Icons.verified_outlined
                                      : Icons.download,
                                ),
                                label: Text(row.hasMedia ? '联网复核' : '继续缓存'),
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
