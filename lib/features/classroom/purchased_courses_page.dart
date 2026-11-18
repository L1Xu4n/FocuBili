import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/bilibili_course_link.dart';
import '../../services/bilibili_course_service.dart';
import '../../services/cache_lifecycle.dart';
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
  bool _suspended = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CacheLifecycle.account.addListener(_accountChanged);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _suspended =
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused;
    unawaited(_load());
  }

  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A dialog may still cover this route after resuming. Restart even then so
    // dismissing it never exposes an empty list with a stranded spinner.
    if (state == AppLifecycleState.resumed && _suspended) {
      _suspended = false;
      unawaited(_load());
    } else if (!_suspended &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      _suspended = true;
      _invalidate();
    }
  }

  void _accountChanged() {
    if (_suspended) {
      _invalidate();
    } else {
      unawaited(_load());
    }
  }

  int _invalidate() {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _courses = const [];
    });
    return generation;
  }

  Future<void> _load() async {
    if (_suspended) return;
    final generation = _invalidate();
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
    var input = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('打开课程链接'),
        content: TextField(
          onChanged: (value) => input = value,
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
            onPressed: () => Navigator.pop(context, input),
            child: const Text('打开'),
          ),
        ],
      ),
    );
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
                                  final generation = _generation;
                                  final account = await Navigator.of(context)
                                      .push<BilibiliAccount>(
                                        MaterialPageRoute(
                                          builder: (_) => const LoginPage(),
                                        ),
                                      );
                                  if (mounted &&
                                      account != null &&
                                      generation == _generation) {
                                    await _load();
                                  }
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
