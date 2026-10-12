import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/subscription_history.dart';

abstract interface class SubscriptionHistoryStore {
  Future<SubscriptionHistoryBatch?> read(String job, int batch);
  Future<void> write(String job, int batch, SubscriptionHistoryBatch value);
}

/// One flushed immutable page per file. The authoritative task cursor is
/// committed afterwards; an interrupted commit reuses the same saved page.
class FileSubscriptionHistoryStore implements SubscriptionHistoryStore {
  FileSubscriptionHistoryStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<File> _file(String job, int batch) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(job) || batch < 0) {
      throw const FormatException('Invalid history location');
    }
    final root = await _directory();
    return File('${root.path}/subscription-history/$job/$batch/page.json');
  }

  @override
  Future<SubscriptionHistoryBatch?> read(String job, int batch) async {
    final file = await _file(job, batch);
    if (!await file.exists()) return null;
    return SubscriptionHistoryBatch.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
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

class MemorySubscriptionHistoryStore implements SubscriptionHistoryStore {
  final _pages = <String, SubscriptionHistoryBatch>{};
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
