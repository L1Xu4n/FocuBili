import 'package:flutter/material.dart';

import '../../models/content_blocklist.dart';
import '../../services/content_blocklist_service.dart';

const _creatorRules = [
  ContentBlockKind.creatorUid,
  ContentBlockKind.creatorName,
  ContentBlockKind.creatorKeyword,
];
const _videoRules = [
  ContentBlockKind.videoTag,
  ContentBlockKind.videoTitleKeyword,
];

String _kindLabel(ContentBlockKind kind) => switch (kind) {
  ContentBlockKind.creatorUid => 'UID（精确）',
  ContentBlockKind.creatorName => '完整昵称（精确）',
  ContentBlockKind.creatorKeyword => '昵称关键词（包含）',
  ContentBlockKind.videoTag => '完整视频标签（精确）',
  ContentBlockKind.videoTitleKeyword => '标题关键词（包含）',
};

String _kindHelp(ContentBlockKind kind) => switch (kind) {
  ContentBlockKind.creatorUid => '输入数字 UID，只匹配该账号，不受改名影响。',
  ContentBlockKind.creatorName => '匹配完整昵称。不同账号同名也会命中，改名后可能不再匹配。',
  ContentBlockKind.creatorKeyword => '昵称包含这段文字即匹配，不匹配视频标题。',
  ContentBlockKind.videoTag => '匹配一个完整的标签，不匹配标签的一部分。缺少标签数据时不按此规则屏蔽。',
  ContentBlockKind.videoTitleKeyword => '视频标题包含这段文字即匹配，不匹配昵称或标签。',
};

/// Manages local rules and the exact-ID blocks added from overflow menus.
class ContentBlocklistPage extends StatefulWidget {
  const ContentBlocklistPage({
    super.key,
    this.service = const ContentBlocklistService(),
  });
  final ContentBlocklistService service;

  @override
  State<ContentBlocklistPage> createState() => _ContentBlocklistPageState();
}

class _ContentBlocklistPageState extends State<ContentBlocklistPage> {
  ContentBlocklist? _list;
  bool _failed = false;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ContentBlocklistService.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    ContentBlocklistService.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final list = await widget.service.load();
      if (mounted && generation == _generation) {
        setState(() {
          _list = list;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  Future<void> _remove(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取消屏蔽失败，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({
    required List<ContentBlockKind> kinds,
    ContentBlockRule? existing,
  }) async {
    if (_busy) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BlockRuleEditor(
        service: widget.service,
        kinds: kinds,
        existing: existing,
      ),
    );
    if (mounted && saved == true) await _reload();
  }

  Widget _sectionTitle(String title, {required bool creator}) => Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      TextButton.icon(
        key: Key(creator ? 'add-creator-block-rule' : 'add-video-block-rule'),
        onPressed: _busy
            ? null
            : () => _edit(kinds: creator ? _creatorRules : _videoRules),
        icon: const Icon(Icons.add),
        label: Text(creator ? '添加 UP 主规则' : '添加视频规则'),
      ),
    ],
  );

  Widget _ruleRow(ContentBlockRule rule) => ListTile(
    key: ValueKey('block-rule-${rule.kind.name}-${rule.value}'),
    title: Text(rule.value),
    subtitle: Text(_kindLabel(rule.kind)),
    trailing: PopupMenuButton<bool>(
      tooltip: '管理规则',
      enabled: !_busy,
      onSelected: (edit) => edit
          ? _edit(kinds: [rule.kind], existing: rule)
          : _remove(() => widget.service.removeRule(rule)),
      itemBuilder: (_) => const [
        PopupMenuItem(value: true, child: Text('编辑规则')),
        PopupMenuItem(value: false, child: Text('删除规则')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final creatorRules = [
      if (list != null)
        for (final kind in _creatorRules.skip(1))
          for (final value in list.rules[kind] ?? const <String>[])
            ContentBlockRule(kind, value),
    ];
    final videoRules = [
      if (list != null)
        for (final kind in _videoRules)
          for (final value in list.rules[kind] ?? const <String>[])
            ContentBlockRule(kind, value),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('黑名单')),
      body: _failed
          ? Center(
              child: TextButton(
                onPressed: _reload,
                child: const Text('黑名单读取失败，点击重试'),
              ),
            )
          : list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('屏蔽只在本机搜索生效，不会删除收藏、学习清单、观看记录或笔记，也不会修改 B 站账号。'),
                const SizedBox(height: 12),
                _sectionTitle(
                  'UP 主（${list.creators.length + creatorRules.length}）',
                  creator: true,
                ),
                if (list.creators.isEmpty && creatorRules.isEmpty)
                  const ListTile(title: Text('暂无屏蔽的 UP 主')),
                for (final entry in list.creators.entries)
                  ListTile(
                    title: Text(
                      entry.value.isEmpty ? 'UID ${entry.key}' : entry.value,
                    ),
                    subtitle: Text(
                      entry.value.isEmpty
                          ? 'UID（精确）'
                          : 'UID ${entry.key} · 精确匹配',
                    ),
                    leading: IconButton(
                      key: Key('edit-creator-uid-${entry.key}'),
                      tooltip: '编辑 UID',
                      onPressed: _busy
                          ? null
                          : () => _edit(
                              kinds: const [ContentBlockKind.creatorUid],
                              existing: ContentBlockRule(
                                ContentBlockKind.creatorUid,
                                '${entry.key}',
                              ),
                            ),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    trailing: IconButton(
                      key: Key('unblock-creator-${entry.key}'),
                      tooltip: '取消屏蔽',
                      onPressed: _busy
                          ? null
                          : () => _remove(
                              () => widget.service.unblockCreator(entry.key),
                            ),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ),
                for (final rule in creatorRules) _ruleRow(rule),
                const Divider(height: 32),
                _sectionTitle(
                  '视频（${list.videos.length + videoRules.length}）',
                  creator: false,
                ),
                if (list.videos.isEmpty && videoRules.isEmpty)
                  const ListTile(title: Text('暂无屏蔽的视频')),
                for (final entry in list.videos.entries)
                  ListTile(
                    title: Text(entry.value.isEmpty ? entry.key : entry.value),
                    subtitle: Text(entry.key),
                    trailing: IconButton(
                      key: Key('unblock-video-${entry.key}'),
                      tooltip: '取消屏蔽',
                      onPressed: _busy
                          ? null
                          : () => _remove(
                              () => widget.service.unblockVideo(entry.key),
                            ),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ),
                for (final rule in videoRules) _ruleRow(rule),
              ],
            ),
    );
  }
}

class _BlockRuleEditor extends StatefulWidget {
  const _BlockRuleEditor({
    required this.service,
    required this.kinds,
    required this.existing,
  });

  final ContentBlocklistService service;
  final List<ContentBlockKind> kinds;
  final ContentBlockRule? existing;

  @override
  State<_BlockRuleEditor> createState() => _BlockRuleEditorState();
}

class _BlockRuleEditorState extends State<_BlockRuleEditor> {
  late final TextEditingController _value = TextEditingController(
    text: widget.existing?.value,
  );
  late ContentBlockKind _kind = widget.existing?.kind ?? widget.kinds.first;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.saveRule(
        ContentBlockRule(_kind, _value.text),
        previous: widget.existing,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is ArgumentError
            ? '${error.message}'
            : '规则未保存，请检查本机存储后重试。';
      });
    }
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.existing == null ? '添加屏蔽规则' : '编辑屏蔽规则'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.kinds.length > 1)
            DropdownButtonFormField<ContentBlockKind>(
              key: const Key('block-rule-kind'),
              initialValue: _kind,
              isExpanded: true,
              isDense: false,
              decoration: const InputDecoration(labelText: '匹配方式'),
              items: [
                for (final kind in widget.kinds)
                  DropdownMenuItem(value: kind, child: Text(_kindLabel(kind))),
              ],
              onChanged: _saving
                  ? null
                  : (kind) {
                      if (kind == null) return;
                      setState(() {
                        _kind = kind;
                        _error = null;
                      });
                    },
            )
          else
            Text(_kindLabel(_kind)),
          const SizedBox(height: 12),
          Text(_kindHelp(_kind)),
          if (_kind != ContentBlockKind.creatorUid)
            const Text('不区分大小写，忽略首尾空格。'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('block-rule-value'),
            controller: _value,
            enabled: !_saving,
            keyboardType: _kind == ContentBlockKind.creatorUid
                ? TextInputType.number
                : TextInputType.text,
            onSubmitted: (_) => _save(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: _kind == ContentBlockKind.creatorUid ? 'UID' : '规则内容',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-block-rule'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
