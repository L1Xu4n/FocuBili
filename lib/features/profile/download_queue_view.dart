import 'package:flutter/material.dart';

import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/offline_download_task.dart';
import '../../services/offline_download_queue.dart';

/// Shows durable task state with pause, resume, retry and removal controls.
class DownloadQueueView extends StatelessWidget {
  /// Reuses the process queue so navigating away never destroys a transfer.
  const DownloadQueueView({super.key, required this.queue, this.query = ''});
  final OfflineDownloadQueue queue;
  final String query;

  /// Formats byte counts consistently for both determinate and unknown totals.
  String _bytes(int value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(value / 1024).toStringAsFixed(0)} KB';

  /// Converts internal states into concise, user-visible task labels.
  String _status(DownloadTaskStatus status) => switch (status) {
    DownloadTaskStatus.queued => '等待下载',
    DownloadTaskStatus.downloading => '下载中',
    DownloadTaskStatus.paused => '已暂停',
    DownloadTaskStatus.failed => '下载失败',
    DownloadTaskStatus.completed => '已完成',
  };

  /// Reports command failures without leaving unhandled asynchronous exceptions.
  Future<void> _run(
    BuildContext context,
    Future<void> Function() command,
  ) async {
    try {
      await command();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下载任务操作失败，请重试。')));
      }
    }
  }

  /// Confirms removing an unfinished task because it discards partial bytes.
  Future<void> _remove(BuildContext context, OfflineDownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载任务'),
        content: Text(
          task.status == DownloadTaskStatus.completed
              ? '仅移除任务记录，保留已完成的缓存。'
              : '删除“${task.video.title}”的任务和未完成文件？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _run(context, () => queue.remove(task.id));
    }
  }

  /// 按可用宽度显示一列或两列任务，标题与进度独占整行，操作按钮固定在卡片底部。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: queue,
    builder: (context, _) {
      final needle = query.trim().toLowerCase();
      final tasks = queue.tasks
          .where(
            (e) =>
                '${e.video.title} ${e.part.title} ${e.video.ownerName} ${e.video.bvid}'
                    .toLowerCase()
                    .contains(needle),
          )
          .toList();
      if (tasks.isEmpty) {
        return Center(child: Text(needle.isEmpty ? '暂无下载任务' : '没有匹配的下载任务'));
      }
      return AdaptiveTwoColumnList(
        key: const Key('download-queue-list'),
        padding: const EdgeInsets.all(16),
        itemCount: tasks.length,
        breakpoint: 840,
        mainAxisSpacing: 12,
        crossAxisSpacing: 16,
        itemBuilder: (context, index) {
          final task = tasks[index];
          final active =
              task.status == DownloadTaskStatus.downloading ||
              task.status == DownloadTaskStatus.queued;
          return Card(
            key: Key('download-task-${task.id}'),
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'P${task.part.pageNumber} ${task.part.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: task.progress ?? (active ? null : 0),
                        minHeight: 6,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_status(task.status)} · ${_bytes(task.receivedBytes)}${task.totalBytes == null ? '' : ' / ${_bytes(task.totalBytes!)}'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (task.status == DownloadTaskStatus.downloading)
                        Text(
                          task.speedLabel,
                          key: Key('download-speed-${task.id}'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (task.error != null)
                        Text(
                          task.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (task.status != DownloadTaskStatus.completed)
                        IconButton(
                          key: Key('toggle-download-${task.id}'),
                          tooltip: active
                              ? '暂停'
                              : task.status == DownloadTaskStatus.failed
                              ? '重试'
                              : '继续下载',
                          icon: Icon(active ? Icons.pause : Icons.play_arrow),
                          onPressed: () => _run(
                            context,
                            () => active
                                ? queue.pause(task.id)
                                : queue.resume(task.id),
                          ),
                        ),
                      IconButton(
                        tooltip: '删除任务',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(context, task),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
