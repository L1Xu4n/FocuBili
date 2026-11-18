import 'package:flutter/material.dart';

import 'drag_selection_region.dart';

/// Lazily builds a vertical checkbox list with drag-to-paint selection.
/// It preserves one keyboard and accessibility stop per ordinary row.
class DragCheckboxList extends StatelessWidget {
  const DragCheckboxList({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.labelAt,
    required this.checkedAt,
    required this.onRangeChanged,
    this.enabled = true,
    this.scrollViewKey,
    this.header,
    this.groupTitleAt,
  });

  final ScrollController controller;
  final int itemCount;
  final String Function(int index) labelAt;
  final bool Function(int index) checkedAt;
  final String? Function(int index)? groupTitleAt;
  final bool enabled;
  final Key? scrollViewKey;
  final Widget? header;

  /// Applies the value to all indexes from first through last, inclusive.
  final void Function(int first, int last, bool selected) onRangeChanged;

  @override
  Widget build(BuildContext context) => DragSelectionRegion(
    controller: controller,
    itemCount: itemCount,
    checkedAt: checkedAt,
    enabled: enabled,
    onDragUpdate: (update) {
      final previous = update.previous, current = update.current;
      onRangeChanged(
        previous < current ? previous : current,
        previous > current ? previous : current,
        update.checked,
      );
    },
    builder: (context, dragging) => ListView.builder(
      key: scrollViewKey,
      controller: controller,
      physics: dragging ? const NeverScrollableScrollPhysics() : null,
      itemCount: itemCount + (header != null ? 1 : 0),
      itemBuilder: (context, item) {
        final index = item - (header != null ? 1 : 0);
        if (index < 0) return header!;
        final bool checked = checkedAt(index);
        final String? groupTitle = groupTitleAt?.call(index);
        final onChanged = enabled
            ? () => onRangeChanged(index, index, !checked)
            : null;
        final row = DragSelectionTarget(
          key: ValueKey(index),
          index: index,
          builder: (context, handleKey) => MergeSemantics(
            child: ListTile(
              title: Text(labelAt(index)),
              onTap: onChanged,
              enabled: enabled,
              trailing: ExcludeFocus(
                child: Checkbox(
                  key: handleKey,
                  value: checked,
                  onChanged: onChanged == null ? null : (_) => onChanged(),
                ),
              ),
            ),
          ),
        );
        if (groupTitle == null) return row;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Semantics(
                header: true,
                child: Text(
                  groupTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            row,
          ],
        );
      },
    ),
  );
}
