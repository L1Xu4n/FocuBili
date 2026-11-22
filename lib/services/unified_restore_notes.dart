import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import '../models/video_note.dart';
import 'unified_restore_zip.dart';
import 'video_note_service.dart';

final class UnifiedRestoreNotesPlan {
  const UnifiedRestoreNotesPlan._(
    this._notes,
    this._frames,
    this.missingFrames,
  );
  final List<VideoNote> _notes;
  final Map<String, List<_Frame>> _frames;
  final int missingFrames;
  int get count => _notes.length;
}

final class UnifiedRestoreNotes {
  UnifiedRestoreNotes(this.service, {Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final VideoNoteService service;
  final Future<Directory> Function() _root;

  static Never _invalid() => throw const FormatException('Invalid notes data');

  static Future<UnifiedRestoreNotesPlan> inspect(UnifiedRestoreZip zip) async {
    const emptyPath = 'notes/notes.json';
    const notesPath = 'notes/focubili_notes.json';
    if (zip.contains(emptyPath) == zip.contains(notesPath)) _invalid();
    if (zip.contains(emptyPath)) {
      final legacy = zip.object(emptyPath);
      if (legacy.length != 1 ||
          legacy['notes'] is! List ||
          (legacy['notes'] as List).isNotEmpty) {
        _invalid();
      }
      return const UnifiedRestoreNotesPlan._([], {}, 0);
    }
    final doc = zip.object(notesPath);
    final rows = doc['notes'];
    if (doc['format'] != 'focubili.video_notes' ||
        doc['version'] != 2 ||
        rows is! List ||
        rows.length > VideoNoteService.maximumEntries) {
      _invalid();
    }
    final notes = <VideoNote>[];
    final frames = <String, List<_Frame>>{};
    final used = <String>{};
    var missing = 0;
    for (final raw in rows) {
      if (raw is! Map<String, dynamic> ||
          raw['partCid'] is! int ||
          raw['partPageNumber'] is! int ||
          !_validPosition(raw['positionMs']) ||
          raw['id'] is! String ||
          (raw['id'] as String).length > 512 ||
          raw['bvid'] is! String ||
          !RegExp(
            r'^(BV[0-9A-Za-z]{10}|cheese:ss[1-9][0-9]*)$',
          ).hasMatch(raw['bvid'] as String)) {
        _invalid();
      }
      final note = VideoNote.tryParse({
        ...raw,
        'framePath': null,
        'frames': [],
        'videoCoverUrl': _cover(raw['videoCoverUrl']),
      });
      if (note == null || frames.containsKey(note.id)) _invalid();
      final rawFrames = raw['frames'];
      if (rawFrames is! List ||
          (raw['framePath'] != null && raw['framePath'] is! String)) {
        _invalid();
      }
      final noteFrames = <_Frame>[];
      for (var i = 0; i < rawFrames.length; i++) {
        final frame = rawFrames[i];
        if (frame is! Map || !_validPosition(frame['positionMs'])) _invalid();
        final path = frame['path'];
        if (i == 0 && raw['framePath'] != path) _invalid();
        if (path == null && frame['unavailable'] == true) {
          missing++;
          continue;
        }
        if (path is! String ||
            !RegExp(
              r'^images/[0-9]+_[A-Za-z0-9_-]+_[0-9]+\.(png|jpe?g|webp)$',
            ).hasMatch(path) ||
            frame['unavailable'] != null ||
            !used.add(path)) {
          _invalid();
        }
        final archivePath = 'notes/$path';
        final bytes = zip.contains(archivePath) ? zip.read(archivePath) : null;
        final extension = path.split('.').last;
        if (bytes == null || !await _validImage(bytes, extension)) {
          missing++;
          continue;
        }
        noteFrames.add(
          _Frame(
            bytes,
            extension,
            Duration(milliseconds: frame['positionMs'] as int),
          ),
        );
      }
      if (rawFrames.isEmpty && raw['framePath'] != null) _invalid();
      notes.add(note);
      frames[note.id] = noteFrames;
    }
    return UnifiedRestoreNotesPlan._(notes, frames, missing);
  }

  static bool _validPosition(Object? raw) =>
      raw is int && raw >= 0 && raw <= 604800000;

  static String _cover(Object? raw) {
    if (raw is! String || raw.length > 4096) return '';
    final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !(uri.host.endsWith('.hdslb.com') ||
            uri.host.endsWith('.biliimg.com'))) {
      return '';
    }
    return Uri(scheme: 'https', host: uri.host, path: uri.path).toString();
  }

  static Future<bool> _validImage(Uint8List bytes, String extension) async {
    if (bytes.length < 16 || bytes.length > 12 * 1024 * 1024) return false;
    final headerMatches = switch (extension) {
      'png' =>
        bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71,
      'jpg' || 'jpeg' => bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255,
      'webp' =>
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
            String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP',
      _ => false,
    };
    if (!headerMatches) return false;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return descriptor.width > 0 &&
          descriptor.height > 0 &&
          descriptor.width <= 8192 &&
          descriptor.height <= 8192 &&
          descriptor.width * descriptor.height <= 20000000;
    } catch (_) {
      return false;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<({int added, int kept})> apply(UnifiedRestoreNotesPlan plan) async {
    if (plan._notes.isEmpty) return (added: 0, kept: 0);
    Directory? directory;
    var index = 0;
    return service.restoreMissingNotes(
      plan._notes,
      stage: (note) async {
        final frames = <VideoNoteFrame>[];
        for (final frame in plan._frames[note.id]!) {
          if (directory == null) {
            final root = await _root();
            await root.create(recursive: true);
            directory = await root.createTemp('focubili-restored-note-frames-');
          }
          final file = File(
            '${directory!.path}${Platform.pathSeparator}${++index}.${frame.extension}',
          );
          await file.writeAsBytes(frame.bytes, flush: true);
          frames.add(VideoNoteFrame(path: file.path, position: frame.position));
        }
        return note.copyWith(frames: frames);
      },
      rollback: () async {
        if (directory != null) await directory!.delete(recursive: true);
      },
    );
  }
}

final class _Frame {
  const _Frame(this.bytes, this.extension, this.position);
  final Uint8List bytes;
  final String extension;
  final Duration position;
}
