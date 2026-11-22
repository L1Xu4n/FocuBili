import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads this application's classic ZIP export without ever extracting paths.
///
/// Central and local records must agree. Size limits are applied before and
/// during inflation, so a forged advertised size cannot cause unbounded output.
final class UnifiedRestoreZip {
  UnifiedRestoreZip(Uint8List bytes) : _bytes = bytes {
    if (bytes.length < 22 || bytes.length > maximumBytes) _invalid();
    _view = ByteData.sublistView(bytes);
    _readIndex();
  }

  static const maximumBytes = 128 * 1024 * 1024;
  static const _maximumExpanded = 256 * 1024 * 1024;
  static const _maximumEntry = 24 * 1024 * 1024;
  static const _maximumEntries = 10000;
  final Uint8List _bytes;
  late final ByteData _view;
  final _entries = <String, _Entry>{};
  final _spans = <(int, int)>[];

  bool contains(String name) => _entries.containsKey(name);

  static Never _invalid() => throw const FormatException('Invalid backup ZIP');

  int _u16(int at) => _view.getUint16(at, Endian.little);
  int _u32(int at) => _view.getUint32(at, Endian.little);

  static bool safePath(String name) =>
      name.length <= 400 &&
      !name
          .split('/')
          .any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(part),
          );

  void _readIndex() {
    var end = _bytes.length - 22;
    final minimum = (end - 65535).clamp(0, end);
    while (end >= minimum &&
        (_u32(end) != 0x06054b50 ||
            end + 22 + _u16(end + 20) != _bytes.length)) {
      end--;
    }
    if (end < minimum || _u16(end + 4) != 0 || _u16(end + 6) != 0) {
      _invalid();
    }
    final count = _u16(end + 10);
    final centralSize = _u32(end + 12);
    final centralStart = _u32(end + 16);
    if (count == 0 ||
        count > _maximumEntries ||
        _u16(end + 8) != count ||
        centralStart + centralSize != end) {
      _invalid();
    }
    var central = centralStart;
    var expanded = 0;
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      if (central + 46 > end || _u32(central) != 0x02014b50) _invalid();
      final flags = _u16(central + 8);
      final method = _u16(central + 10);
      final crc = _u32(central + 16);
      final compressed = _u32(central + 20);
      final size = _u32(central + 24);
      final nameLength = _u16(central + 28);
      final extraLength = _u16(central + 30);
      final commentLength = _u16(central + 32);
      final mode = (_u32(central + 38) >> 16) & 0xf000;
      final local = _u32(central + 42);
      final next = central + 46 + nameLength + extraLength + commentLength;
      if ((flags & ~0x080e) != 0 ||
          (method != 0 && method != 8) ||
          (method == 0 && compressed != size) ||
          _u16(central + 34) != 0 ||
          (mode != 0 && mode != 0x8000) ||
          (_u32(central + 38) & 0x10) != 0 ||
          size > _maximumEntry ||
          next > end ||
          local + 30 > centralStart ||
          _u32(local) != 0x04034b50 ||
          _u16(local + 6) != flags ||
          _u16(local + 8) != method ||
          _u16(local + 26) != nameLength) {
        _invalid();
      }
      final descriptor = (flags & 8) != 0;
      if (!descriptor &&
          (_u32(local + 14) != crc ||
              _u32(local + 18) != compressed ||
              _u32(local + 22) != size)) {
        _invalid();
      }
      final data = local + 30 + nameLength + _u16(local + 28);
      var afterData = data + compressed;
      if (afterData > centralStart) _invalid();
      if (descriptor) {
        if (afterData + 4 <= centralStart && _u32(afterData) == 0x08074b50) {
          afterData += 4;
        }
        if (afterData + 12 > centralStart ||
            _u32(afterData) != crc ||
            _u32(afterData + 4) != compressed ||
            _u32(afterData + 8) != size) {
          _invalid();
        }
        afterData += 12;
      }
      final name = utf8.decode(
        Uint8List.sublistView(_bytes, central + 46, central + 46 + nameLength),
      );
      if (!safePath(name) ||
          !names.add(name.toLowerCase()) ||
          name !=
              utf8.decode(
                Uint8List.sublistView(
                  _bytes,
                  local + 30,
                  local + 30 + nameLength,
                ),
              )) {
        _invalid();
      }
      expanded += size;
      if (expanded > _maximumExpanded) _invalid();
      _entries[name] = _Entry(data, compressed, size, method, crc);
      _spans.add((local, afterData));
      central = next;
    }
    if (central != end) _invalid();
    _spans.sort((a, b) => a.$1.compareTo(b.$1));
    var previousEnd = 0;
    for (final (start, end) in _spans) {
      if (start < previousEnd) _invalid();
      previousEnd = end;
    }
  }

  Uint8List read(String name) {
    final entry = _entries[name];
    if (entry == null) _invalid();
    try {
      final builder = _BoundedZipSink(entry.size);
      if (entry.method == 0) {
        builder.add(
          Uint8List.sublistView(
            _bytes,
            entry.offset,
            entry.offset + entry.size,
          ),
        );
      } else {
        final decoder = ZLibDecoder(raw: true).startChunkedConversion(builder);
        final end = entry.offset + entry.compressed;
        // Feed small chunks; even intermediate inflater output is limited.
        for (var i = entry.offset; i < end; i += 8192) {
          decoder.add(
            Uint8List.sublistView(_bytes, i, (i + 8192).clamp(i, end)),
          );
        }
        decoder.close();
      }
      final result = builder.bytes.takeBytes();
      if (result.length != entry.size || _crc(result) != entry.crc) _invalid();
      return result;
    } catch (_) {
      _invalid();
    }
  }

  Map<String, dynamic> object(String name) {
    final doc = jsonDecode(utf8.decode(read(name)));
    if (doc is! Map<String, dynamic>) _invalid();
    return doc;
  }

  static final _crcTable = List<int>.generate(256, (index) {
    var current = index;
    for (var i = 0; i < 8; i++) {
      current = (current >> 1) ^ ((current & 1) == 0 ? 0 : 0xedb88320);
    }
    return current;
  });

  static int _crc(List<int> bytes) {
    var crc = 0xffffffff;
    for (final value in bytes) {
      crc = _crcTable[(crc ^ value) & 0xff] ^ (crc >> 8);
    }
    return crc ^ 0xffffffff;
  }
}

final class _BoundedZipSink implements Sink<List<int>> {
  _BoundedZipSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) UnifiedRestoreZip._invalid();
    bytes.add(data);
  }

  @override
  void close() {}
}

final class _Entry {
  const _Entry(this.offset, this.compressed, this.size, this.method, this.crc);
  final int offset, compressed, size, method, crc;
}
