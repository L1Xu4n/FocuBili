import 'dart:convert';
import 'dart:io';

import 'package:focubili/services/cache_file_lock.dart';

// A Dart VM peer owns actual OS file locks; no Flutter engine or player is
// needed. Accept only the test's dedicated temporary directory namespace.
Future<void> main(List<String> arguments) async {
  final root = Directory(arguments.single).absolute;
  if (!root.parent.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last
          .startsWith('focubili_media_peer_') ||
      root.uri.pathSegments.where((segment) => segment.isNotEmpty).last !=
          'media_kit_video_cache') {
    throw ArgumentError('Expected the synthetic media-cache test directory');
  }
  final directoryLock = await CacheFileLock.acquire(
    '${root.path}/sessions.lock',
  );
  late CacheFileLock owner;
  late Directory session;
  try {
    session = await Directory('${root.path}/session_$pid').create();
    owner = await CacheFileLock.acquire('${session.path}/owner.lock');
    await File('${session.path}/packet').writeAsBytes([1, 2, 3]);
  } finally {
    await directoryLock.release();
  }
  stdout.writeln(jsonEncode({'session': session.path}));
  final command = await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  if (command == 'exit') exit(0); // OS must release an abandoned owner's lock.
  if (command != 'release') throw ArgumentError('Unknown test command');
  await owner.release();
  stdout.writeln('released');
}
