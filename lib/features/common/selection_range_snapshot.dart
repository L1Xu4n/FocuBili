import 'package:flutter/foundation.dart';

import '../../core/widgets/drag_selection_region.dart';

/// Recomputes a checkbox range from its original selection. If filtering or a
/// refresh changes the order, the former indexes must not select new rows.
class SelectionRangeSnapshot {
  List<String>? _orderedIds;
  Set<String> _beforeDrag = const {};

  void clear() {
    _orderedIds = null;
    _beforeDrag = const {};
  }

  Set<String>? apply(
    DragSelectionUpdate update,
    List<String> orderedIds,
    Set<String> selected,
  ) {
    if (update.anchor == update.previous && update.previous == update.current) {
      _orderedIds = List.unmodifiable(orderedIds);
      _beforeDrag = {...selected};
    }
    final first = update.anchor < update.current
        ? update.anchor
        : update.current;
    final last = update.anchor > update.current
        ? update.anchor
        : update.current;
    if (first < 0 ||
        last >= orderedIds.length ||
        !listEquals(_orderedIds, orderedIds)) {
      clear();
      return null;
    }
    final ids = orderedIds.getRange(first, last + 1);
    if (update.checked) return {..._beforeDrag, ...ids};
    return {..._beforeDrag}..removeAll(ids);
  }
}
