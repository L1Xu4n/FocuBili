import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/media_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Peer {
  _Peer(this.process, this.messages, this.directory, this.errors);
  final Process process;
  final StreamIterator<String> messages;
  final Directory directory;
  final Future<String> errors;

  Future<void> close(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(await errors, isEmpty);
  }
}

String _dartExecutable() {
  final config = File('.dart_tool/package_config.json').absolute;
  final document =
      jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = document['packages'] as List<dynamic>;
  final flutter = packages.cast<Map<String, dynamic>>().singleWhere(
    (entry) => entry['name'] == 'flutter',
  );
  final packageRoot = Directory.fromUri(
    config.uri.resolve(flutter['rootUri'] as String),
  );
  final sdk = packageRoot.parent.parent;
  return '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
}

Future<_Peer> _startPeer(Directory cache) async {
  final process = await Process.start(_dartExecutable(), [
    '--packages=.dart_tool/package_config.json',
    'test/fixtures/media_cache_lock_peer.dart',
    cache.path,
  ]);
  final errors = process.stderr.transform(utf8.decoder).join();
  final messages = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 20)),
      isTrue,
    );
    final report = jsonDecode(messages.current) as Map<String, dynamic>;
    return _Peer(
      process,
      messages,
      Directory(report['session'] as String),
      errors,
    );
  } catch (_) {
    process.kill();
    await process.exitCode;
    await messages.cancel();
    rethrow;
  }
}

void main() {
  test(
    'three processes retain live owners and reclaim released or exited peers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'focubili_media_peer_',
      );
      final cache = await Directory(
        '${root.path}/${WindowsMediaCacheService.cacheDirectoryName}',
      ).create();
      final peers = <_Peer>[];
      try {
        for (var index = 0; index < 3; index++) {
          peers.add(await _startPeer(cache));
        }
        final service = WindowsMediaCacheService(
          directoryLoader: () async => cache,
          playbackActiveLoader: () => false,
        );
        final legacy = await File(
          '${cache.path}/legacy-packet',
        ).writeAsBytes([8]);
        final abandoned = await Directory(
          '${cache.path}/session_abandoned',
        ).create();
        await File('${abandoned.path}/old-packet').writeAsBytes([9]);
        await service.maintain();
        expect(abandoned.existsSync(), isFalse);
        expect(legacy.existsSync(), isTrue);
        expect((await service.loadStatus()).isPlaybackActive, isTrue);
        for (final peer in peers) {
          expect(await File('${peer.directory.path}/packet').readAsBytes(), [
            1,
            2,
            3,
          ]);
        }
        await expectLater(
          service.clearCache(),
          throwsA(isA<MediaCacheException>()),
        );

        await peers[0].close('release');
        await service.maintain();
        expect(peers[0].directory.existsSync(), isFalse);
        expect(peers[1].directory.existsSync(), isTrue);
        expect(peers[2].directory.existsSync(), isTrue);
        expect(legacy.existsSync(), isTrue);

        await peers[1].close('exit');
        await service.maintain();
        expect(peers[1].directory.existsSync(), isFalse);
        expect(peers[2].directory.existsSync(), isTrue);
        expect(legacy.existsSync(), isTrue);

        await peers[2].close('release');
        await service.maintain();
        expect(peers[2].directory.existsSync(), isFalse);
        expect(legacy.existsSync(), isFalse);
        expect((await service.loadStatus()).isPlaybackActive, isFalse);
      } finally {
        for (final peer in peers) {
          peer.process.kill();
          await peer.process.exitCode;
          await peer.messages.cancel();
        }
        await root.delete(recursive: true);
      }
    },
  );
}
