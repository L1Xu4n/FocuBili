import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/features/notes/video_notes_page.dart';
import 'package:focubili/features/notes/video_note_share_preview.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/video_note_service.dart';

/// 创建绑定到内存 SharedPreferences 的页面测试服务。
Future<VideoNoteService> _createPageNoteService() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return VideoNoteService(preferencesLoader: () async => preferences);
}

/// 创建“我的笔记”页面需要展示的一条完整测试笔记。
VideoNote _createPageNote({
  String videoCoverUrl = '',
  String partTitle = '第一P',
  String? framePath,
}) {
  final DateTime time = DateTime(2026, 7, 15, 19, 1);
  return VideoNote(
    id: 'managed-note',
    bvid: 'BV1GJ411x7h7',
    videoTitle: '统一管理测试视频',
    ownerName: '测试UP',
    partCid: 100,
    partPageNumber: 1,
    partTitle: partTitle,
    title: '原笔记标题',
    body: '原正文',
    createdAt: time,
    updatedAt: time,
    position: const Duration(minutes: 1, seconds: 2),
    videoCoverUrl: videoCoverUrl,
    framePath: framePath,
  );
}

/// 提供可计数的假视频查询服务，避免组件测试访问真实 B 站接口。
class _FakeNoteVideoService implements BilibiliService {
  /// 创建假服务，并指定旧笔记补全时应返回的视频封面。
  _FakeNoteVideoService({this.coverUrl = ''});

  final String coverUrl;
  int lookupRequests = 0;

  /// 返回包含指定封面的最小视频资料，并记录查询次数。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupRequests += 1;
    return VideoPreview(
      bvid: input,
      cid: 100,
      title: '统一管理测试视频',
      ownerName: '测试UP',
      thumbnailUrl: coverUrl,
      parts: const <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 100,
          title: '第一P',
          duration: Duration(minutes: 3),
        ),
      ],
    );
  }

  /// 此页面不会搜索视频，若误调用则立即暴露测试错误。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) {
    throw UnimplementedError('笔记页面不应调用视频搜索');
  }

  /// 此页面不会获取搜索建议，固定返回空列表即可。
  @override
  Future<List<String>> suggestKeywords(String input) async => const <String>[];
}

/// 提供可返回的测试首页，用来验证详情页的退出提醒和播放器跳转。
class _NoteDetailTestHost extends StatelessWidget {
  /// 创建带有“打开笔记”入口的测试宿主页。
  const _NoteDetailTestHost({
    required this.note,
    required this.noteService,
    required this.videoService,
    required this.playerBuilder,
  });

  final VideoNote note;
  final VideoNoteService noteService;
  final BilibiliService videoService;
  final VideoNotePlayerBuilder playerBuilder;

  /// 构建测试入口，并把依赖完整传递给独立笔记详情页。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-test-note-detail'),
          // 打开函数进入详情页，测试结束时可以正常返回此宿主页。
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => VideoNoteDetailPage(
                note: note,
                noteService: noteService,
                videoService: videoService,
                playerBuilder: playerBuilder,
              ),
            ),
          ),
          child: const Text('打开笔记'),
        ),
      ),
    );
  }
}

void main() {
  /// 每项组件测试使用全新的本机笔记存储。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证搜索、独立详情编辑和列表菜单删除可以组成完整管理流程。
  testWidgets('时间点笔记页面可搜索并进入独立详情编辑和删除', (WidgetTester tester) async {
    final VideoNoteService service = await _createPageNoteService();
    final _FakeNoteVideoService videoService = _FakeNoteVideoService();
    await service.saveNote(_createPageNote());
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNotesPage(noteService: service, videoService: videoService),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('时间点笔记'), findsOneWidget);
    expect(find.text('原笔记标题'), findsOneWidget);
    expect(find.text('01:02'), findsOneWidget);
    expect(find.text('2026-07-15 19:01'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('video-notes-search-field')),
      '找不到的关键词',
    );
    await tester.pump();
    expect(find.text('没有匹配的笔记'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-video-notes-search')));
    await tester.pump();
    expect(find.text('原笔记标题'), findsOneWidget);

    await tester.tap(find.byKey(const Key('managed-video-note-managed-note')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoNoteDetailPage), findsOneWidget);
    expect(find.text('笔记详情'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('note-detail-title-field')),
      '修改后的笔记',
    );
    await tester.enterText(
      find.byKey(const Key('note-detail-body-field')),
      '修改后的正文',
    );
    await tester.tap(find.byKey(const Key('save-note-detail')));
    await tester.pumpAndSettle();
    expect((await service.loadNotes()).single.body, '修改后的正文');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('修改后的笔记'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('managed-video-note-menu-managed-note')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除笔记').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('还没有时间点笔记'), findsOneWidget);
    expect(await service.loadNotes(), isEmpty);
  });

  /// 验证右上角使用明确“导出”文字，进入选择后同时提供保存和分享文件。
  testWidgets('笔记列表导出入口支持多选后保存或分享文件', (WidgetTester tester) async {
    final VideoNoteService service = await _createPageNoteService();
    await service.saveNote(_createPageNote());
    await tester.pumpWidget(
      MaterialApp(home: VideoNotesPage(noteService: service)),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextButton, '导出'), findsOneWidget);
    expect(find.byIcon(Icons.checklist_rounded), findsNothing);
    await tester.tap(find.byKey(const Key('select-video-notes')));
    await tester.pumpAndSettle();

    expect(find.text('导出文件'), findsOneWidget);
    expect(find.text('分享文件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('managed-video-note-managed-note')));
    await tester.pump();
    final OutlinedButton exportButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('save-selected-video-notes')),
    );
    final FilledButton shareButton = tester.widget<FilledButton>(
      find.byKey(const Key('share-selected-video-notes')),
    );
    expect(exportButton.onPressed, isNotNull);
    expect(shareButton.onPressed, isNotNull);
  });

  /// 验证旧版本笔记会用公开视频资料补齐视频封面并写回本机。
  testWidgets('旧笔记会自动补齐视频封面', (WidgetTester tester) async {
    final VideoNoteService service = await _createPageNoteService();
    final _FakeNoteVideoService videoService = _FakeNoteVideoService(
      coverUrl: 'https://example.com/video-cover.jpg',
    );
    await service.saveNote(_createPageNote());
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNotesPage(noteService: service, videoService: videoService),
      ),
    );
    await tester.pumpAndSettle();

    expect(videoService.lookupRequests, 1);
    expect(
      find.byKey(const Key('managed-video-note-cover-managed-note')),
      findsOneWidget,
    );
    expect(
      (await service.loadNotes()).single.videoCoverUrl,
      'https://example.com/video-cover.jpg',
    );
  });

  /// 验证详情页把截图放在正文之后、保持原比例并可打开全屏预览。
  testWidgets('详情页截图自适应并支持全屏查看', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(450, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final VideoNoteService service = await _createPageNoteService();
    final File frame = File('assets/icon/focubili_icon.png').absolute;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNoteDetailPage(
          note: _createPageNote(
            framePath: frame.path,
            partTitle: '这是一个用于验证窄屏省略效果的超长视频分P标题',
          ),
          noteService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder frameSection = find.byKey(
      const Key('note-detail-frame-section'),
    );
    expect(frameSection, findsOneWidget);
    final Image frameImage = tester.widget<Image>(
      find.descendant(of: frameSection, matching: find.byType(Image)).first,
    );
    expect(frameImage.fit, BoxFit.contain);

    final InkWell openFrameButton = tester.widget<InkWell>(
      find.byKey(const Key('open-note-frame-fullscreen')),
    );
    openFrameButton.onTap!();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fullscreen-note-frame-viewer')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('fullscreen-note-frame-viewport'))),
      const Size(450, 900),
    );
    // 关闭按钮必须保持普通按钮大小，不能被全屏 Stack 拉伸成遮罩层。
    final Size closeButtonSize = tester.getSize(
      find.byKey(const Key('close-fullscreen-note-frame')),
    );
    expect(closeButtonSize.width, lessThan(80));
    expect(closeButtonSize.height, lessThan(80));

    await tester.tap(find.byKey(const Key('close-fullscreen-note-frame')));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);
  });

  /// 验证详情右上角会生成包含来源、正文、时间点、截图和字数的自适应长图。
  testWidgets('详情页可预览包含截图和完整正文的笔记分享长图', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final VideoNoteService service = await _createPageNoteService();
    final File frame = File('assets/icon/focubili_icon.png').absolute;
    final String longBody = List<String>.filled(
      80,
      '这是一段不会在分享图中被截断的笔记正文。',
    ).join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: VideoNoteDetailPage(
          note: _createPageNote(framePath: frame.path).copyWith(body: longBody),
          noteService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('share-note-from-detail')));
    await tester.pumpAndSettle();

    expect(find.text('笔记分享预览'), findsOneWidget);
    expect(find.byType(VideoNoteShareCard), findsOneWidget);
    expect(find.text('BV · BV1GJ411x7h7'), findsOneWidget);
    expect(find.text('时间点 · 01:02'), findsOneWidget);
    expect(find.text('统一管理测试视频'), findsWidgets);
    expect(find.byKey(const Key('video-note-share-frame')), findsOneWidget);
    expect(
      find.text('笔记 ${videoNoteCharacterCount(longBody)} 字'),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('video-note-share-card'))).height,
      greaterThan(1200),
    );
  });

  /// 验证视频来源卡会传递正确分P和时间点，未保存退出时必须确认。
  testWidgets('详情来源可跳转对应分P时间点且退出前提醒保存', (WidgetTester tester) async {
    final VideoNoteService service = await _createPageNoteService();
    final _FakeNoteVideoService videoService = _FakeNoteVideoService();
    int? openedCid;
    Duration? openedPosition;
    await tester.pumpWidget(
      MaterialApp(
        home: _NoteDetailTestHost(
          note: _createPageNote(),
          noteService: service,
          videoService: videoService,
          // 测试播放器构建函数记录详情页传来的分P和时间点，不启动原生播放器。
          playerBuilder:
              (
                VideoPreview video,
                int initialPartCid,
                Duration initialPosition,
              ) {
                openedCid = initialPartCid;
                openedPosition = initialPosition;
                return const Scaffold(
                  key: Key('test-note-player-destination'),
                  body: Text('播放器目标页'),
                );
              },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-test-note-detail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-video-source-card')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('test-note-player-destination')),
      findsOneWidget,
    );
    expect(openedCid, 100);
    expect(openedPosition, const Duration(minutes: 1, seconds: 2));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('note-detail-title-field')),
      '尚未保存的标题',
    );
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('不保存并退出'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-test-note-detail')), findsOneWidget);
  });

  /// 验证全屏编辑器的头部高度和截图预览不再强制拉满固定宽高。
  testWidgets('全屏笔记头部紧凑且截图按原比例布局', (WidgetTester tester) async {
    final TextEditingController titleController = TextEditingController();
    final TextEditingController bodyController = TextEditingController();
    addTearDown(titleController.dispose);
    addTearDown(bodyController.dispose);
    final File frame = File('assets/icon/focubili_icon.png').absolute;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoNoteComposer(
            titleController: titleController,
            bodyController: bodyController,
            position: const Duration(minutes: 5),
            includeFrame: true,
            saving: false,
            framePath: frame.path,
            compact: true,
            borderless: true,
            // 画面选择测试函数无需改变外部状态。
            onIncludeFrameChanged: (bool selected) {},
            // 保存测试函数只用于满足编辑器必需回调。
            onSave: () {},
            // 新建测试函数只用于满足编辑器必需回调。
            onNew: () {},
            // 关闭测试函数只用于满足编辑器必需回调。
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('compact-note-header'))).height,
      lessThanOrEqualTo(40),
    );
    final Image preview = tester.widget<Image>(
      find.byKey(const Key('note-frame-preview')),
    );
    expect(preview.width, isNull);
    expect(preview.height, isNull);
    expect(preview.fit, BoxFit.contain);
  });

  /// 验证狭窄全屏面板会为完整记录时间启用横向循环滚动，而不是省略文字。
  testWidgets('全屏笔记记录时间过长时自动滚动', (WidgetTester tester) async {
    final TextEditingController titleController = TextEditingController();
    final TextEditingController bodyController = TextEditingController();
    addTearDown(titleController.dispose);
    addTearDown(bodyController.dispose);
    await tester.binding.setSurfaceSize(const Size(340, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoNoteComposer(
            titleController: titleController,
            bodyController: bodyController,
            position: const Duration(minutes: 25, seconds: 17),
            createdAt: DateTime(2026, 7, 15, 23, 59),
            includeFrame: false,
            saving: false,
            compact: true,
            borderless: true,
            // 画面选择测试函数无需改变外部状态。
            onIncludeFrameChanged: (bool selected) {},
            // 保存测试函数只用于满足编辑器必需回调。
            onSave: () {},
            // 新建测试函数只用于满足编辑器必需回调。
            onNew: () {},
            // 关闭测试函数只用于满足编辑器必需回调。
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final Finder marquee = find.byKey(const Key('note-recorded-time-marquee'));
    expect(marquee, findsOneWidget);
    expect(
      find.descendant(of: marquee, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );
  });
}
