import 'package:flutter/material.dart';
import '../../models/content_blocklist.dart';
import '../../services/content_blocklist_service.dart';

/// Lists all local blocks with a per-entry cancellation path.
class ContentBlocklistPage extends StatefulWidget {
  const ContentBlocklistPage({
    super.key,
    this.service = const ContentBlocklistService(),
  });
  final ContentBlocklistService service;

  @override
  State<ContentBlocklistPage> createState() => _ContentBlocklistPageState();
}

class _ContentBlocklistPageState extends State<ContentBlocklistPage> {
  ContentBlocklist? _list;
  bool _failed = false;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ContentBlocklistService.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    ContentBlocklistService.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final list = await widget.service.load();
      if (mounted && generation == _generation) {
        setState(() {
          _list = list;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  Future<void> _remove(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取消屏蔽失败，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('黑名单')),
      body: _failed
          ? Center(
              child: TextButton(
                onPressed: _reload,
                child: const Text('黑名单读取失败，点击重试'),
              ),
            )
          : list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('屏蔽在本机生效，隐藏搜索中的视频。不会删除收藏、学习清单、观看记录或笔记，也不会修改 B 站账号。'),
                const SizedBox(height: 20),
                Text(
                  'UP 主（${list.creators.length}）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (list.creators.isEmpty)
                  const ListTile(title: Text('暂无屏蔽的 UP 主')),
                for (final entry in list.creators.entries)
                  ListTile(
                    title: Text(entry.value.isEmpty ? 'UP 主' : entry.value),
                    subtitle: Text('UID ${entry.key}'),
                    trailing: TextButton(
                      key: Key('unblock-creator-${entry.key}'),
                      onPressed: _busy
                          ? null
                          : () => _remove(
                              () => widget.service.unblockCreator(entry.key),
                            ),
                      child: const Text('取消屏蔽'),
                    ),
                  ),
                const Divider(height: 32),
                Text(
                  '视频（${list.videos.length}）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (list.videos.isEmpty) const ListTile(title: Text('暂无屏蔽的视频')),
                for (final entry in list.videos.entries)
                  ListTile(
                    title: Text(entry.value.isEmpty ? entry.key : entry.value),
                    subtitle: Text(entry.key),
                    trailing: TextButton(
                      key: Key('unblock-video-${entry.key}'),
                      onPressed: _busy
                          ? null
                          : () => _remove(
                              () => widget.service.unblockVideo(entry.key),
                            ),
                      child: const Text('取消屏蔽'),
                    ),
                  ),
              ],
            ),
    );
  }
}
