import 'package:flutter/material.dart';

/// 给专注入口提供可恢复的读取失败状态，不把原有记录显示成空数据。
class FocusStorageNotice extends StatefulWidget {
  const FocusStorageNotice({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  State<FocusStorageNotice> createState() => _FocusStorageNoticeState();
}

class _FocusStorageNoticeState extends State<FocusStorageNotice> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('暂时无法读取本机专注记录。原有记录不会被覆盖。'),
        TextButton.icon(
          onPressed: _retrying ? null : _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(_retrying ? '正在重新读取…' : '重新读取'),
        ),
      ],
    ),
  );
}
