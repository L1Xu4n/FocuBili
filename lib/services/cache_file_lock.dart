import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _Open = int Function(Pointer<Utf8>, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _Flock = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _Close = int Function(int);

/// Unix Dart FileLock is process-scoped: two isolates can both obtain it, and
/// closing either descriptor releases all process locks. flock uses an open
/// file description instead. Nonblocking retries never freeze the UI isolate.
class CacheFileLock {
  CacheFileLock._(this._fd, this._file);
  final int? _fd;
  final RandomAccessFile? _file;
  static final _library = DynamicLibrary.process();
  static final _open = _library.lookupFunction<_OpenNative, _Open>('open');
  static final _flock = _library.lookupFunction<_FlockNative, _Flock>('flock');
  static final _close = _library.lookupFunction<_CloseNative, _Close>('close');

  static Future<CacheFileLock> acquire(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) => _acquire(path, timeout: timeout, readOnly: false);

  /// Waits for an existing writer without creating or modifying a lock file.
  /// An absent lock is safe for readers of atomically replaced metadata.
  static Future<CacheFileLock?> acquireExisting(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe cache lock');
    }
    return _acquire(path, timeout: timeout, readOnly: true);
  }

  static Future<CacheFileLock> _acquire(
    String path, {
    required Duration timeout,
    required bool readOnly,
  }) async {
    int? descriptor;
    RandomAccessFile? file;
    try {
      if (Platform.isWindows) {
        file = await File(
          path,
        ).open(mode: readOnly ? FileMode.read : FileMode.append);
      } else {
        // Creating through dart:io avoids open's variadic mode argument ABI
        // (notably different on Apple arm64). Existing lock files are retained.
        if (!readOnly) await File(path).create();
        final name = path.toNativeUtf8();
        try {
          final noFollow = Platform.isMacOS || Platform.isIOS
              ? 0x0100
              : 0x20000;
          descriptor = _open(name, (readOnly ? 0 : 2) | noFollow);
        } finally {
          calloc.free(name);
        }
        if (descriptor < 0) {
          throw const FileSystemException('Cannot open cache lock');
        }
      }
      final watch = Stopwatch()..start();
      while (true) {
        if (descriptor != null) {
          if (_flock(descriptor, (readOnly ? 1 : 2) | 4) == 0) {
            return CacheFileLock._(descriptor, null); // LOCK_SH/EX | LOCK_NB
          }
        } else {
          try {
            await file!.lock(readOnly ? FileLock.shared : FileLock.exclusive);
            return CacheFileLock._(null, file);
          } on FileSystemException {
            /* Retry a held Windows handle lock. */
          }
        }
        if (watch.elapsed >= timeout) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      throw const FileSystemException('Cache lock busy');
    } catch (_) {
      if (descriptor != null && descriptor >= 0) _close(descriptor);
      await file?.close();
      rethrow;
    }
  }

  Future<void> release() async {
    if (_fd != null) {
      _close(_fd);
    } else {
      await _file?.close();
    }
  }
}
