import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/offline_cache_locations.dart';

Future<void> showOfflineCacheLocationDialog(
  BuildContext context,
  OfflineCacheLocations locations,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _OfflineCacheLocationDialog(locations: locations),
);

class _OfflineCacheLocationDialog extends StatefulWidget {
  const _OfflineCacheLocationDialog({required this.locations});

  final OfflineCacheLocations locations;

  @override
  State<_OfflineCacheLocationDialog> createState() =>
      _OfflineCacheLocationDialogState();
}

class _OfflineCacheLocationDialogState
    extends State<_OfflineCacheLocationDialog> {
  String? _path, _error;
  bool _available = true, _busy = true, _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh([Future<void> Function()? action]) async {
    if (action != null) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action?.call();
      final status = await widget.locations.status();
      if (!mounted) return;
      setState(() {
        _path = status.path;
        _available = status.available;
        _loaded = true;
      });
    } on OfflineCacheLocationException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法更改离线缓存位置，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('离线缓存位置'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loaded)
                SelectableText(
                  _path ?? '系统默认位置',
                  key: const Key('offline-cache-location-path'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('只影响新下载。已有缓存和下载任务留在原位置，不会移动或删除。'),
              if (!_available || _error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error ?? OfflineCacheLocationException.unavailable.message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (_path != null)
          TextButton(
            onPressed: _busy
                ? null
                : () => unawaited(_refresh(widget.locations.reset)),
            child: const Text('恢复默认'),
          ),
        FilledButton(
          onPressed: _busy
              ? null
              : () => unawaited(
                  _refresh(() async {
                    await widget.locations.choose();
                  }),
                ),
          child: const Text('选择文件夹'),
        ),
      ],
    ),
  );
}
