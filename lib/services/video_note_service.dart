import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_note.dart';
import 'cache_lifecycle.dart';

typedef VideoNotePreferencesLoader = Future<SharedPreferences> Function();

/// 使用 SharedPreferences 保存文字数据，并管理笔记附带的本机视频画面文件。
class VideoNoteService {
  /// 创建时间点笔记服务；测试可注入内存偏好设置读取器。
  VideoNoteService({VideoNotePreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String storageKey = 'video_timepoint_notes_v1';
  static const int maximumEntries = 500;
  static final StreamController<String> _changes =
      StreamController<String>.broadcast();

  /// 通知所有服务实例同一 BV 的笔记已成功写入，播放器无需另建数据源。
  static Stream<String> get changes => _changes.stream;

  final VideoNotePreferencesLoader _preferencesLoader;

  // 读、写和截图回收共享同一队列，不能读取另一个操作尚未提交的笔记。
  static final Expando<Future<void>> _queues = Expando('note storage');
  static final Expando<bool> _unverifiedCaches = Expando(
    'unverified note cache',
  );

  Future<T> _withNotes<T>(Future<T> Function(SharedPreferences) action) async {
    final prefs = await _preferencesLoader();
    final previous = _queues[prefs];
    final release = Completer<void>();
    _queues[prefs] = release.future;
    try {
      if (previous != null) await previous;
      if (_unverifiedCaches[prefs] == true) await _reloadNotes(prefs);
      return await action(prefs);
    } finally {
      release.complete();
      if (identical(_queues[prefs], release.future)) {
        _queues[prefs] = null;
      }
    }
  }

  Future<void> _reloadNotes(SharedPreferences preferences) async {
    await preferences.reload();
    _unverifiedCaches[preferences] = null;
  }

  Future<void> _writeNotes(
    SharedPreferences preferences,
    String raw,
    String errorMessage,
  ) async {
    try {
      if (!await preferences.setString(storageKey, raw)) {
        throw StateError(errorMessage);
      }
    } catch (_) {
      // SharedPreferences 先改内存再调用平台写入。回到持久值后才允许下一个
      // 读、写或截图回收；否则下一次补封面可能把被拒的删除真正写入。
      _unverifiedCaches[preferences] = true;
      try {
        await _reloadNotes(preferences);
      } catch (_) {
        // 不用读取错误替换原始写入错误；下次操作在访问缓存前会再次校验。
      }
      rethrow;
    }
  }

  /// 迟到的封面只更新仍存在且仍缺封面的记录，不回写查询开始时的正文或截图。
  Future<Set<String>> fillMissingCovers(String bvid, String coverUrl) async {
    if (coverUrl.trim().isEmpty || bvid.trim().isEmpty) return {};
    return _withNotes((prefs) async {
      final raw = prefs.getString(storageKey);
      if (raw == null) return <String>{};
      final rows = jsonDecode(raw);
      if (rows is! List) return <String>{};
      final changed = <String>{};
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row['bvid'] != bvid ||
            row['id'] is! String) {
          continue;
        }
        final existing = row['videoCoverUrl'];
        if (existing != null &&
            (existing is! String || existing.trim().isNotEmpty)) {
          continue;
        }
        row['videoCoverUrl'] = coverUrl;
        changed.add(row['id'] as String);
      }
      // 就地改原始字段，同时保留未识别字段、记录顺序、用户编辑时间和画面。
      if (changed.isNotEmpty) {
        await _writeNotes(prefs, jsonEncode(rows), '封面保存失败');
        _changes.add(bvid);
      }
      return changed;
    });
  }

  /// 清理导航撤销后的新截图；存储不可读或仍被任一笔记引用时保留文件。
  Future<void> discardUnreferencedFrame(String path) async {
    try {
      await _withNotes((preferences) async {
        final raw = preferences.getString(storageKey);
        if (raw != null && jsonDecode(raw) is! List) return;
        final notes = _decodeNotes(raw);
        if (notes.any(
          (note) => note.allFrames.any((frame) => frame.path == path),
        )) {
          return;
        }
        await _deleteFrameIfPresent(path);
      });
    } catch (_) {
      // 无法确认引用状态时不删除。
    }
  }

  /// 读取全部合法笔记，并按最近更新时间从新到旧排列。
  Future<List<VideoNote>> loadNotes() async {
    try {
      final List<VideoNote> notes = await _withNotes(
        (preferences) async => _decodeNotes(preferences.getString(storageKey)),
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

  /// 读取指定 BV 视频的笔记，依次按分 P、播放位置和创建时间升序排列。
  Future<List<VideoNote>> loadNotesForVideo(String bvid) async {
    final String normalizedBvid = bvid.trim();
    final List<VideoNote> notes = (await loadNotes())
        .where((VideoNote note) => note.bvid == normalizedBvid)
        .toList(growable: true);
    notes.sort(
      // 按观看顺序排列；同位置笔记按创建时间排列，编号兜底确保编辑后顺序稳定。
      (VideoNote left, VideoNote right) {
        final int partOrder = left.partPageNumber.compareTo(
          right.partPageNumber,
        );
        if (partOrder != 0) return partOrder;
        final int positionOrder = left.position.compareTo(right.position);
        if (positionOrder != 0) return positionOrder;
        final int createdOrder = left.createdAt.compareTo(right.createdAt);
        if (createdOrder != 0) return createdOrder;
        return left.id.compareTo(right.id);
      },
    );
    return List<VideoNote>.unmodifiable(notes);
  }

  /// 新增或覆盖同编号笔记，并在更换画面时删除不再引用的旧文件。
  Future<void> saveNote(VideoNote note) async {
    final VideoNote? normalized = VideoNote.tryParse(note.toJson());
    if (normalized == null) {
      throw ArgumentError.value(note, 'note', '笔记缺少必要信息。');
    }
    await _withNotes((prefs) => _saveNormalized(prefs, normalized));
  }

  /// Finish an editor's detached write on the same storage queue. A deleted
  /// or newer copy is authoritative; a queued draft never recreates it.
  Future<bool> finishPendingDraft(
    VideoNote draft, {
    required VideoNote? expected,
    required int accountRevision,
    required String accountScope,
  }) async {
    final normalized = VideoNote.tryParse(draft.toJson());
    if (normalized == null) return false;
    return _withNotes((prefs) async {
      if (accountRevision != CacheLifecycle.account.value ||
          accountScope != CacheLifecycle.accountScope) {
        return false;
      }
      final current = _decodeNotes(
        prefs.getString(storageKey),
      ).where((note) => note.id == normalized.id).firstOrNull;
      if (expected == null
          ? current != null
          : current == null ||
                current.id != expected.id ||
                current.bvid != expected.bvid ||
                current.partCid != expected.partCid ||
                !_matchesSavedDraft(current, expected) ||
                expected.id != normalized.id ||
                expected.bvid != normalized.bvid ||
                expected.partCid != normalized.partCid) {
        return false;
      }
      await _saveNormalized(prefs, normalized);
      return true;
    });
  }

  bool _matchesSavedDraft(VideoNote current, VideoNote expected) {
    if (!current.updatedAt.isAtSameMomentAs(expected.updatedAt) ||
        current.title != expected.title.trim() ||
        current.body != expected.body ||
        current.position.inMilliseconds != expected.position.inMilliseconds) {
      return false;
    }
    final currentFrames = current.allFrames;
    final expectedFrames = expected.allFrames;
    if (currentFrames.length != expectedFrames.length) return false;
    for (var index = 0; index < currentFrames.length; index++) {
      if (currentFrames[index].path != expectedFrames[index].path.trim() ||
          currentFrames[index].position.inMilliseconds !=
              expectedFrames[index].position.inMilliseconds) {
        return false;
      }
    }
    return true;
  }

  Future<void> _saveNormalized(
    SharedPreferences preferences,
    VideoNote normalized,
  ) async {
    final List<VideoNote> notes = _decodeNotes(
      preferences.getString(storageKey),
    );
    final int existingIndex = notes.indexWhere(
      (VideoNote item) => item.id == normalized.id,
    );
    final Set<String> obsoleteFramePaths = <String>{};
    if (existingIndex >= 0) {
      final VideoNote previous = notes[existingIndex];
      obsoleteFramePaths.addAll(previous.allFrames.map((frame) => frame.path));
      notes[existingIndex] =
          normalized.videoCoverUrl.isEmpty &&
              previous.bvid == normalized.bvid &&
              previous.videoCoverUrl.isNotEmpty
          ? normalized.copyWith(videoCoverUrl: previous.videoCoverUrl)
          : normalized;
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
    obsoleteFramePaths.addAll(
      notes
          .where((VideoNote item) => !retainedIds.contains(item.id))
          .expand(
            (VideoNote item) => item.allFrames.map((frame) => frame.path),
          ),
    );
    final retainedFramePaths = limited
        .expand((item) => item.allFrames.map((frame) => frame.path))
        .toSet();
    obsoleteFramePaths.removeAll(retainedFramePaths);
    await _writeNotes(
      preferences,
      jsonEncode(
        limited.map((VideoNote item) => item.toJson()).toList(growable: false),
      ),
      '笔记保存失败',
    );
    _changes.add(normalized.bvid);
    for (final String framePath in obsoleteFramePaths) {
      await _deleteFrameIfPresent(framePath);
    }
  }

  /// 删除指定编号的笔记，并同步清理该笔记独占的视频画面文件。
  Future<void> deleteNote(String id) async {
    final String normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    await _withNotes((prefs) => _deleteStoredNote(prefs, normalizedId));
  }

  Future<void> _deleteStoredNote(
    SharedPreferences preferences,
    String normalizedId,
  ) async {
    final List<VideoNote> notes = _decodeNotes(
      preferences.getString(storageKey),
    );
    final VideoNote? removed = notes.cast<VideoNote?>().firstWhere(
      (VideoNote? item) => item?.id == normalizedId,
      orElse: () => null,
    );
    notes.removeWhere((VideoNote item) => item.id == normalizedId);
    await _writeNotes(
      preferences,
      jsonEncode(
        notes.map((VideoNote item) => item.toJson()).toList(growable: false),
      ),
      '笔记删除失败',
    );
    if (removed != null) _changes.add(removed.bvid);
    final retainedPaths = notes
        .expand((item) => item.allFrames.map((frame) => frame.path))
        .toSet();
    for (final frame in removed?.allFrames ?? const <VideoNoteFrame>[]) {
      if (!retainedPaths.contains(frame.path)) {
        await _deleteFrameIfPresent(frame.path);
      }
    }
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
