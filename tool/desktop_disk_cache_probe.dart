// Real libmpv + loopback HTTP probe. No account, external service or user media.
import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:focubili/services/desktop_disk_cache_session.dart';
import 'package:focubili/services/media_cache_service.dart';

import '../integration_test/media_fixture.dart';

class _ProbeStorage extends WindowsMediaCacheService {
  _ProbeStorage(Directory root)
    : super(
        directoryLoader: () async => root,
        playbackActiveLoader: () => false,
      );
  @override
  Future<int> loadCapacityBytes() async => 256 * 1024;
}

Future<void> _waitFor(Future<bool> Function() ready, String phase) async {
  final until = DateTime.now().add(const Duration(seconds: 12));
  while (DateTime.now().isBefore(until)) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Disk cache probe timed out: $phase');
}

Future<void> verifyDesktopDiskCache() async {
  final root = await Directory.systemTemp.createTemp(
    'focubili_mpv_cache_probe_',
  );
  final storage = _ProbeStorage(
    Directory('${root.path}/${WindowsMediaCacheService.cacheDirectoryName}'),
  );
  final bytes = base64Decode(appleSmokeVideoBase64);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  server.listen((request) async {
    requests++;
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = range == null ? 0 : int.parse(range[1]!);
    final end = range == null || range[2]!.isEmpty
        ? bytes.length - 1
        : int.parse(range[2]!);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentType = ContentType('video', 'mp4');
    if (start >= bytes.length || end >= bytes.length || start > end) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    } else {
      if (range != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
      }
      request.response.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        request.response.add(bytes.sublist(start, end + 1));
      }
    }
    await request.response.close();
  });
  final player = Player();
  final native = player.platform as NativePlayer;
  final cache = DesktopDiskCacheSession(
    writeProperty: native.setProperty,
    readProperty: native.getProperty,
    storage: storage,
    pollInterval: const Duration(
      days: 1,
    ), // Deterministic manual threshold sample.
  );
  try {
    await native.setProperty('ao', 'null');
    await cache.configure();
    if (await native.getProperty('cache-on-disk') != 'yes') {
      throw StateError(
        'Native disk configuration failed: ${WindowsMediaCacheRuntime.bufferMessage}',
      );
    }
    final url = 'http://127.0.0.1:${server.port}/fixture.mp4';
    await player.open(Media(url));
    await _waitFor(
      () async => player.state.position.inMilliseconds >= 400,
      'decode',
    );
    await player.pause();
    await player.setAudioTrack(AudioTrack.uri('$url?external-audio=1'));
    Future<List<File>> packets() async =>
        (await Directory(cache.directoryPath!).list().toList())
            .whereType<File>()
            .where((file) => !file.path.endsWith('owner.lock'))
            .toList();
    await _waitFor(
      () async => (await packets()).length >= 2,
      'video and external audio packet files',
    );
    await player.seek(const Duration(seconds: 2));
    await _waitFor(
      () async => (player.state.position.inMilliseconds - 2000).abs() < 600,
      'forward seek',
    );
    final beforeSeek = requests;
    await player.seek(const Duration(milliseconds: 500));
    await _waitFor(
      () async => player.state.position.inMilliseconds < 1100,
      'cached rewind',
    );
    if (requests != beforeSeek) {
      throw StateError('Fixture rewind fetched more HTTP data');
    }
    final packetFiles = await packets();
    final packetBytes = await storage.diskBytes();
    if (packetBytes <= 0) throw StateError('No real packet data was written');
    // A small, real test-owned file crosses the aggregate threshold without
    // requiring a large media fixture. This is not a video traffic benchmark.
    final padding = await File(
      '${cache.directoryPath}/probe-threshold-padding',
    ).writeAsBytes(List.filled(256 * 1024, 0));
    final measuredAtThreshold = await storage.diskBytes();
    await cache.sample();
    if (!cache.writesSuspended ||
        await native.getProperty('cache-on-disk') != 'no') {
      throw StateError('Native threshold setting was not accepted');
    }
    for (final packet in packetFiles) {
      if (!await packet.exists()) {
        throw StateError('Active packet file was deleted');
      }
    }
    await padding.delete();
    await player.seek(const Duration(seconds: 1));
    await _waitFor(
      () async => (player.state.position.inMilliseconds - 1000).abs() < 250,
      'seek after threshold',
    );
    if (requests != beforeSeek) {
      throw StateError('Retained fixture packets were not reused');
    }
    stdout.writeln(
      'DESKTOP_DISK_CACHE_RESULT: ${jsonEncode({'nativeVersion': await native.getProperty('mpv-version'), 'packetFiles': packetFiles.length, 'packetBytes': packetBytes, 'thresholdBytes': 256 * 1024, 'testPaddingBytes': 256 * 1024, 'measuredBytesAtThreshold': measuredAtThreshold, 'httpRequests': requests, 'rewindAdditionalRequests': requests - beforeSeek, 'cacheOnDiskAfterThreshold': await native.getProperty('cache-on-disk'), 'activeFilesRetained': true})}',
    );
  } finally {
    await cache.stopMonitoring();
    await player.dispose();
    await cache.releaseAfterPlayerClosed();
    await server.close(force: true);
    if (cache.directoryPath != null &&
        await Directory(cache.directoryPath!).exists()) {
      throw StateError('Closed media session was not reclaimed');
    }
    await root.delete(recursive: true);
  }
  stdout.writeln('DESKTOP_DISK_CACHE_PROBE_PASSED');
}
