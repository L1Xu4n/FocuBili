import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

typedef _FavoriteDrag = ({Object owner, String id});

/// Local-only reordering for the existing adaptive single- and two-column lists.
/// The viewport is the drop target so scrolling beneath a stationary pointer
/// never commits to a row that was previously under it.
class AppFavoriteReorder extends StatefulWidget {
  const AppFavoriteReorder({
    super.key,
    required this.ids,
    required this.enabled,
    required this.onReorder,
    this.onDragStarted,
    required this.builder,
  });

  final List<String> ids;
  final bool enabled;
  final ValueChanged<List<String>> onReorder;
  final VoidCallback? onDragStarted;
  final Widget Function(BuildContext context, AppFavoriteReorderState reorder)
  builder;

  @override
  State<AppFavoriteReorder> createState() => AppFavoriteReorderState();
}

class AppFavoriteReorderState extends State<AppFavoriteReorder> {
  static const _edgeZone = 48.0;
  final _bounds = <String, GlobalKey>{};
  final _highlight = ValueNotifier<String?>(null);
  String? _dragging;
  Offset? _pointer;
  ScrollableState? _scrollable;
  EdgeDraggingAutoScroller? _autoScroller;

  bool get _enabled => widget.enabled && widget.ids.length > 1;

  @override
  void didUpdateWidget(covariant AppFavoriteReorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || !listEquals(widget.ids, oldWidget.ids)) {
      _finish();
    }
    final ids = widget.ids.toSet();
    _bounds.removeWhere((id, _) => !ids.contains(id));
  }

  @override
  void dispose() {
    _autoScroller?.stopAutoScroll();
    _highlight.dispose();
    super.dispose();
  }

  String? _rowAt(Offset pointer) {
    for (final entry in _bounds.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          (Offset.zero & box.size).contains(box.globalToLocal(pointer))) {
        return entry.key;
      }
    }
    return null;
  }

  void _move(String source, String target) {
    if (!_enabled || source == target) return;
    final ids = widget.ids.toList();
    final from = ids.indexOf(source);
    final to = ids.indexOf(target);
    if (from == -1 || to == -1) return;
    ids.insert(to, ids.removeAt(from));
    widget.onReorder(ids);
  }

  void _start(BuildContext context, String id) {
    if (!_enabled || _dragging != null) return;
    _dragging = id;
    _scrollable = Scrollable.of(context);
    widget.onDragStarted?.call();
  }

  EdgeDraggingAutoScroller _createAutoScroller(ScrollableState scrollable) {
    late final EdgeDraggingAutoScroller scroller;
    scroller = EdgeDraggingAutoScroller(
      scrollable,
      velocityScalar: 12,
      onScrollViewScrolled: () {
        if (!mounted || !identical(_autoScroller, scroller)) return;
        // Flutter stores the supplied rect relative to the scroll origin.
        // Re-anchor it after each step even if the user's pointer is stationary.
        _scrollAtPointer();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (identical(_autoScroller, scroller)) _updateHighlight();
        });
      },
    );
    return scroller;
  }

  void _scrollAtPointer() {
    final pointer = _pointer;
    final scrollable = _scrollable;
    if (pointer == null || scrollable == null || !scrollable.mounted) return;
    final position = scrollable.position;
    if (!position.hasViewportDimension || position.viewportDimension <= 0) {
      return;
    }
    final scroller = _autoScroller ??= _createAutoScroller(scrollable);
    scroller.startAutoScrollIfNecessary(
      Rect.fromCenter(
        center: pointer,
        width: 1,
        height: position.viewportDimension.clamp(0.0, _edgeZone * 2).toDouble(),
      ),
    );
  }

  void _updateHighlight() {
    final pointer = _pointer;
    if (!mounted || pointer == null) return;
    final id = _rowAt(pointer);
    _highlight.value = id == _dragging ? null : id;
  }

  void _leave() {
    _pointer = null;
    _highlight.value = null;
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
  }

  void _finish() {
    _leave();
    _dragging = null;
    _scrollable = null;
  }

  void _end(String id) {
    if (mounted && _dragging == id) _finish();
  }

  @override
  Widget build(BuildContext context) => DragTarget<_FavoriteDrag>(
    onWillAcceptWithDetails: (details) =>
        _enabled && identical(details.data.owner, this),
    onMove: (details) {
      if (!_enabled ||
          !identical(details.data.owner, this) ||
          _dragging != details.data.id) {
        return;
      }
      _pointer = details.offset;
      _updateHighlight();
      _scrollAtPointer();
    },
    onLeave: (data) {
      if (identical(data?.owner, this) && data?.id == _dragging) _leave();
    },
    onAcceptWithDetails: (details) {
      if (!identical(details.data.owner, this) ||
          _dragging != details.data.id) {
        return;
      }
      final target = _rowAt(details.offset);
      _finish();
      if (target != null) _move(details.data.id, target);
    },
    builder: (context, _, _) => widget.builder(context, this),
  );

  /// Builds an isolated handle (not an ancestor of the row's tap/long press).
  /// Keep row bounds under the list and the drag avatar in Flutter's overlay.
  Widget row({
    required BuildContext context,
    required String id,
    required String title,
    required Key handleKey,
    required Widget Function(Widget? handle) builder,
  }) {
    if (!_enabled) return builder(null);
    final index = widget.ids.indexOf(id);
    final previous = index > 0 ? widget.ids[index - 1] : null;
    final following = index + 1 < widget.ids.length
        ? widget.ids[index + 1]
        : null;
    final scheme = Theme.of(context).colorScheme;
    final handle = LongPressDraggable<_FavoriteDrag>(
      key: handleKey,
      data: (owner: this, id: id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      hitTestBehavior: HitTestBehavior.opaque,
      allowedButtonsFilter: (buttons) =>
          buttons == kPrimaryButton && _enabled && _dragging == null,
      onDragStarted: () => _start(context, id),
      // Unlike onDragEnd, these also fire when the source row was recycled.
      onDragCompleted: () => _end(id),
      onDraggableCanceled: (_, _) => _end(id),
      feedback: FractionalTranslation(
        translation: const Offset(-1, -.5),
        child: Material(
          elevation: 4,
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 164,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                title,
                style: TextStyle(color: scheme.onSecondaryContainer),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
      child: Semantics(
        label: '拖动排序：$title',
        customSemanticsActions: {
          if (previous != null)
            const CustomSemanticsAction(label: '上移'): () => _move(id, previous),
          if (following != null)
            const CustomSemanticsAction(label: '下移'): () =>
                _move(id, following),
        },
        child: const MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Tooltip(
            triggerMode: TooltipTriggerMode.manual,
            excludeFromSemantics: true,
            message: '长按拖动排序',
            child: SizedBox.square(
              dimension: 48,
              child: Icon(Icons.drag_handle_rounded),
            ),
          ),
        ),
      ),
    );
    return ValueListenableBuilder<String?>(
      key: _bounds.putIfAbsent(id, GlobalKey.new),
      valueListenable: _highlight,
      child: builder(handle),
      builder: (context, target, child) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: target == id
              ? Border.all(color: scheme.primary, width: 2)
              : null,
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      ),
    );
  }
}
