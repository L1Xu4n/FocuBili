// Real libmpv + loopback HTTP probe. No account, external service or user media.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:focubili/services/desktop_disk_cache_session.dart';
import 'package:focubili/services/media_cache_service.dart';

import '../integration_test/media_fixture.dart';

class _ProbeStorage extends WindowsMediaCacheService {
  /// Uses a synthetic cache location and deterministic threshold.
  _ProbeStorage(Directory root, {this.capacity = 256 * 1024})
    : super(
        directoryLoader: () async => root,
        playbackActiveLoader: () => false,
      );
  @override
  /// Returns the probe's threshold without depending on user settings.
  Future<int> loadCapacityBytes() async => capacity;
  final int capacity;
}

/// Polls for a native playback transition and reports the stalled phase.
Future<void> _waitFor(Future<bool> Function() ready, String phase) async {
  final until = DateTime.now().add(const Duration(seconds: 12));
  while (DateTime.now().isBefore(until)) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Disk cache probe timed out: $phase');
}

/// Verifies packet lifetime, seek reuse, and the long-media traffic cap.
Future<void> verifyDesktopDiskCache() async {
  final root = await Directory.systemTemp.createTemp(
    'focubili_mpv_cache_probe_',
  );
  final storage = _ProbeStorage(
    Directory('${root.path}/${WindowsMediaCacheService.cacheDirectoryName}'),
  );
  final bytes = base64Decode(appleSmokeVideoBase64);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var serverClosed = false;
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
    readProperty: (name) async {
      final actual = await native.getProperty(name);
      // Only synthetic cache options/temporary paths; never account data.
      stdout.writeln('DESKTOP_DISK_PROPERTY: $name=$actual');
      return actual;
    },
    storage: storage,
    pollInterval: const Duration(
      days: 1,
    ), // Deterministic manual threshold sample.
  );
  try {
    await native.setProperty('ao', 'null');
    await cache.configure();
    await cache.applyPlaybackPolicy(diskAllowed: true, preferDataSaving: false);
    if (await native.getProperty('cache-on-disk') != 'yes') {
      throw StateError(
        'Native disk configuration failed: ${cache.configurationError}; '
        '${WindowsMediaCacheRuntime.bufferMessage}',
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

    /// Lists the active media packet files separately from the lease lock.
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
    // Take the only media origin offline. Property readback/file existence
    // alone cannot prove that old packets remain usable after disabling disk.
    await server.close(force: true);
    serverClosed = true;
    await player.seek(const Duration(milliseconds: 2500));
    await _waitFor(
      () async => (player.state.position.inMilliseconds - 2500).abs() < 250,
      'post-threshold forward seek with origin offline',
    );
    await player.seek(const Duration(milliseconds: 500));
    await _waitFor(
      () async => (player.state.position.inMilliseconds - 500).abs() < 250,
      'post-threshold rewind with origin offline',
    );
    await player.play();
    await _waitFor(
      () async => player.state.position.inMilliseconds >= 1250,
      'decode and advance after offline rewind',
    );
    await player.pause();
    if (requests != beforeSeek) {
      throw StateError('Retained fixture packets were not reused');
    }
    stdout.writeln(
      'DESKTOP_DISK_CACHE_RESULT: ${jsonEncode({'nativeVersion': await native.getProperty('mpv-version'), 'packetFiles': packetFiles.length, 'packetBytes': packetBytes, 'thresholdBytes': 256 * 1024, 'testPaddingBytes': 256 * 1024, 'measuredBytesAtThreshold': measuredAtThreshold, 'httpRequests': requests, 'rewindAdditionalRequests': requests - beforeSeek, 'cacheOnDiskAfterThreshold': await native.getProperty('cache-on-disk'), 'activeFilesRetained': true, 'originClosedBeforePostThresholdSeek': true, 'postThresholdRewindFromMs': 2500, 'postThresholdRewindToMs': 500, 'postRewindPlaybackPositionMs': player.state.position.inMilliseconds})}',
    );
  } finally {
    await cache.stopMonitoring();
    await player.dispose();
    await cache.releaseAfterPlayerClosed();
    if (!serverClosed) await server.close(force: true);
    if (cache.directoryPath != null &&
        await Directory(cache.directoryPath!).exists()) {
      throw StateError('Closed media session was not reclaimed');
    }
    await root.delete(recursive: true);
  }
  await verifyPausedReadAheadPlateau();
  stdout.writeln('DESKTOP_DISK_CACHE_PROBE_PASSED');
}

/// Builds a fast-start MP4 and PCM WAV with 180 seconds of distinct tracks.
({Uint8List video, Uint8List audio}) _makeLongFixture() {
  const duration = 180;
  const fps = 24;
  const frames = duration * fps;
  const sampleRate = 16000;
  const audioBytes = duration * sampleRate * 2;

  /// Encodes MP4 and WAV integer fields in their respective byte orders.
  Uint8List words(List<int> values, {Endian endian = Endian.big}) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i], endian);
    }
    return data.buffer.asUint8List();
  }

  /// Writes a RIFF chunk header whose payload can be appended separately.
  Uint8List header(String tag, int bytes) => Uint8List.fromList([
    ...ascii.encode(tag),
    ...words([bytes], endian: Endian.little),
  ]);

  /// Finds a named box among the children of the trusted synthetic MP4 fixture.
  Uint8List child(Uint8List bytes, String tag, {int start = 8}) {
    final data = ByteData.sublistView(bytes);
    for (var offset = start; offset + 8 <= bytes.length;) {
      final size = data.getUint32(offset);
      if (size < 8 || offset + size > bytes.length) break;
      if (ascii.decode(bytes.sublist(offset + 4, offset + 8)) == tag) {
        return Uint8List.sublistView(bytes, offset, offset + size);
      }
      offset += size;
    }
    throw StateError('Synthetic MP4 is missing $tag');
  }

  /// Assembles an MP4 box from its content.
  Uint8List box(String tag, List<Uint8List> contents) {
    final size = contents.fold<int>(8, (total, item) => total + item.length);
    return Uint8List.fromList([
      ...words([size]),
      ...ascii.encode(tag),
      for (final item in contents) ...item,
    ]);
  }

  /// Patches timestamp fields while preserving the fixture's other metadata.
  Uint8List patch(Uint8List source, Map<int, int> fields) {
    final result = Uint8List.fromList(source);
    final data = ByteData.sublistView(result);
    fields.forEach(data.setUint32);
    return result;
  }

  final original = base64Decode(appleSmokeVideoBase64);
  final ftyp = child(original, 'ftyp', start: 0);
  final movie = child(original, 'moov', start: 0);
  final track = child(movie, 'trak');
  final media = child(track, 'mdia');
  final info = child(media, 'minf');
  final table = child(info, 'stbl');
  final sampleSize = ByteData.sublistView(child(table, 'stsz')).getUint32(20);
  final sampleOffset = ByteData.sublistView(child(table, 'stco')).getUint32(16);
  final frame = Uint8List.sublistView(
    original,
    sampleOffset,
    sampleOffset + sampleSize,
  );

  /// Indexes repeated independent AVC frames so mpv can open without scanning EOF.
  Uint8List movieBox(int chunkOffset) => box('moov', [
    patch(child(movie, 'mvhd'), {24: duration * 1000}),
    box('trak', [
      patch(child(track, 'tkhd'), {28: duration * 1000}),
      box('mdia', [
        patch(child(media, 'mdhd'), {20: fps * 1000, 24: frames * 1000}),
        child(media, 'hdlr'),
        box('minf', [
          child(info, 'vmhd'),
          child(info, 'dinf'),
          box('stbl', [
            child(table, 'stsd'),
            box('stts', [
              words([0, 1, frames, 1000]),
            ]),
            box('stsc', [
              words([0, 1, 1, frames, 1]),
            ]),
            box('stsz', [
              words([0, sampleSize, frames]),
            ]),
            box('stco', [
              words([0, 1, chunkOffset]),
            ]),
          ]),
        ]),
      ]),
    ]),
  ]);
  final chunkOffset = ftyp.length + movieBox(0).length + 8;
  final video = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(movieBox(chunkOffset))
    ..add(words([8 + sampleSize * frames]))
    ..add(ascii.encode('mdat'));
  for (var i = 0; i < frames; i++) {
    video.add(frame);
  }
  final audio = BytesBuilder(copy: false)
    ..add(header('RIFF', audioBytes + 36))
    ..add(ascii.encode('WAVE'))
    ..add(header('fmt ', 16))
    ..add(
      words([
        1 | (1 << 16),
        sampleRate,
        sampleRate * 2,
        2 | (16 << 16),
      ], endian: Endian.little),
    )
    ..add(header('data', audioBytes))
    ..add(Uint8List(audioBytes));
  return (video: video.takeBytes(), audio: audio.takeBytes());
}

/// Confirms paused playback stops pulling both tracks well before reading EOF.
Future<void> verifyPausedReadAheadPlateau() async {
  final fixture = _makeLongFixture();
  final root = await Directory.systemTemp.createTemp('focubili_mpv_traffic_');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sent = [0, 0];
  final reachedEof = [false, false];
  final rangePattern = RegExp(r'^bytes=(\d+)-(\d*)$');
  server.listen((request) async {
    final index = request.uri.path == '/audio.wav' ? 1 : 0;
    final bytes = index == 0 ? fixture.video : fixture.audio;
    final response = request.response;
    final done = response.done.then<void>((_) {}, onError: (Object _) {});
    final range = rangePattern.firstMatch(
      request.headers.value(HttpHeaders.rangeHeader) ?? '',
    );
    final start = range == null ? 0 : int.parse(range[1]!);
    final end = range == null || range[2]!.isEmpty
        ? bytes.length - 1
        : int.parse(range[2]!).clamp(0, bytes.length - 1);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.contentType = index == 0
        ? ContentType('video', 'mp4')
        : ContentType('audio', 'wav');
    try {
      if (start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
      } else {
        response.contentLength = end - start + 1;
        if (range != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        if (request.method != 'HEAD') {
          for (var offset = start; offset <= end;) {
            final next = (offset + 64 * 1024).clamp(offset, end + 1);
            response.add(Uint8List.sublistView(bytes, offset, next));
            await response.flush();
            // Each flush counts separately, including overlapping Range requests.
            sent[index] += next - offset;
            offset = next;
            if (offset == bytes.length) reachedEof[index] = true;
          }
        }
      }
      await response.close();
    } on IOException {
      // mpv may cancel an in-flight range while seeking or closing the media.
    } finally {
      await done;
    }
  });
  final player = Player();
  final native = player.platform as NativePlayer;
  final cache = DesktopDiskCacheSession(
    writeProperty: native.setProperty,
    readProperty: native.getProperty,
    storage: _ProbeStorage(
      Directory('${root.path}/${WindowsMediaCacheService.cacheDirectoryName}'),
      capacity: 200 * 1024 * 1024,
    ),
  );
  try {
    await native.setProperty('ao', 'null');
    // The headless player has no VideoController to enable video decoding.
    await native.setProperty('vo', 'null');
    await native.setProperty('vid', 'auto');
    await cache.configure();
    await cache.applyPlaybackPolicy(diskAllowed: true, preferDataSaving: false);
    if (cache.configurationError != null) throw cache.configurationError!;
    final origin = 'http://127.0.0.1:${server.port}';
    await player.open(Media('$origin/video.mp4'));
    await _waitFor(
      () async => player.state.position.inMilliseconds >= 400,
      'long video decode',
    );
    await player.pause();
    await player.setAudioTrack(AudioTrack.uri('$origin/audio.wav'));
    await player.play();
    await _waitFor(
      () async =>
          player.state.position >= const Duration(seconds: 1) &&
          (player.state.audioParams.channelCount ?? 0) > 0,
      'long DASH decode',
    );
    await player.pause();
    var lastTotal = -1;
    var stableSamples = 0;
    await _waitFor(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
      final total = sent[0] + sent[1];
      if (reachedEof.any((eof) => eof) ||
          sent[0] >= fixture.video.length ||
          sent[1] >= fixture.audio.length) {
        throw StateError('Paused demuxer fetched an entire track: $sent');
      }
      stableSamples = total == lastTotal ? stableSamples + 1 : 0;
      lastTotal = total;
      return sent.every((count) => count > 0) && stableSamples >= 3;
    }, 'paused traffic plateau');
    stdout.writeln(
      'DESKTOP_DISK_TRAFFIC_RESULT: ${jsonEncode({'nativeVersion': await native.getProperty('mpv-version'), 'videoSentBytes': sent[0], 'audioSentBytes': sent[1], 'videoLength': fixture.video.length, 'audioLength': fixture.audio.length, 'stableSamples': stableSamples})}',
    );
  } finally {
    await server.close(force: true);
    await cache.stopMonitoring();
    await player.dispose();
    await cache.releaseAfterPlayerClosed();
    await root.delete(recursive: true);
  }
}
