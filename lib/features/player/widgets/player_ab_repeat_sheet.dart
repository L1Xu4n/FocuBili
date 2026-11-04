import 'package:flutter/material.dart';
import '../../../models/ab_repeat_range.dart';

/// Edits chapter-local points. Opening or dismissing the sheet does not seek.
class PlayerAbRepeatSheet extends StatefulWidget {
  const PlayerAbRepeatSheet({
    super.key,
    required this.bvid,
    required this.cid,
    required this.duration,
    required this.readPosition,
    required this.onApply,
    required this.onClear,
    this.initialRange,
    this.resumeFullLoop = false,
    this.inline = false,
    this.draftA,
    this.draftB,
    this.onDraftChanged,
    this.onClose,
  });
  final String bvid;
  final int cid;
  final Duration duration;
  final Duration Function() readPosition;
  final AbRepeatRange? initialRange;
  final bool resumeFullLoop;
  final ValueChanged<AbRepeatRange> onApply;
  final VoidCallback onClear;
  final bool inline;
  final String? draftA;
  final String? draftB;
  final void Function(String a, String b)? onDraftChanged;
  final VoidCallback? onClose;

  /// 创建仅持有编辑控件的状态；草稿由播放器拥有。
  @override
  State<PlayerAbRepeatSheet> createState() => _PlayerAbRepeatSheetState();
}

class _PlayerAbRepeatSheetState extends State<PlayerAbRepeatSheet> {
  late final TextEditingController _a;
  late final TextEditingController _b;
  String? _error;
  bool _editingTimes = false;

  /// 初始化一次标记，不因播放进度更新而覆盖用户草稿。
  @override
  void initState() {
    super.initState();
    _a = TextEditingController(
      text:
          widget.draftA ??
          formatAbRepeatTime(widget.initialRange?.a ?? widget.readPosition()),
    );
    _b = TextEditingController(
      text:
          widget.draftB ??
          (widget.initialRange == null
              ? ''
              : formatAbRepeatTime(widget.initialRange!.b)),
    );
    _a.addListener(_saveDraft);
    _b.addListener(_saveDraft);
  }

  /// 每次输入立即把草稿交给页面，收起和重开仍保留尚未启用的标记。
  void _saveDraft() => widget.onDraftChanged?.call(_a.text, _b.text);

  /// 释放两个输入控件。
  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  /// 验证完整区间后启用；标记不完整时保留草稿。
  void _apply() {
    final a = parseAbRepeatTime(_a.text);
    final b = parseAbRepeatTime(_b.text);
    if (a == null || b == null) {
      setState(() => _error = '请输入秒数、分:秒或时:分:秒，例如 01:23.500。');
      return;
    }
    final range = AbRepeatRange(bvid: widget.bvid, cid: widget.cid, a: a, b: b);
    final error = range.validate(widget.duration);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    widget.onApply(range);
    _close();
  }

  /// 内嵌编辑器只收起自身，独立面板才弹出路由。
  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// 显示精确时间输入与当前点标记按钮。
  Widget _point(String name, TextEditingController controller) => Row(
    children: [
      Expanded(
        child: TextField(
          key: Key('ab-repeat-$name-input'),
          controller: controller,
          keyboardType: TextInputType.datetime,
          decoration: InputDecoration(
            labelText: '$name 点',
            hintText: '分:秒',
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton(
        key: Key('ab-repeat-set-$name'),
        tooltip: '当前点设为 $name',
        onPressed: () => setState(() {
          controller.text = formatAbRepeatTime(widget.readPosition());
          _error = null;
        }),
        icon: const Icon(Icons.my_location_rounded),
      ),
    ],
  );

  /// 紧凑编辑器不添加遮罩，进度条和画面仍能操作。
  Widget _inlineEditor(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              TextButton(
                key: const Key('ab-repeat-set-A'),
                // 标记当前点，并更新紧凑条显示。
                onPressed: () => setState(
                  () => _a.text = formatAbRepeatTime(widget.readPosition()),
                ),
                child: Text('A ${_a.text}'),
              ),
              TextButton(
                key: const Key('ab-repeat-set-B'),
                // B 点可在拖动进度或继续播放之后再记录。
                onPressed: () => setState(
                  () => _b.text = formatAbRepeatTime(widget.readPosition()),
                ),
                child: Text('B ${_b.text.isEmpty ? "标记" : _b.text}'),
              ),
              IconButton(
                tooltip: '输入时间',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => setState(() => _editingTimes = !_editingTimes),
              ),
              IconButton(
                key: const Key('ab-repeat-apply'),
                tooltip: '启用区间循环',
                onPressed: _apply,
                icon: const Icon(Icons.repeat_rounded),
              ),
              if (widget.initialRange != null)
                IconButton(
                  key: const Key('ab-repeat-clear'),
                  tooltip: '清除区间',
                  onPressed: () {
                    widget.onClear();
                    _close();
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              const Tooltip(
                message: '标记 A 后可拖动视频，再标记 B。收起保留标记，切换内容清除。',
                child: Icon(Icons.info_outline, size: 18),
              ),
              IconButton(
                tooltip: '收起 A–B 设置',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (_editingTimes) ...[
            _point('A', _a),
            const SizedBox(height: 4),
            _point('B', _b),
          ],
          if (_error != null)
            Text(
              _error!,
              key: const Key('ab-repeat-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );

  /// 独立面板保留测试和复用入口，真实播放器使用紧凑内嵌模式。
  @override
  Widget build(BuildContext context) => widget.inline
      ? _inlineEditor(context)
      : SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'A–B 区间循环',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('当前分 P · ${formatAbRepeatTime(widget.duration)}'),
                  const SizedBox(height: 12),
                  _point('A', _a),
                  const SizedBox(height: 12),
                  _point('B', _b),
                  const SizedBox(height: 12),
                  const Text(
                    '到 B 点回到 A 点。暂停会保留区间；跳到区间外、切换分 P 或退出播放页会清除循环。听视频与画面使用同一区间。',
                  ),
                  Text(
                    widget.resumeFullLoop ? '退出区间后恢复原来的整片循环。' : '退出区间后恢复普通播放。',
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        key: const Key('ab-repeat-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('ab-repeat-apply'),
                    onPressed: _apply,
                    child: const Text('启用区间循环'),
                  ),
                  if (widget.initialRange != null)
                    TextButton(
                      key: const Key('ab-repeat-clear'),
                      onPressed: () {
                        widget.onClear();
                        _close();
                      },
                      child: const Text('清除区间，恢复原播放方式'),
                    ),
                ],
              ),
            ),
          ),
        );
}
