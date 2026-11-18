import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Secondary check on actual MP4/DASH bytes, not an encryption detector for
/// arbitrary formats. Never attempts decryption, fetching keys or removing boxes.
class CourseCacheContainer {
  static final _protectedMarker = RegExp(r'pssh|encv|enca|sinf|tenc|senc');
  static const _metadataLimit = 16 * 1024 * 1024;

  // Handler kind belongs at moov/trak/mdia/hdlr, not in arbitrary metadata
  // (or a filename). Only visit genuine, bounds-checked child boxes.
  static Set<String>? _handlers(Uint8List movie) {
    final data = ByteData.sublistView(movie);
    final found = <String>{};
    var count = 0;
    bool walk(int start, int end, int depth) {
      var at = start;
      while (at < end) {
        if (++count > 100000 || end - at < 8) return false;
        var size = data.getUint32(at), header = 8;
        final kind = latin1.decode(
          Uint8List.sublistView(movie, at + 4, at + 8),
        );
        if (size == 1) {
          if (end - at < 16) return false;
          size = data.getUint64(at + 8);
          header = 16;
        } else if (size == 0) {
          size = end - at;
        }
        if (size < header || size > end - at) return false;
        final body = at + header, limit = at + size;
        if (depth == 0 && kind == 'trak' || depth == 1 && kind == 'mdia') {
          if (!walk(body, limit, depth + 1)) return false;
        } else if (depth == 2 && kind == 'hdlr') {
          if (limit - body < 12) return false;
          found.add(
            latin1.decode(Uint8List.sublistView(movie, body + 8, body + 12)),
          );
        }
        at = limit;
      }
      return true;
    }

    return walk(0, movie.length, 0) ? found : null;
  }

  /// Reads bounded container metadata only. Skip (do not scan) the media payload.
  /// Missing, malformed, encrypted and unrecognized files are not playable.
  static Future<bool> clearMp4(
    File file,
    void Function() check, {
    required bool video,
    required bool audio,
  }) async {
    final tracks = <String>{};
    final input = await file.open();
    try {
      final length = await input.length();
      var offset = 0, boxes = 0, metadata = 0;
      var brand = false, movie = false, payload = false;
      while (offset < length) {
        check();
        if (++boxes > 100000 || length - offset < 8) return false;
        await input.setPosition(offset);
        final header = await input.read(8);
        if (header.length != 8) return false;
        final kind = latin1.decode(header.sublist(4, 8));
        var size = ByteData.sublistView(header).getUint32(0);
        var headerLength = 8;
        if (size == 1) {
          final extended = await input.read(8);
          if (extended.length != 8) return false;
          size = ByteData.sublistView(extended).getUint64(0);
          headerLength += 8;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < headerLength || size > length - offset) return false;
        final dataLength = size - headerLength;
        if (_protectedMarker.hasMatch(kind)) return false;
        if (kind == 'ftyp' && dataLength >= 8) brand = true;
        if (kind == 'mdat' && dataLength > 0) payload = true;
        if (kind == 'moov' || kind == 'moof') {
          if (dataLength < 8 ||
              dataLength > _metadataLimit ||
              (metadata += dataLength) > 64 * 1024 * 1024) {
            return false;
          }
          final block = await input.read(dataLength);
          if (block.length != dataLength ||
              _protectedMarker.hasMatch(latin1.decode(block))) {
            return false;
          }
          if (kind == 'moov') {
            final roles = _handlers(block);
            if (roles == null) return false;
            tracks.addAll(roles);
            movie = true;
          }
        }
        offset += size;
      }
      return brand &&
          movie &&
          payload &&
          (!video || tracks.contains('vide')) &&
          (!audio || tracks.contains('soun'));
    } finally {
      await input.close();
    }
  }
}
