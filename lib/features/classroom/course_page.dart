import 'package:flutter/material.dart';

import '../../models/video_preview.dart';
import '../../services/bilibili_course_service.dart';
import '../player/player_page.dart';
import '../profile/login_page.dart';

/// 显式打开课程后读取目录，进入现有播放器并复用选集、进度与笔记。
class CoursePage extends StatefulWidget {
  const CoursePage({super.key, required this.uri, this.service});
  final Uri uri;
  final BilibiliCourseService? service;

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  late Future<VideoPreview> _video;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      _video = (widget.service ?? BilibiliCourseService()).lookup(widget.uri);

  @override
  Widget build(BuildContext context) => FutureBuilder<VideoPreview>(
    future: _video,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        final video = snapshot.data!;
        return PlayerPage(
          video: video,
          initialPartCid: video.requestedCourseEpisodeId == null
              ? null
              : video.cid,
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('B站课堂')),
        body: Center(
          child: snapshot.hasError
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        snapshot.error is CourseLookupException
                            ? '${snapshot.error}'
                            : '课程加载失败，请重试。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const LoginPage(),
                                ),
                              );
                              if (mounted) setState(_load);
                            },
                            child: const Text('登录购买账号'),
                          ),
                          FilledButton(
                            onPressed: () => setState(_load),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    },
  );
}
