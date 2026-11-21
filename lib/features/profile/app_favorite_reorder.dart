import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

typedef _FavoriteDrag = ({Object owner, String id});

/// Previews local favorite order in the existing adaptive list. The viewport,
/// not a moving card, accepts the drop, so dragging across columns or holding
/// at a scroll edge does not leave a stale per-card drop target.
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
  final Future<void> Function(List<String>) onReorder;
  final VoidCallback? onDragStarted;
  final Widget Function(BuildContext context, AppFavoriteReorderState reorder)
  builder;

  @override
  State<AppFavoriteReorder> createState() => AppFavoriteReorderState();
}

class AppFavoriteReorderState extends State<AppFavoriteReorder> {
  static const _edgeZone = 48.0;
  final _slots = <int, GlobalKey>{};
  final _cards = <String, GlobalKey>{};
  List<String>? _preview;
  List<String>? _saving;
  String? _dragging;
  int? _target;
  Offset? _pointer;
  ScrollableState? _scrollable;
  EdgeDraggingAutoScroller? _autoScroller;

  List<String> get ids => _preview ?? _saving ?? widget.ids;
  bool get _enabled =>
      widget.enabled && widget.ids.length > 1 && _saving == null;

  @override
  void didUpdateWidget(covariant AppFavoriteReorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final orderChanged = !listEquals(widget.ids, oldWidget.ids);
    if (!widget.enabled || orderChanged) _resetDrag();
    if (orderChanged) _saving = null;
    final ids = widget.ids.toSet();
    _cards.removeWhere((id, _) => !ids.contains(id));
    _slots.removeWhere((index, _) => index >= ids.length);
  }

  @override
  void dispose() {
    _resetDrag();
    super.dispose();
  }

  int? _slotAt(Offset pointer) {
    for (final entry in _slots.entries) {
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

  List<String> _orderWith(String source, int target) {
    final order = widget.ids.toList();
    order.insert(target, order.removeAt(order.indexOf(source)));
    return order;
  }

  Future<void> _commit(List<String> order) async {
    setState(() {
      _resetDrag();
      // Keep the final preview in place while the service saves and reloads.
      _saving = order;
    });
    try {
      await widget.onReorder(order);
    } finally {
      if (mounted && identical(_saving, order)) setState(() => _saving = null);
    }
  }

  void _move(String source, String target) {
    if (!_enabled || _dragging != null || source == target) return;
    final index = widget.ids.indexOf(target);
    if (index != -1 && widget.ids.contains(source)) {
      unawaited(_commit(_orderWith(source, index)));
    }
  }

  void _start(BuildContext context, String id) {
    setState(() {
      _dragging = id;
      _target = widget.ids.indexOf(id);
      _scrollable = Scrollable.of(context);
    });
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

  void _updatePreview() {
    final pointer = _pointer;
    final source = _dragging;
    if (!mounted || !_enabled || pointer == null || source == null) return;
    final slot = _slotAt(pointer);
    // Read the stable display slot, not the ID of whichever card currently
    // occupies it. Repeated moves in one slot must not reorder back and forth.
    if (slot == null || slot == _target) return;
    setState(() {
      _target = slot;
      _preview = _orderWith(source, slot);
    });
  }

  void _stopTracking() {
    _pointer = null;
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
  }

  void _resetDrag() {
    _stopTracking();
    _dragging = null;
    _target = null;
    _preview = null;
    _scrollable = null;
  }

  void _end(String id) {
    if (mounted && _dragging == id) setState(_resetDrag);
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 && _pointer != null) {
            // The pointer can be stationary while new slots scroll under it.
            // Measure after layout, including during an auto-scroll step.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _updatePreview(),
            );
          }
          return false;
        },
        child: _dropTarget(),
      );

  Widget _dropTarget() => DragTarget<_FavoriteDrag>(
    onWillAcceptWithDetails: (details) =>
        _enabled && identical(details.data.owner, this),
    onMove: (details) {
      if (!_enabled ||
          !identical(details.data.owner, this) ||
          _dragging != details.data.id) {
        return;
      }
      _pointer = details.offset;
      _updatePreview();
      _scrollAtPointer();
    },
    onLeave: (data) {
      if (!identical(data?.owner, this) || data?.id != _dragging) return;
      _stopTracking();
      if (_preview != null) {
        setState(() {
          _preview = null;
          _target = widget.ids.indexOf(_dragging!);
        });
      }
    },
    onAcceptWithDetails: (details) {
      if (!identical(details.data.owner, this) ||
          _dragging != details.data.id) {
        return;
      }
      final order = _preview;
      if (_enabled && order != null && !listEquals(order, widget.ids)) {
        unawaited(_commit(order));
      } else {
        _end(details.data.id);
      }
    },
    builder: (context, _, _) => widget.builder(context, this),
  );

  /// Reparents only the card (not the measured slot) as the draft order changes.
  /// The source still lays out invisibly to reserve its normal size in the list.
  Widget row({
    required int index,
    required String id,
    required String title,
    required Key handleKey,
    required Widget Function(Widget? handle, {required bool preview}) builder,
  }) {
    final previous = index > 0 ? ids[index - 1] : null;
    final following = index + 1 < ids.length ? ids[index + 1] : null;
    return SizedBox(
      key: _slots.putIfAbsent(index, GlobalKey.new),
      width: double.infinity,
      child: LayoutBuilder(
        key: _cards.putIfAbsent(id, GlobalKey.new),
        builder: (context, constraints) {
          final dragging = id == _dragging;
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          final handle = _enabled
              ? _FavoriteDragHandle(
                  key: handleKey,
                  canStart: () => mounted && _enabled && _dragging == null,
                  data: (owner: this, id: id),
                  onDragStarted: () => _start(context, id),
                  // Unlike onDragEnd, these fire if the row scrolled away.
                  onDragCompleted: () => _end(id),
                  onDraggableCanceled: (_, _) => _end(id),
                  feedback: FractionalTranslation(
                    translation: Offset(rtl ? 0 : -1, -.5),
                    child: Transform.translate(
                      // Keep the handle aligned with the pointer on either side.
                      offset: Offset(rtl ? -28 : 28, 0),
                      child: SizedBox(
                        key: ValueKey('app-favorite-reorder-proxy-$id'),
                        width: constraints.maxWidth,
                        child: Theme(
                          data: theme.copyWith(
                            cardTheme: theme.cardTheme.copyWith(
                              color: scheme.secondaryContainer,
                              elevation: 8,
                            ),
                          ),
                          child: builder(_handleIcon, preview: true),
                        ),
                      ),
                    ),
                  ),
                  child: Semantics(
                    label: '拖动排序：$title',
                    tooltip: '拖动排序（触屏长按）',
                    customSemanticsActions: {
                      if (previous != null)
                        const CustomSemanticsAction(label: '上移'): () =>
                            _move(id, previous),
                      if (following != null)
                        const CustomSemanticsAction(label: '下移'): () =>
                            _move(id, following),
                    },
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: _handleIcon,
                    ),
                  ),
                )
              : null;
          final card = builder(handle, preview: false);
          return Stack(
            children: [
              Visibility(
                visible: !dragging,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: card,
              ),
              if (dragging)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: DecoratedBox(
                      key: ValueKey('app-favorite-reorder-gap-$id'),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: .08),
                        border: Border.all(color: scheme.primary, width: 2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static const _handleIcon = SizedBox.square(
    dimension: 48,
    child: Icon(Icons.drag_handle_rounded),
  );
}

class _FavoriteDragHandle extends Draggable<_FavoriteDrag> {
  const _FavoriteDragHandle({
    super.key,
    required this.canStart,
    required super.data,
    required super.onDragStarted,
    required super.onDragCompleted,
    required super.onDraggableCanceled,
    required super.feedback,
    required super.child,
  }) : super(
         dragAnchorStrategy: pointerDragAnchorStrategy,
         hitTestBehavior: HitTestBehavior.opaque,
         maxSimultaneousDrags: 1,
       );

  final bool Function() canStart;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _FavoriteDragRecognizer(
        allowedButtonsFilter: (buttons) =>
            buttons == kPrimaryButton && canStart(),
      )
      ..onStart = (position) {
        if (!canStart()) return null;
        final drag = onStart(position);
        if (drag != null) unawaited(HapticFeedback.selectionClick());
        return drag;
      };
  }
}

class _FavoriteDragRecognizer extends DelayedMultiDragGestureRecognizer {
  _FavoriteDragRecognizer({super.allowedButtonsFilter});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return event.kind == PointerDeviceKind.mouse
        ? _MouseDragPointer(event.position, event.kind, gestureSettings)
        : super.createNewPointerState(event);
  }
}

class _MouseDragPointer extends MultiDragPointerState {
  _MouseDragPointer(super.initialPosition, super.kind, super.gestureSettings);

  GestureMultiDragStartCallback? _starter;

  bool get _hasMoved =>
      pendingDelta!.distance > computeHitSlop(kind, gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    if (!_hasMoved) return;
    final starter = _starter;
    if (starter == null) {
      resolve(GestureDisposition.accepted);
    } else {
      _starter = null;
      starter(initialPosition);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    // A lone recognizer can win on pointer down. Still wait for real movement
    // in that case, so clicking the desktop handle does not lift the card.
    if (_hasMoved) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }
}
