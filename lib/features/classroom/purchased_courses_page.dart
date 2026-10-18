import 'package:flutter/material.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../services/bilibili_course_link.dart';
import '../../services/bilibili_course_service.dart';
import '../profile/login_page.dart';
import 'course_page.dart';

/// 仅在用户打开此页后读取当前会话的已购列表，不持久化购买记录。
class PurchasedCoursesPage extends StatefulWidget {
  const PurchasedCoursesPage({super.key, this.service});
  final BilibiliCourseService? service;
  @override
  State<PurchasedCoursesPage> createState() => _PurchasedCoursesPageState();
}

class _PurchasedCoursesPageState extends State<PurchasedCoursesPage>
    with WidgetsBindingObserver {
  late final _service = widget.service ?? BilibiliCourseService();
  List<PurchasedCourse> _courses = const [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台不保留账号购买列表；返回前台必须重新读取当前会话。
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent != false) {
      _load();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _generation++;
      if (mounted) {
        setState(() {
          _courses = const [];
          _loading = true;
        });
      }
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _courses = const [];
    });
    try {
      final courses = await _service.purchasedCourses();
      if (mounted && generation == _generation) {
        setState(() => _courses = courses);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is CourseLookupException
              ? error.message
              : '已购课程加载失败，请重试。',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openLink() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('打开课程链接'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '粘贴 B站课堂 ss / ep 链接'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    // 等待对话框退出动画后释放输入控制器。
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (!mounted || text == null) return;
    final uri = BilibiliCourseLink.fromInput(text);
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的 B站课堂 ss / ep 链接。')));
      return;
    }
    await _open(uri);
  }

  Future<void> _open(Uri uri) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoursePage(uri: uri, service: _service),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('已购课程'),
      actions: [
        IconButton(
          tooltip: '打开课程链接',
          onPressed: _openLink,
          icon: const Icon(Icons.add_link_rounded),
        ),
        IconButton(
          tooltip: '刷新已购课程',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                key: const Key('purchased-courses-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: AdaptiveLayout.centeredHorizontalPadding(
                    width: constraints.maxWidth,
                    maxContentWidth: 900,
                    compact: 16,
                  ),
                  vertical: 16,
                ),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('显示当前登录账号的已购课堂。播放权限由 B站校验，本机进度与时间点笔记可在播放器内使用。'),
                  ),
                  if (_courses.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        children: [
                          const Icon(Icons.school_outlined, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            _error ?? '当前账号暂无已购课程。请确认登录的是购买课程的账号。',
                            key: const Key('purchased-courses-message'),
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
                                  if (mounted) await _load();
                                },
                                child: const Text('登录购买账号'),
                              ),
                              FilledButton(
                                onPressed: _load,
                                child: const Text('重新加载'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  for (final course in _courses)
                    Card(
                      child: ListTile(
                        key: Key('purchased-course-${course.id}'),
                        leading: Icon(
                          course.unavailable || course.expired
                              ? Icons.lock_outline
                              : Icons.school_outlined,
                        ),
                        title: Text(course.title),
                        subtitle: Text(
                          course.unavailable
                              ? '课程已失效或已下架'
                              : course.expired
                              ? '课程已过期，请到官方课堂确认'
                              : course.description,
                        ),
                        enabled: !course.unavailable && !course.expired,
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: course.unavailable || course.expired
                            ? null
                            : () => _open(course.uri),
                      ),
                    ),
                ],
              ),
            ),
          ),
  );
}
