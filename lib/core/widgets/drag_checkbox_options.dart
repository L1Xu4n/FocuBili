import 'package:flutter/material.dart';

import 'drag_selection_region.dart';

/// Gives a custom checkbox list the same sweep behavior as DragCheckboxList
/// without changing its use of subtitles, decorative rows, or a scroll view.
class DragCheckboxOptions extends StatefulWidget {
  const DragCheckboxOptions({
    super.key,
    required this.itemCount,
    required this.checkedAt,
    required this.onRangeChanged,
    required this.builder,
    this.enabled = true,
  });

  final int itemCount;
  final bool Function(int index) checkedAt;

  /// Applies one value to the inclusive interval. If it crosses a decorative
  /// or unavailable row, the caller should skip that row.
  final void Function(int first, int last, bool checked) onRangeChanged;
  final Widget Function(
    BuildContext context,
    ScrollController controller,
    ScrollPhysics? physics,
  )
  builder;
  final bool enabled;

  @override
  State<DragCheckboxOptions> createState() => _DragCheckboxOptionsState();
}

class _DragCheckboxOptionsState extends State<DragCheckboxOptions> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragSelectionRegion(
    controller: _controller,
    itemCount: widget.itemCount,
    checkedAt: widget.checkedAt,
    enabled: widget.enabled,
    onDragUpdate: (update) {
      final previous = update.previous, current = update.current;
      widget.onRangeChanged(
        previous < current ? previous : current,
        previous > current ? previous : current,
        update.checked,
      );
    },
    builder: (context, dragging) => widget.builder(
      context,
      _controller,
      dragging ? const NeverScrollableScrollPhysics() : null,
    ),
  );
}

/// A checkbox row with one accessible and keyboard-focusable control. Only
/// the checkbox starts a sweep. Omit [index] for a row that is tap-only.
class DragCheckboxTile extends StatelessWidget {
  const DragCheckboxTile({
    super.key,
    this.index,
    required this.value,
    required this.title,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.dense,
    this.shape,
    this.contentPadding,
  });

  final int? index;
  final bool value;
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final ValueChanged<bool>? onChanged;
  final bool? dense;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    Widget row(BuildContext context, Key? handleKey) => MergeSemantics(
      child: ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        dense: dense,
        shape: shape,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: ExcludeFocus(
          child: Checkbox(
            key: handleKey,
            value: value,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: onChanged == null
                ? null
                : (checked) => onChanged!(checked == true),
          ),
        ),
      ),
    );

    final index = this.index;
    return index == null || onChanged == null
        ? row(context, null)
        : DragSelectionTarget(index: index, builder: row);
  }
}
