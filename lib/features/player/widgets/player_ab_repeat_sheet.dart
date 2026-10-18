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
  });
  final String bvid;
  final int cid;
  final Duration duration;
  final Duration Function() readPosition;
  final AbRepeatRange? initialRange;
  final bool resumeFullLoop;
  final ValueChanged<AbRepeatRange> onApply;
  final VoidCallback onClear;

  @override
  State<PlayerAbRepeatSheet> createState() => _PlayerAbRepeatSheetState();
}

class _PlayerAbRepeatSheetState extends State<PlayerAbRepeatSheet> {
  late final TextEditingController _a;
  late final TextEditingController _b;
  String? _error;
  @override
  void initState() {
    super.initState();
    _a = TextEditingController(
      text: formatAbRepeatTime(widget.initialRange?.a ?? widget.readPosition()),
    );
    _b = TextEditingController(
      text: widget.initialRange == null
          ? ''
          : formatAbRepeatTime(widget.initialRange!.b),
    );
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

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
    Navigator.of(context).pop();
  }

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
      TextButton(
        key: Key('ab-repeat-set-$name'),
        onPressed: () => setState(() {
          controller.text = formatAbRepeatTime(widget.readPosition());
          _error = null;
        }),
        child: Text('当前点设为 $name'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => SafeArea(
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
            Text('A–B 区间循环', style: Theme.of(context).textTheme.titleLarge),
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
            Text(widget.resumeFullLoop ? '退出区间后恢复原来的整片循环。' : '退出区间后恢复普通播放。'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('ab-repeat-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                  Navigator.of(context).pop();
                },
                child: const Text('清除区间，恢复原播放方式'),
              ),
          ],
        ),
      ),
    ),
  );
}
