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
  final _search = TextEditingController();
  List<PurchasedCourse> _courses = const [];
  bool _loading = true;
  bool _suspended = false;
  String? _error;
  int _generation = 0;
  int _searchRevision = 0;

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
    _search.dispose();
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
      _invalidate(clearSearch: true);
    }
  }

  void _accountChanged() {
    if (_suspended) {
      _invalidate(clearSearch: true);
    } else {
      unawaited(_load(clearSearch: true));
    }
  }

  int _invalidate({bool clearSearch = false}) {
    final generation = ++_generation;
    setState(() {
      if (clearSearch) {
        _search.clear();
        _searchRevision++;
      }
      _loading = true;
      _error = null;
      _courses = const [];
    });
    return generation;
  }

  Future<void> _load({bool clearSearch = false}) async {
    if (_suspended) return;
    final generation = _invalidate(clearSearch: clearSearch);
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
          key: const Key('purchased-courses-link-input'),
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

  void _clearSearch() {
    setState(_search.clear);
  }

  Widget _searchField({required bool separateLabel}) {
    const label = '搜索课程名或简介';
    final field = TextField(
      key: const Key('purchased-courses-search'),
      controller: _search,
      textInputAction: TextInputAction.search,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => FocusScope.of(context).unfocus(),
      decoration: InputDecoration(
        labelText: separateLabel ? null : label,
        hintText: separateLabel ? '输入关键词' : null,
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除课程搜索',
                onPressed: _clearSearch,
                icon: const Icon(Icons.close_rounded),
              ),
        border: const OutlineInputBorder(),
      ),
    );
    if (!separateLabel) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        field,
      ],
    );
  }

  Widget _emptyList() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
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
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () async {
                final generation = _generation;
                final account = await Navigator.of(context)
                    .push<BilibiliAccount>(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                    );
                if (mounted && account != null && generation == _generation) {
                  await _load();
                }
              },
              child: const Text('登录购买账号'),
            ),
            FilledButton(onPressed: _load, child: const Text('重新加载')),
          ],
        ),
      ],
    ),
  );

  Widget _noMatches() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      children: [
        const Icon(Icons.search_off_rounded, size: 40),
        const SizedBox(height: 12),
        const Text('没有匹配的课程', key: Key('purchased-courses-no-matches')),
        const SizedBox(height: 8),
        const Text('试试其他课程名或简介关键词。', textAlign: TextAlign.center),
        TextButton(onPressed: _clearSearch, child: const Text('清除搜索')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? _courses
        : _courses
              .where(
                (course) =>
                    course.title.toLowerCase().contains(query) ||
                    course.description.toLowerCase().contains(query),
              )
              .toList(growable: false);
    return Scaffold(
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
                builder: (context, constraints) {
                  final inset = AdaptiveLayout.centeredHorizontalPadding(
                    width: constraints.maxWidth,
                    maxContentWidth: 900,
                    compact: 16,
                  );
                  // Reserve space for both icons even before typing so the
                  // label never jumps mid-edit. Eight CJK characters can use
                  // the whole em width at accessibility text scales.
                  final separateLabel =
                      constraints.maxWidth - 2 * inset <
                      120 + 8 * MediaQuery.textScalerOf(context).scale(16);
                  return ListView.builder(
                    key: const Key('purchased-courses-list'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.symmetric(
                      horizontal: inset,
                      vertical: 16,
                    ),
                    itemCount: 1 + (visible.isEmpty ? 1 : visible.length),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_courses.isNotEmpty) ...[
                                // Keep purchase notices and result counts out of the field label.
                                Semantics(
                                  key: ValueKey(_searchRevision),
                                  container: true,
                                  child: _searchField(
                                    separateLabel: separateLabel,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  query.isEmpty
                                      ? '共 ${_courses.length} 门已购课程'
                                      : '找到 ${visible.length} 门课程',
                                  key: const Key('purchased-courses-count'),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                              ],
                              Text(
                                '仅显示当前账号的已购课堂。播放权限由 B站校验，本机进度与时间点笔记可在播放器内使用。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      }
                      if (_courses.isEmpty) return _emptyList();
                      if (visible.isEmpty) return _noMatches();
                      final course = visible[index - 1];
                      return _PurchasedCourseTile(
                        key: ValueKey(course.id),
                        course: course,
                        onOpen: () => _open(course.uri),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

class _PurchasedCourseTile extends StatelessWidget {
  const _PurchasedCourseTile({
    super.key,
    required this.course,
    required this.onOpen,
  });

  final PurchasedCourse course;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = course.unavailable
        ? '课程已失效或已下架'
        : course.expired
        ? '课程已过期，请到官方课堂确认'
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        enabled: status == null,
        child: InkWell(
          key: Key('purchased-course-${course.id}'),
          onTap: status == null ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final coverWidth = (constraints.maxWidth * .28)
                    .clamp(0.0, 144.0)
                    .toDouble();
                final showChevron =
                    status == null &&
                    constraints.maxWidth >= 300 &&
                    MediaQuery.textScalerOf(context).scale(16) < 28;
                return Row(
                  children: [
                    _CourseCover(course: course, width: coverWidth),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            course.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (course.description.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              course.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (status != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              status,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (showChevron) ...[
                      const SizedBox(width: 8),
                      const ExcludeSemantics(
                        child: Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CourseCover extends StatelessWidget {
  const _CourseCover({required this.course, required this.width});

  final PurchasedCourse course;
  final double width;

  static Uri? _coverUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !(uri.host.endsWith('.hdslb.com') ||
            uri.host.endsWith('.biliimg.com'))) {
      return null;
    }
    return uri;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final url = _coverUri(course.cover);
    final placeholder = ColoredBox(
      key: Key('purchased-course-cover-placeholder-${course.id}'),
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.school_outlined, color: colors.onSurfaceVariant),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        key: Key('purchased-course-cover-${course.id}'),
        width: width,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: url == null
                ? placeholder
                // No session headers, purchase-record persistence or disk image
                // cache. Flutter keeps only the usual in-memory decode cache.
                : Image.network(
                    url.toString(),
                    fit: BoxFit.cover,
                    cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                        .ceil()
                        .clamp(1, 512),
                    frameBuilder: (context, child, frame, _) =>
                        frame == null ? placeholder : child,
                    errorBuilder: (context, _, _) => placeholder,
                  ),
          ),
        ),
      ),
    );
  }
}
