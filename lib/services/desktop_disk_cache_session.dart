import 'dart:async';

import 'media_cache_service.dart';

typedef MpvPropertyWriter = Future<void> Function(String name, String value);

/// mpv's append-only packet file has no native byte cap. This is deliberately
/// a soft threshold: sampling/option propagation can overshoot it. Switching
/// off new disk writes keeps the existing file available until media closes.
class DesktopDiskCacheSession {
  /// Connects one player's mpv options to its disk lease and sampler.
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
  bool _diskAllowed = false;
  bool _preferDataSaving = false;
  bool _configured = false;
  bool _diskReady = false;
  bool _retainingPackets = false;
  int _threshold = defaultMediaCacheBytes;
  Object? _configurationError;

  /// Last option or storage error observed while applying the policy.
  Object? get configurationError => _configurationError;

  /// Whether disk writes have been disabled successfully.
  bool get writesSuspended => _suspended;

  /// Temporary packet directory held until the player closes.
  String? get directoryPath => _lease?.directory.path;

  /// Serializes property writes and sampling with shutdown.
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

  /// Verifies the mpv value after a write because the backend discards status codes.
  Future<void> _set(
    String name,
    String value, {
    bool Function(String)? matches,
  }) async {
    await writeProperty(name, value);
    // media_kit setProperty discards mpv's status code. Explicit readback is
    // required before saying that the option was accepted (workers may lag).
    final actual = await readProperty(name);
    if (!(matches?.call(actual) ?? actual == value)) {
      throw StateError('Player cache option was not accepted: $name');
    }
  }

  /// Accepts numeric readback from both supported mpv versions.
  Future<void> _setNumber(String name, double value) => _set(
    name,
    value.toStringAsFixed(3),
    matches: (actual) {
      final parsed = double.tryParse(actual);
      return parsed != null &&
          parsed.isFinite &&
          (parsed - value).abs() < 0.001;
    },
  );

  /// Compares byte budgets using exact integer values.
  Future<void> _setBytes(String name, int value) =>
      _set(name, '$value', matches: (actual) => int.tryParse(actual) == value);

  /// Creates the lease and sampler once. Each media open applies its own policy.
  Future<void> configure() => _serial(() async {
    if (_configured) return;
    _configured = true;
    try {
      _lease = await storage.openSession();
      _threshold = await storage.loadCapacityBytes();
      // Enable only after every required path/accounting option succeeded.
      await _set('cache-on-disk', 'no');
      await _set('cache', 'yes');
      await _setCacheLocation(_lease!.directory.path);
      _diskReady = true;
      if (_stopped) return;
      _timer = Timer.periodic(pollInterval, (_) {
        // Skip overlapping samples rather than building up an operation queue.
        if (_sampling) return;
        unawaited(sample());
      });
    } catch (error) {
      _configurationError = error;
    }
  });

  /// Uses the modern cache path options or the aliases provided by mpv 0.36.
  Future<void> _setCacheLocation(String path) async {
    /// Normalizes platform-specific separators only for the path property.
    bool samePath(String actual) =>
        actual.replaceAll('\\', '/') == path.replaceAll('\\', '/');
    try {
      await _set('demuxer-cache-dir', path, matches: samePath);
      await _set('demuxer-cache-unlink-files', 'whendone');
    } catch (_) {
      // The bundled Apple mpv 0.36 uses the old option names. Both options
      // must pass readback before disk writes are enabled on either version.
      await _set('cache-dir', path, matches: samePath);
      await _set('cache-unlink-files', 'whendone');
    }
  }

  /// 每次打开媒体前选择网络预算，课堂和省流禁止写盘。
  Future<void> applyPlaybackPolicy({
    required bool diskAllowed,
    required bool preferDataSaving,
  }) => _serial(() async {
    _diskAllowed = diskAllowed;
    _preferDataSaving = preferDataSaving;
    try {
      if (!diskAllowed) {
        await _suspend(preferDataSaving ? '课堂使用省流内存缓冲。' : '课堂使用内存缓冲。');
      } else if (preferDataSaving) {
        await _suspend('计量网络或省流模式，使用较小的内存缓冲。');
      } else if (!_diskReady) {
        await _suspend('磁盘缓冲未能启用，暂用内存缓冲；磁盘软阈值不可用。');
      } else {
        _configurationError = null;
        await _updateDiskUsage(reapply: true);
      }
    } catch (error) {
      _configurationError = error;
      try {
        await _suspend('磁盘缓冲未能启用，暂用内存缓冲；磁盘软阈值不可用。');
      } catch (_) {
        WindowsMediaCacheRuntime.diskMessages[this] =
            '无法确认播放器缓冲设置，磁盘软阈值暂未生效；退出播放后会清理。';
        // A disallowed session must never open media without verified disk-off.
        if (!diskAllowed || preferDataSaving) rethrow;
      }
    }
  });

  /// Applies both demuxer time limits and the active forward/backward budgets.
  Future<void> _setBudgets(int forward, int back) async {
    final seconds = _preferDataSaving ? 15.0 : 30.0;
    await _setNumber('cache-secs', seconds);
    await _setNumber('demuxer-readahead-secs', seconds);
    await _setBytes('demuxer-max-bytes', forward);
    await _setBytes('demuxer-max-back-bytes', back);
  }

  /// Enables disk only after the bounded demuxer settings pass readback.
  Future<void> _enableDisk() async {
    await _setBudgets(_threshold, _threshold);
    await _set('cache-on-disk', 'yes');
    _suspended = false;
    WindowsMediaCacheRuntime.diskMessages.remove(this);
  }

  bool _sampling = false;

  /// Checks disk usage without overlapping policy changes or other samples.
  Future<void> sample() async {
    if (_sampling || _stopped || !_diskReady) return;
    _sampling = true;
    try {
      await _serial(() async {
        if (_diskAllowed && !_preferDataSaving) await _updateDiskUsage();
      });
    } catch (error) {
      _configurationError = error;
      // Keep retrying the guard. Do not claim a failed option change bounded it.
      WindowsMediaCacheRuntime.diskMessages[this] =
          '播放器未能暂停磁盘写入，软阈值暂未生效；退出播放后会清理。';
    } finally {
      _sampling = false;
    }
  }

  /// Restores disk mode after a soft failure only when retained packets close.
  Future<void> _updateDiskUsage({bool reapply = false}) async {
    final int bytes;
    try {
      bytes = await storage.diskBytes();
    } catch (_) {
      if (!_suspended || !_retainingPackets || reapply) {
        await _suspend('无法读取磁盘占用，暂停新增磁盘缓冲。');
      }
      _retainingPackets = true;
      return;
    }
    if (bytes >= _threshold) {
      if (!_suspended || !_retainingPackets || reapply) {
        await _suspend('已达到磁盘软阈值，保留已有文件，暂停新增磁盘缓冲。');
      }
      _retainingPackets = true;
    } else if (_suspended || reapply) {
      if (_retainingPackets) {
        final files = await _lease!.directory.list(followLinks: false).toList();
        if (files.any((file) => file.uri.pathSegments.last != 'owner.lock')) {
          if (reapply) await _suspend('保留已有磁盘缓冲，等待当前媒体关闭后恢复写入。');
          return;
        }
        _retainingPackets = false;
      }
      await _enableDisk();
    }
  }

  /// Verifies disk-off first, then sets the matching RAM and time budgets.
  Future<void> _suspend(String message) async {
    await _set('cache-on-disk', 'no');
    // Once packets are no longer written to disk, use bounded RAM for new
    // data. The existing files stay open; seeks depend on retained metadata.
    const mib = 1024 * 1024;
    await _setBudgets(
      _preferDataSaving ? 16 * mib : 32 * mib,
      _preferDataSaving ? 16 * mib : desktopFallbackMemoryBytes,
    );
    _suspended = true;
    WindowsMediaCacheRuntime.diskMessages[this] = message;
  }

  /// Stop option mutations before destroying mpv, but retain its lifetime lock.
  Future<void> stopMonitoring() async {
    _stopped = true;
    _timer?.cancel();
    await _operations;
  }

  /// Must run AFTER public player disposal succeeds, including external audio.
  /// media_kit may still finish native cleanup; storage handles late unlinks.
  Future<void> releaseAfterPlayerClosed() async {
    await stopMonitoring();
    WindowsMediaCacheRuntime.diskMessages.remove(this);
    await _lease?.close();
  }
}
