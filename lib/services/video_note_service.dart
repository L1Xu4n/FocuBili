import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_note.dart';

typedef VideoNotePreferencesLoader = Future<SharedPreferences> Function();

/// 使用 SharedPreferences 保存文字数据，并管理笔记附带的本机视频画面文件。
class VideoNoteService {
  /// 创建时间点笔记服务；测试可注入内存偏好设置读取器。
  VideoNoteService({VideoNotePreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String storageKey = 'video_timepoint_notes_v1';
  static const int maximumEntries = 500;

  final VideoNotePreferencesLoader _preferencesLoader;

  /// 读取全部合法笔记，并按最近更新时间从新到旧排列。
  Future<List<VideoNote>> loadNotes() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final List<VideoNote> notes = _decodeNotes(
        preferences.getString(storageKey),
      );
      notes.sort(
        // 排序函数让最近编辑过的笔记优先出现在“我的笔记”页面。
        (VideoNote left, VideoNote right) =>
            right.updatedAt.compareTo(left.updatedAt),
      );
      return List<VideoNote>.unmodifiable(notes);
    } catch (_) {
      return const <VideoNote>[];
    }
  }

  /// 读取指定 BV 视频的笔记，并按视频时间点从早到晚排列。
  Future<List<VideoNote>> loadNotesForVideo(String bvid) async {
    final String normalizedBvid = bvid.trim();
    final List<VideoNote> notes = (await loadNotes())
        .where((VideoNote note) => note.bvid == normalizedBvid)
        .toList(growable: true);
    notes.sort(
      // 时间点排序函数让全屏左侧列表与视频播放时间线保持一致。
      (VideoNote left, VideoNote right) =>
          left.position.compareTo(right.position),
    );
    return List<VideoNote>.unmodifiable(notes);
  }

  /// 新增或覆盖同编号笔记，并在更换画面时删除不再引用的旧文件。
  Future<void> saveNote(VideoNote note) async {
    final VideoNote? normalized = VideoNote.tryParse(note.toJson());
    if (normalized == null) {
      throw ArgumentError.value(note, 'note', '笔记缺少必要信息。');
    }
    final SharedPreferences preferences = await _preferencesLoader();
    final List<VideoNote> notes = _decodeNotes(
      preferences.getString(storageKey),
    );
    final int existingIndex = notes.indexWhere(
      (VideoNote item) => item.id == normalized.id,
    );
    String? obsoleteFramePath;
    if (existingIndex >= 0) {
      final VideoNote previous = notes[existingIndex];
      if (previous.framePath != normalized.framePath) {
        obsoleteFramePath = previous.framePath;
      }
      notes[existingIndex] = normalized;
    } else {
      notes.add(normalized);
    }
    notes.sort(
      // 保存前排序函数让截断上限时优先保留最近编辑过的笔记。
      (VideoNote left, VideoNote right) =>
          right.updatedAt.compareTo(left.updatedAt),
    );
    final List<VideoNote> limited = notes.take(maximumEntries).toList();
    final Set<String> retainedIds = limited
        .map((VideoNote item) => item.id)
        .toSet();
    final List<String?> removedFrames = notes
        .where((VideoNote item) => !retainedIds.contains(item.id))
        .map((VideoNote item) => item.framePath)
        .toList(growable: false);
    await preferences.setString(
      storageKey,
      jsonEncode(
        limited.map((VideoNote item) => item.toJson()).toList(growable: false),
      ),
    );
    await _deleteFrameIfPresent(obsoleteFramePath);
    for (final String? framePath in removedFrames) {
      await _deleteFrameIfPresent(framePath);
    }
  }

  /// 删除指定编号的笔记，并同步清理该笔记独占的视频画面文件。
  Future<void> deleteNote(String id) async {
    final String normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final SharedPreferences preferences = await _preferencesLoader();
    final List<VideoNote> notes = _decodeNotes(
      preferences.getString(storageKey),
    );
    final VideoNote? removed = notes.cast<VideoNote?>().firstWhere(
      (VideoNote? item) => item?.id == normalizedId,
      orElse: () => null,
    );
    notes.removeWhere((VideoNote item) => item.id == normalizedId);
    await preferences.setString(
      storageKey,
      jsonEncode(
        notes.map((VideoNote item) => item.toJson()).toList(growable: false),
      ),
    );
    await _deleteFrameIfPresent(removed?.framePath);
  }

  /// 将本机 JSON 解码为去重后的笔记列表，损坏数据会被安全忽略。
  List<VideoNote> _decodeNotes(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return <VideoNote>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return <VideoNote>[];
      }
      final Set<String> seenIds = <String>{};
      final List<VideoNote> notes = <VideoNote>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final VideoNote? note = VideoNote.tryParse(
          Map<String, dynamic>.from(item),
        );
        if (note != null && seenIds.add(note.id)) {
          notes.add(note);
        }
      }
      return notes;
    } catch (_) {
      return <VideoNote>[];
    }
  }

  /// 删除存在的本机画面文件；文件已不存在或删除失败不会影响文字笔记。
  Future<void> _deleteFrameIfPresent(String? framePath) async {
    if (framePath == null || framePath.trim().isEmpty) {
      return;
    }
    try {
      final File file = File(framePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 画面清理失败不应导致用户的文字笔记保存或删除失败。
    }
  }
}
