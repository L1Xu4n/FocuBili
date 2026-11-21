import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/drag_selection_region.dart';

/// Selection shared only by the local favorite folder and watch history pages.
class LocalVideoListSelection {
  final ids = <String>{};
  bool active = false;
  List<String> _visibleIds = const [];
  Set<String> _beforeDrag = {};

  /// A changed projection cancels an old gesture before its indexes can be
  /// applied to different videos. Keep any selected video still on screen.
  void project(Iterable<String> idsInOrder) {
    final next = idsInOrder.toList(growable: false);
    if (listEquals(next, _visibleIds)) return;
    _visibleIds = next;
    ids.retainAll(next);
    _beforeDrag.clear();
  }

  void start([String? anchor]) {
    active = true;
    if (anchor != null) ids.add(anchor);
  }

  void end() {
    active = false;
    ids.clear();
    _beforeDrag.clear();
  }

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
  }

  void _apply(DragSelectionUpdate change) {
    if (change.anchor == change.previous && change.anchor == change.current) {
      _beforeDrag = {...ids};
    }
    final from = change.anchor < change.current
        ? change.anchor
        : change.current;
    final to = change.anchor > change.current ? change.anchor : change.current;
    ids
      ..clear()
      ..addAll(_beforeDrag);
    for (var i = from; i <= to; i++) {
      if (change.checked) {
        ids.add(_visibleIds[i]);
      } else {
        ids.remove(_visibleIds[i]);
      }
    }
  }

  Widget region({
    required ScrollController controller,
    required bool busy,
    required StateSetter setState,
    required Widget Function(BuildContext, bool) builder,
  }) {
    // Read the immutable projection captured by this region; a late callback
    // from the old region must not select from a newly filtered/reordered list.
    final visible = _visibleIds;
    return DragSelectionRegion(
      key: ObjectKey(visible),
      controller: controller,
      itemCount: visible.length,
      enabled: active && !busy,
      checkedAt: (index) => ids.contains(visible[index]),
      onDragUpdate: (change) {
        if (identical(visible, _visibleIds) && active) {
          setState(() => _apply(change));
        }
      },
      builder: builder,
    );
  }

  Widget checkbox({
    required Key handleKey,
    required String id,
    required String title,
    required VoidCallback? onToggle,
  }) => SizedBox.square(
    key: handleKey,
    dimension: 48,
    child: Checkbox(
      key: ValueKey('select-local-video-$id'),
      semanticLabel: '选择 $title',
      value: ids.contains(id),
      onChanged: onToggle == null ? null : (_) => onToggle(),
    ),
  );

  AppBar appBar({
    required VoidCallback? onExit,
    required VoidCallback? onRemove,
  }) => AppBar(
    leading: IconButton(
      tooltip: '退出多选',
      onPressed: onExit,
      icon: const Icon(Icons.close_rounded),
    ),
    title: Text('已选 ${ids.length} 项'),
    actions: [
      TextButton(
        onPressed: ids.isEmpty ? null : onRemove,
        child: const Text('移除所选'),
      ),
    ],
  );
}
