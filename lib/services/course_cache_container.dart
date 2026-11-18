import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Secondary check on actual MP4/DASH bytes, not an encryption detector for
/// arbitrary formats. Never attempts decryption, fetching keys or removing boxes.
class CourseCacheContainer {
  static final _protectedMarker = RegExp(r'pssh|encv|enca|sinf|tenc|senc');
  static const _metadataLimit = 16 * 1024 * 1024;

  /// Reads bounded container metadata only. Skip (do not scan) the media payload.
  /// Missing, malformed, encrypted and unrecognized files are not playable.
  static Future<bool> clearMp4(File file, void Function() check) async {
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
          if (kind == 'moov') movie = true;
        }
        offset += size;
      }
      return brand && movie && payload;
    } finally {
      await input.close();
    }
  }
}
