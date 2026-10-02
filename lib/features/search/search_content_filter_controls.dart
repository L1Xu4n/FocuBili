import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/search_content_filter.dart';

/// Stable input state for the search sheet's local filtering options.
class SearchContentFilterControls extends StatefulWidget {
  /// Receives a draft; persistence happens only when the parent sheet is applied.
  const SearchContentFilterControls({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final SearchContentFilter value;
  final ValueChanged<SearchContentFilter> onChanged;

  /// Creates the controller once so IME composing text survives rebuilds.
  @override
  State<SearchContentFilterControls> createState() =>
      _SearchContentFilterControlsState();
}

class _SearchContentFilterControlsState
    extends State<SearchContentFilterControls> {
  static const _stops = [
    0,
    1000,
    10000,
    50000,
    100000,
    500000,
    1000000,
    10000000,
  ];
  late final TextEditingController _count;

  /// Seeds the numeric input from persisted or previously edited settings.
  @override
  void initState() {
    super.initState();
    _count = TextEditingController(text: '${widget.value.minimumPlayCount}');
  }

  /// Reflects an explicit reset without rewriting equivalent actively edited text.
  @override
  void didUpdateWidget(covariant SearchContentFilterControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value.minimumPlayCount != widget.value.minimumPlayCount &&
        int.tryParse(_count.text) != widget.value.minimumPlayCount) {
      _count.text = '${widget.value.minimumPlayCount}';
    }
  }

  /// Releases the input controller when the sheet closes.
  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  /// Uses the nearest preset for custom values without changing the exact input.
  int _sliderIndex() {
    var best = 0;
    for (var i = 1; i < _stops.length; i++) {
      if ((_stops[i] - widget.value.minimumPlayCount).abs() <
          (_stops[best] - widget.value.minimumPlayCount).abs()) {
        best = i;
      }
    }
    return best;
  }

  /// Validates custom limits instead of silently applying a stale previous number.
  String? _validate(String? text) {
    final value = int.tryParse(text ?? '');
    return value == null ||
            value < 0 ||
            value > SearchContentFilter.maximumPlayCount
        ? '请输入 0 到 2000000000 的整数'
        : null;
  }

  /// Combines a binary learning switch, a preset slider and an exact numeric field.
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile.adaptive(
        key: const Key('search-learning-only'),
        contentPadding: EdgeInsets.zero,
        title: const Text('仅显示学习内容'),
        value: widget.value.learningOnly,
        onChanged: (value) =>
            widget.onChanged(widget.value.copyWith(learningOnly: value)),
      ),
      const SizedBox(height: 8),
      Text('最低播放量', style: Theme.of(context).textTheme.titleMedium),
      Slider(
        key: const Key('search-play-count-slider'),
        min: 0,
        max: (_stops.length - 1).toDouble(),
        divisions: _stops.length - 1,
        value: _sliderIndex().toDouble(),
        label: widget.value.minimumPlayCount == 0
            ? '不限'
            : '${widget.value.minimumPlayCount}',
        onChanged: (value) {
          final count = _stops[value.round()];
          _count.text = '$count';
          widget.onChanged(widget.value.copyWith(minimumPlayCount: count));
        },
      ),
      TextFormField(
        key: const Key('search-play-count-input'),
        controller: _count,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(10),
        ],
        decoration: const InputDecoration(
          labelText: '自定义最低播放量',
          suffixText: '次',
          hintText: '0 表示不限',
        ),
        validator: _validate,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        onChanged: (value) {
          if (_validate(value) == null) {
            widget.onChanged(
              widget.value.copyWith(minimumPlayCount: int.parse(value)),
            );
          }
        },
      ),
    ],
  );
}
