import 'dart:async';

import 'media_cache_service.dart';

typedef MpvPropertyWriter = Future<void> Function(String name, String value);

/// mpv's append-only packet file has no native byte cap. This is deliberately
/// a soft threshold: sampling/option propagation can overshoot it. Switching
/// off new disk writes keeps the existing file available until media closes.
class DesktopDiskCacheSession {
  DesktopDiskCacheSession({
    required this.writeProperty,
    required this.readProperty,
    WindowsMediaCacheService? storage,
    this.pollInterval = const Duration(milliseconds: 500),
  }) : storage = storage ?? WindowsMediaCacheService();

  final MpvPropertyWriter writeProperty;
  final Future<String> Function(String) readProperty;
  final WindowsMediaCacheService storage;
  final Duration pollInterval;
  MediaCacheDirectoryLease? _lease;
  Timer? _timer;
  Future<void> _operations = Future.value();
  bool _stopped = false;
  bool _suspended = false;
  int _threshold = defaultMediaCacheBytes;
  Object? _configurationError;
  Object? get configurationError => _configurationError;
  bool get writesSuspended => _suspended;
  String? get directoryPath => _lease?.directory.path;

  Future<void> _serial(Future<void> Function() action) {
    final operation = _operations.then((_) async {
      if (!_stopped) await action();
    });
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _set(String name, String value) async {
    await writeProperty(name, value);
    // media_kit setProperty discards mpv's status code. Explicit readback is
    // required before saying that the option was accepted (workers may lag).
    final actual = await readProperty(name);
    if (actual.replaceAll('\\', '/') != value.replaceAll('\\', '/')) {
      throw StateError('Player cache option was not accepted: $name');
    }
  }

  Future<void> configure() => _serial(() async {
    _configurationError = null;
    try {
      _lease = await storage.openSession();
      _threshold = await storage.loadCapacityBytes();
      // Enable only after every required path/accounting option succeeded.
      await _set('cache-on-disk', 'no');
      await _set('cache', 'yes');
      await _setCacheLocation(_lease!.directory.path);
      if (await storage.diskBytes() >= _threshold) {
        await _suspend('已达到磁盘软阈值，保留已有文件，暂停新增磁盘缓冲。');
      } else {
        await _enableDisk();
      }
      if (_stopped) return;
      _timer = Timer.periodic(pollInterval, (_) {
        // Skip overlapping samples rather than building up an operation queue.
        if (_sampling) return;
        unawaited(sample());
      });
    } catch (error) {
      _configurationError = error;
      try {
        await _suspend('磁盘缓冲未能启用，暂用内存缓冲；磁盘软阈值不可用。');
      } catch (_) {
        WindowsMediaCacheRuntime.diskMessages[this] =
            '无法确认播放器缓冲设置，磁盘软阈值暂未生效；退出播放后会清理。';
      }
    }
  });

  Future<void> _setCacheLocation(String path) async {
    try {
      await _set('demuxer-cache-dir', path);
      await _set('demuxer-cache-unlink-files', 'whendone');
    } catch (_) {
      // The bundled Apple mpv 0.36 uses the old option names. Both options
      // must pass readback before disk writes are enabled on either version.
      await _set('cache-dir', path);
      await _set('cache-unlink-files', 'whendone');
    }
  }

  Future<void> _enableDisk() async {
    // Preserve the previous metadata budgets while using disk packets. These
    // are memory metadata limits, never a claim about physical disk size.
    await _set('demuxer-max-bytes', _threshold.toString());
    await _set('demuxer-max-back-bytes', _threshold.toString());
    await _set('cache-on-disk', 'yes');
    _suspended = false;
    WindowsMediaCacheRuntime.diskMessages.remove(this);
  }

  bool _sampling = false;
  Future<void> sample() async {
    if (_sampling || _stopped || _lease == null) return;
    _sampling = true;
    try {
      await _serial(() async {
        int bytes;
        try {
          bytes = await storage.diskBytes();
        } catch (_) {
          await _suspend('无法读取磁盘占用，暂停新增磁盘缓冲。');
          return;
        }
        if (bytes >= _threshold && !_suspended) {
          await _suspend('已达到磁盘软阈值，保留已有文件，暂停新增磁盘缓冲。');
        } else if (_suspended && bytes < _threshold) {
          // mpv removes the session's packet files when its media closes.
          // Re-enable for a later video only after all our old files are gone.
          final files = await _lease!.directory
              .list(followLinks: false)
              .toList();
          if (files.every(
            (file) => file.uri.pathSegments.last == 'owner.lock',
          )) {
            await _enableDisk();
          }
        }
      });
    } catch (_) {
      // Keep retrying the guard. Do not claim a failed option change bounded it.
      WindowsMediaCacheRuntime.diskMessages[this] =
          '播放器未能暂停磁盘写入，软阈值暂未生效；退出播放后会清理。';
    } finally {
      _sampling = false;
    }
  }

  Future<void> _suspend(String message) async {
    await _set('cache-on-disk', 'no');
    // Once packets are no longer written to disk, use bounded RAM for new
    // data. The existing files stay open; seeks depend on retained metadata.
    await _set('demuxer-max-bytes', desktopFallbackMemoryBytes.toString());
    await _set('demuxer-max-back-bytes', desktopFallbackMemoryBytes.toString());
    _suspended = true;
    WindowsMediaCacheRuntime.diskMessages[this] = message;
  }

  /// Stop option mutations before destroying mpv, but retain its lifetime lock.
  Future<void> stopMonitoring() async {
    _stopped = true;
    _timer?.cancel();
    await _operations;
  }

  /// Must run AFTER the player has closed its files, including external audio.
  Future<void> releaseAfterPlayerClosed() async {
    await stopMonitoring();
    WindowsMediaCacheRuntime.diskMessages.remove(this);
    await _lease?.close();
  }
}
