import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/video_note_service.dart';

/// 创建一条字段完整的测试笔记，并允许替换编号、视频、时间点和画面。
VideoNote _createNote({
  String id = 'note-1',
  String bvid = 'BV1GJ411x7h7',
  String title = '测试笔记',
  Duration position = const Duration(seconds: 12),
  DateTime? updatedAt,
  String videoCoverUrl = '',
  String? framePath,
}) {
  final DateTime time = updatedAt ?? DateTime(2026, 7, 15, 19);
  return VideoNote(
    id: id,
    bvid: bvid,
    videoTitle: '测试视频',
    ownerName: '测试UP',
    partCid: 100,
    partPageNumber: 1,
    partTitle: '第一P',
    title: title,
    body: '正文',
    createdAt: time,
    updatedAt: time,
    position: position,
    videoCoverUrl: videoCoverUrl,
    framePath: framePath,
  );
}

/// 创建绑定到当前 SharedPreferences 测试实例的笔记服务。
Future<VideoNoteService> _createService() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return VideoNoteService(preferencesLoader: () async => preferences);
}

void main() {
  test(
    'cancelled captures delete only unreferenced files and retain files when storage is unreadable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-capture-cleanup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final retained = await File(
        '${directory.path}/retained.png',
      ).writeAsBytes([1]);
      final discarded = await File(
        '${directory.path}/discarded.png',
      ).writeAsBytes([2]);
      final service = await _createService();
      await service.saveNote(_createNote(framePath: retained.path));
      await service.discardUnreferencedFrame(retained.path);
      await service.discardUnreferencedFrame(discarded.path);
      expect(await retained.exists(), isTrue);
      expect(await discarded.exists(), isFalse);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(VideoNoteService.storageKey, '{broken');
      await service.discardUnreferencedFrame(retained.path);
      expect(await retained.exists(), isTrue);
    },
  );
  test('legacy frame becomes one attachment at the note position', () {
    final legacy = _createNote(framePath: '/legacy/frame.png').toJson()
      ..remove('frames');
    final parsed = VideoNote.tryParse(legacy)!;
    expect(parsed.allFrames, [
      VideoNoteFrame(path: '/legacy/frame.png', position: parsed.position),
    ]);
    expect(parsed.copyWith(body: 'edited').allFrames, parsed.allFrames);
    expect(parsed.copyWith(clearFrame: true).allFrames, isEmpty);
  });

  test(
    'frame order and individual positions survive saving and editing',
    () async {
      final service = await _createService();
      const frames = [
        VideoNoteFrame(
          path: '/frame-c.png',
          position: Duration(milliseconds: 30025),
        ),
        VideoNoteFrame(
          path: '/frame-a.png',
          position: Duration(milliseconds: 5030),
        ),
        VideoNoteFrame(
          path: '/frame-b.png',
          position: Duration(milliseconds: 30025),
        ),
      ];
      await service.saveNote(_createNote().copyWith(frames: frames));
      final loaded = (await service.loadNotes()).single;
      expect(loaded.allFrames, frames);
      expect(loaded.framePath, frames.first.path);
      await service.saveNote(
        loaded.copyWith(
          body: 'edited',
          frames: [frames[2], frames[0], frames[1]],
        ),
      );
      expect((await service.loadNotes()).single.allFrames, [
        frames[2],
        frames[0],
        frames[1],
      ]);
    },
  );

  test(
    'removing frames only deletes files no remaining note references',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-frames-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = await File('${directory.path}/first.png').writeAsBytes([1]);
      final shared = await File(
        '${directory.path}/shared.png',
      ).writeAsBytes([2]);
      final last = await File('${directory.path}/last.png').writeAsBytes([3]);
      final service = await _createService();
      final note = _createNote().copyWith(
        frames: [
          for (final file in [first, shared, last])
            VideoNoteFrame(path: file.path, position: Duration.zero),
        ],
      );
      await service.saveNote(note);
      await service.saveNote(
        _createNote(id: 'shared-note', framePath: shared.path),
      );
      await service.saveNote(note.copyWith(frames: [note.allFrames.last]));
      expect(await first.exists(), isFalse);
      expect(await shared.exists(), isTrue);
      expect(await last.exists(), isTrue);
      await service.deleteNote(note.id);
      expect(await last.exists(), isFalse);
      expect(await shared.exists(), isTrue);
      await service.deleteNote('shared-note');
      expect(await shared.exists(), isFalse);
    },
  );

  /// 每项测试使用独立的内存偏好设置，避免笔记互相污染。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证保存后可以按更新时间读取，并能按 BV 与时间点筛选排序。
  test('保存并按视频时间点读取笔记', () async {
    final VideoNoteService service = await _createService();
    await service.saveNote(
      _createNote(id: 'later-position', position: const Duration(seconds: 80)),
    );
    await service.saveNote(
      _createNote(
        id: 'earlier-position',
        position: const Duration(seconds: 20),
        updatedAt: DateTime(2026, 7, 15, 20),
      ),
    );
    await service.saveNote(
      _createNote(id: 'other-video', bvid: 'BV1Q541167Qg'),
    );

    final List<VideoNote> allNotes = await service.loadNotes();
    final List<VideoNote> videoNotes = await service.loadNotesForVideo(
      'BV1GJ411x7h7',
    );

    expect(allNotes, hasLength(3));
    expect(allNotes.first.id, 'earlier-position');
    expect(videoNotes.map((VideoNote note) => note.id), <String>[
      'earlier-position',
      'later-position',
    ]);
  });

  /// 验证同编号保存会更新原笔记，而不是产生重复记录。
  test('更新同编号笔记不会重复', () async {
    final VideoNoteService service = await _createService();
    await service.saveNote(_createNote());
    await service.saveNote(
      _createNote(title: '修改后的标题', updatedAt: DateTime(2026, 7, 15, 21)),
    );

    final List<VideoNote> notes = await service.loadNotes();

    expect(notes, hasLength(1));
    expect(notes.single.title, '修改后的标题');
  });

  /// 验证新加入的视频封面字段可以持久化，旧数据缺少字段时仍能读取。
  test('视频封面字段兼容新旧笔记数据', () async {
    final VideoNoteService service = await _createService();
    await service.saveNote(
      _createNote(videoCoverUrl: 'https://example.com/video-cover.jpg'),
    );

    final VideoNote saved = (await service.loadNotes()).single;
    final Map<String, Object?> oldJson = saved.toJson()
      ..remove('videoCoverUrl');
    final VideoNote? oldNote = VideoNote.tryParse(oldJson);

    expect(saved.videoCoverUrl, 'https://example.com/video-cover.jpg');
    expect(oldNote, isNotNull);
    expect(oldNote!.videoCoverUrl, isEmpty);
  });

  /// 验证删除笔记会同时清理该笔记附带的本机画面文件。
  test('删除笔记会清理画面文件', () async {
    final VideoNoteService service = await _createService();
    final Directory directory = await Directory.systemTemp.createTemp(
      'focubili-note-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final File frame = File(
      '${directory.path}${Platform.pathSeparator}frame.jpg',
    );
    await frame.writeAsBytes(<int>[1, 2, 3]);
    await service.saveNote(_createNote(framePath: frame.path));

    await service.deleteNote('note-1');

    expect(await service.loadNotes(), isEmpty);
    expect(await frame.exists(), isFalse);
  });

  /// 验证损坏 JSON 不会让“我的笔记”页面启动崩溃。
  test('损坏数据返回空列表', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      VideoNoteService.storageKey: '{broken-json',
    });
    final VideoNoteService service = await _createService();

    expect(await service.loadNotes(), isEmpty);
  });
}
