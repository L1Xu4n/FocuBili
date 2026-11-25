import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/subscription_history.dart';

abstract interface class SubscriptionHistoryStore {
  Future<SubscriptionHistoryBatch?> read(String job, int batch);
  Future<void> write(String job, int batch, SubscriptionHistoryBatch value);
}

/// Optional capability for stores that can reclaim all pages belonging to a job.
abstract interface class SubscriptionHistoryReclaimer {
  Future<void> deleteJob(String job);
}

/// One flushed immutable page per file. The authoritative task cursor is
/// committed afterwards; an interrupted commit reuses the same saved page.
class FileSubscriptionHistoryStore
    implements SubscriptionHistoryStore, SubscriptionHistoryReclaimer {
  FileSubscriptionHistoryStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;

  /// Resolves an opaque job ID within the history root.
  Future<Directory> _jobDirectory(String job) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(job)) {
      throw const FormatException('Invalid history location');
    }
    final root = await _directory();
    return Directory('${root.path}/subscription-history/$job');
  }

  /// Resolves the page file for a validated job and batch number.
  Future<File> _file(String job, int batch) async {
    if (batch < 0) throw const FormatException('Invalid history location');
    final directory = await _jobDirectory(job);
    return File('${directory.path}/$batch/page.json');
  }

  /// Deletes a real job directory and refuses redirected history roots.
  @override
  Future<void> deleteJob(String job) async {
    final directory = await _jobDirectory(job);
    if (await FileSystemEntity.type(
          directory.parent.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return;
    }
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<SubscriptionHistoryBatch?> read(String job, int batch) async {
    final file = await _file(job, batch);
    if (!await file.exists()) return null;
    return SubscriptionHistoryBatch.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  /// Export validates raw optional fields before the browsing parser can
  /// normalize malformed values or discard a future item's public fields.
  Future<SubscriptionHistoryBatch?> readForExport(String job, int batch) async {
    final file = await _file(job, batch);
    if (!await file.exists()) return null;
    final values =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    const fields = {
      'bvid',
      'title',
      'coverUrl',
      'sources',
      'discoveredAt',
      'publishedAt',
      'readAt',
      'collectionAdded',
    };
    for (final raw in values['items'] as List) {
      if (raw is! Map ||
          raw.keys.any((key) => !fields.contains(key)) ||
          (raw['collectionAdded'] != null && raw['collectionAdded'] is! bool)) {
        throw const FormatException('Invalid subscription history item');
      }
    }
    return SubscriptionHistoryBatch.fromJson(values);
  }

  @override
  Future<void> write(
    String job,
    int batch,
    SubscriptionHistoryBatch value,
  ) async {
    final file = await _file(job, batch);
    if (await file.exists()) {
      return; // immutable, read back before cursor commit
    }
    await file.parent.parent.create(recursive: true);
    final temporary = await file.parent.parent.createTemp('$batch.stage-');
    try {
      await File(
        '${temporary.path}/page.json',
      ).writeAsString(jsonEncode(value.toJson()), flush: true);
      // Publishing a non-empty directory is atomic and cannot replace another
      // non-empty directory, including across isolates/processes. A stale lease
      // holder must never overwrite the page a newer owner already committed.
      try {
        await temporary.rename(file.parent.path);
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }
}

class MemorySubscriptionHistoryStore
    implements SubscriptionHistoryStore, SubscriptionHistoryReclaimer {
  final _pages = <String, SubscriptionHistoryBatch>{};

  /// Clears only the pages keyed to this job.
  @override
  Future<void> deleteJob(String job) async {
    _pages.removeWhere((key, _) => key.startsWith('$job:'));
  }

  @override
  Future<SubscriptionHistoryBatch?> read(String job, int batch) async =>
      _pages['$job:$batch'];
  @override
  Future<void> write(
    String job,
    int batch,
    SubscriptionHistoryBatch value,
  ) async {
    _pages.putIfAbsent('$job:$batch', () => value);
  }
}
