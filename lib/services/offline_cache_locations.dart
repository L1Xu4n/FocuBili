import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_platform.dart';

typedef OfflineCacheSelection = ({String path, String? bookmark});
typedef _CacheLocation = ({String path, String? bookmark});
typedef _CacheSettings = ({String? active, Map<String, _CacheLocation> roots});

class OfflineCacheLocationException implements Exception {
  const OfflineCacheLocationException(this.message);

  static const unavailable = OfflineCacheLocationUnavailable();

  final String message;

  @override
  String toString() => message;
}

class OfflineCacheLocationUnavailable extends OfflineCacheLocationException {
  const OfflineCacheLocationUnavailable() : super('离线缓存目录不可用。请连接原磁盘或重新授权后重试。');
}

/// Device-local registry. Switching the active location never changes existing
/// records, jobs, or filesystem contents at the previously selected location.
class OfflineCacheLocations {
  OfflineCacheLocations({
    AppPlatform? platform,
    Future<SharedPreferences> Function()? preferences,
    Future<OfflineCacheSelection?> Function()? pickDirectory,
    Future<String?> Function(String bookmark)? restoreDirectory,
  }) : _platform = platform ?? AppPlatformDetector.current,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _pickDirectory = pickDirectory,
       _restoreDirectory = restoreDirectory;

  static final instance = OfflineCacheLocations();
  static final systemOnly = OfflineCacheLocations(
    platform: AppPlatform.unsupported,
  );
  static const storageKey = 'offline_cache_locations.v1';
  static const _channel = MethodChannel('focubili/offline_cache_directory');
  static const _markerName = '.focubili-cache-owner';
  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');

  final AppPlatform _platform;
  final Future<SharedPreferences> Function() _preferences;
  final Future<OfflineCacheSelection?> Function()? _pickDirectory;
  final Future<String?> Function(String bookmark)? _restoreDirectory;
  Future<void>? _pendingWrite;

  bool get supported => _platform.isDesktop;

  Future<_CacheSettings> _read() async {
    if (!supported) return (active: null, roots: <String, _CacheLocation>{});
    try {
      final raw = (await _preferences()).getString(storageKey);
      if (raw == null) return (active: null, roots: <String, _CacheLocation>{});
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final active = data['active'] as String?;
      final roots = {
        for (final entry in (data['roots'] as Map<String, dynamic>).entries)
          entry.key: (
            path: entry.value['path'] as String,
            bookmark: entry.value['bookmark'] as String?,
          ),
      };
      if (roots.entries.any(
            (entry) =>
                !_idPattern.hasMatch(entry.key) ||
                !Directory(entry.value.path).isAbsolute ||
                !Directory(entry.value.path).uri.pathSegments
                    .where((segment) => segment.isNotEmpty)
                    .last
                    .startsWith('FocuBili-Offline-'),
          ) ||
          (active != null && !roots.containsKey(active))) {
        throw const FormatException();
      }
      return (active: active, roots: roots);
    } catch (_) {
      throw const OfflineCacheLocationException('无法读取离线缓存目录设置，原记录已保留。');
    }
  }

  Future<void> _save(_CacheSettings settings) async {
    final prefs = await _preferences();
    try {
      if (await prefs.setString(
        storageKey,
        jsonEncode({
          'active': settings.active,
          'roots': {
            for (final entry in settings.roots.entries)
              entry.key: {
                'path': entry.value.path,
                'bookmark': entry.value.bookmark,
              },
          },
        }),
      )) {
        return;
      }
    } catch (_) {
      // SharedPreferences can update its local cache before the platform write.
    }
    await prefs.reload();
    throw const OfflineCacheLocationException('无法保存离线缓存目录设置，请重试。');
  }

  Future<T> _change<T>(Future<T> Function() action) {
    final previous = _pendingWrite;
    final result = Future<T>.sync(() async {
      await previous;
      return action();
    });
    late final Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_pendingWrite, settled)) _pendingWrite = null;
        });
    _pendingWrite = settled;
    return result;
  }

  Future<String?> activeId() async {
    await _pendingWrite;
    return (await _read()).active;
  }

  /// Includes recently used removable drives even when they are disconnected.
  Future<List<String>> registeredIds() async {
    await _pendingWrite;
    return (await _read()).roots.keys.toList(growable: false);
  }

  Future<({String? path, bool available})> status() async {
    await _pendingWrite;
    final settings = await _read();
    final active = settings.active;
    if (active == null) return (path: null, available: true);
    final location = settings.roots[active]!;
    return (
      path: location.path,
      available: await _verifiedRoot(active, location) != null,
    );
  }

  Future<OfflineCacheSelection?> _nativePicker() async {
    if (_platform == AppPlatform.macos) {
      final selected = await _channel.invokeMapMethod<String, String>('pick');
      if (selected == null) return null;
      return (path: selected['path']!, bookmark: selected['bookmark']!);
    }
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择离线缓存目录',
      lockParentWindow: true,
    );
    return path == null ? null : (path: path, bookmark: null);
  }

  Future<String?> _restore(String bookmark) =>
      _restoreDirectory?.call(bookmark) ??
      _channel.invokeMethod<String>('restore', bookmark);

  /// A fresh directory is exclusively created for this installation. No
  /// pre-existing directory is adopted, even if its name looks like ours.
  Future<bool> choose() async {
    if (!supported) return false;
    final OfflineCacheSelection? selection;
    try {
      selection = await (_pickDirectory ?? _nativePicker)();
    } catch (_) {
      throw const OfflineCacheLocationException('无法打开系统文件夹选择器。');
    }
    final selected = selection;
    if (selected == null) return false;

    return _change(() async {
      final settings = await _read();
      late final Directory parent;
      try {
        final picked = Directory(selected.path);
        if (!picked.isAbsolute ||
            !await picked.exists() ||
            (_platform == AppPlatform.macos && selected.bookmark == null)) {
          throw OfflineCacheLocationException.unavailable;
        }
        parent = Directory(await picked.resolveSymbolicLinks());
        if (selected.bookmark != null &&
            await _restore(selected.bookmark!) != parent.path) {
          throw OfflineCacheLocationException.unavailable;
        }
      } catch (_) {
        throw const OfflineCacheLocationException('所选文件夹不可用，请重新选择。');
      }

      for (final entry in settings.roots.entries) {
        final candidate = (path: entry.value.path, bookmark: selected.bookmark);
        if (Directory(candidate.path).parent.uri == parent.uri) {
          final existing = await _verifiedRoot(entry.key, candidate);
          if (existing == null) continue;
          try {
            // Verify write permission even when reusing a registered location.
            final probe = await existing.createTemp('.focubili-write-test-');
            await probe.delete();
          } catch (_) {
            throw const OfflineCacheLocationException('无法写入所选文件夹，请检查权限和可用空间。');
          }
          await _save((
            active: entry.key,
            roots: {...settings.roots, entry.key: candidate},
          ));
          return true;
        }
      }

      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final Directory root;
      try {
        root = await parent.createTemp('FocuBili-Offline-');
        await File.fromUri(
          root.uri.resolve(_markerName),
        ).writeAsString(id, flush: true);
      } catch (_) {
        throw const OfflineCacheLocationException('无法写入所选文件夹，请检查权限和可用空间。');
      }
      final location = (path: root.path, bookmark: selected.bookmark);
      await _save((active: id, roots: {...settings.roots, id: location}));
      return true;
    });
  }

  Future<void> reset() async {
    if (!supported) return;
    await _change(() async {
      final settings = await _read();
      if (settings.active != null) {
        await _save((active: null, roots: settings.roots));
      }
    });
  }

  Future<Directory?> _verifiedRoot(String id, _CacheLocation location) async {
    try {
      final root = Directory(location.path);
      if (_platform == AppPlatform.macos &&
          (location.bookmark == null ||
              await _restore(location.bookmark!) != root.parent.path)) {
        return null;
      }
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          Directory(await root.resolveSymbolicLinks()).uri != root.uri) {
        return null;
      }
      final marker = File.fromUri(root.uri.resolve(_markerName));
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await marker.length() != id.length ||
          await marker.readAsString() != id) {
        return null;
      }
      return root;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> requireRoot(String id) async {
    await _pendingWrite;
    final location = (await _read()).roots[id];
    final root = location == null ? null : await _verifiedRoot(id, location);
    if (root == null) throw OfflineCacheLocationException.unavailable;
    return root;
  }

  /// Descend only through app-generated names. Reads/deletion do not create
  /// missing cache paths, and neither may traverse a link out of the cache.
  static Future<Directory?> childDirectory(
    Directory root,
    List<String> components, {
    required bool create,
    bool createRoot = false,
  }) async {
    var dir = root.absolute;
    if (create && createRoot && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (!await dir.exists()) return null;
    var expected = Directory(await dir.resolveSymbolicLinks()).uri;
    for (final name in components) {
      expected = expected.resolve('$name/');
      dir = Directory.fromUri(dir.uri.resolve('$name/'));
      final type = await FileSystemEntity.type(dir.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        await dir.create();
      } else if (type != FileSystemEntityType.directory) {
        throw OfflineCacheLocationException.unavailable;
      }
      if (Directory(await dir.resolveSymbolicLinks()).uri != expected) {
        throw OfflineCacheLocationException.unavailable;
      }
    }
    return dir;
  }
}
