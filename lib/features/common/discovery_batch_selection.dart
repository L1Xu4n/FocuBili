import 'package:flutter/material.dart';

import '../../core/widgets/drag_selection_region.dart';

/// A draft over the currently visible, selectable rows of a video list.
class DiscoveryBatchSelection {
  bool active = false;
  final ids = <String>{};
  int epoch = 0;
  List<String> _projection = const [];
  Set<String> _beforeDrag = {};

  void close() {
    active = false;
    ids.clear();
    _beforeDrag.clear();
  }

  /// Paging may append to the projection without interrupting a sweep. If a
  /// filter or re-order remaps any index, invalidate the old gesture, retaining only still-visible IDs.
  void sync(Iterable<String> visibleIds) {
    final next = visibleIds.toList(growable: false);
    final sharedLength = _projection.length;
    if (next.length < sharedLength ||
        Iterable<int>.generate(
          sharedLength,
        ).any((i) => next[i] != _projection[i])) {
      epoch++;
      ids.retainAll(next);
      _beforeDrag.clear();
    }
    _projection = next;
  }

  void reset() {
    epoch++;
    close();
    _projection = const [];
  }

  void start([String? id]) {
    active = true;
    if (id != null) ids.add(id);
  }

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
  }

  void range(DragSelectionUpdate update, List<String> projection) {
    if (update.anchor == update.previous && update.previous == update.current) {
      _beforeDrag = {...ids};
    }
    final lo = update.anchor < update.current ? update.anchor : update.current;
    final hi = update.anchor > update.current ? update.anchor : update.current;
    ids
      ..clear()
      ..addAll(_beforeDrag);
    for (var i = lo; i <= hi; i++) {
      final id = projection[i];
      if (update.checked) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
    }
  }
}

/// Only offers saving. Selection must not turn a read-only list into one
/// that can mutate its source or perform destructive account actions.
class DiscoveryBatchSelectionBar extends StatelessWidget {
  const DiscoveryBatchSelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    required this.onSave,
  });

  final int count;
  final VoidCallback? onClose;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Row(
      children: [
        IconButton(
          tooltip: '退出多选',
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
        ),
        Expanded(child: Text('已选 $count 支视频', overflow: TextOverflow.ellipsis)),
        FilledButton.tonal(onPressed: onSave, child: const Text('添加到')),
        const SizedBox(width: 8),
      ],
    ),
  );
}
