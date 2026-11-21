import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Lists report all positions as zero-based indexes in their loaded order.
typedef DragSelectionUpdate = ({
  int anchor,
  int previous,
  int current,
  bool checked,
});

/// Supplies checkbox-initiated range dragging to a scrollable list or grid.
///
/// Wrap each visible option in [DragSelectionTarget], giving it a stable
/// index in the loaded order. The caller owns selection and decides whether
/// to paint traversed items or recompute a range from the gesture's anchor.
class DragSelectionRegion extends StatefulWidget {
  const DragSelectionRegion({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.checkedAt,
    required this.onDragUpdate,
    required this.builder,
    this.enabled = true,
    this.itemOrderKey,
  });

  final ScrollController controller;
  final int itemCount;
  final bool Function(int index) checkedAt;
  final ValueChanged<DragSelectionUpdate> onDragUpdate;

  /// Builds the viewport. While dragging, disable ordinary scroll gestures
  /// (but not programmatic scrolling) so a second pointer cannot move it.
  final Widget Function(BuildContext context, bool dragging) builder;
  final bool enabled;

  /// Change this if existing indexes no longer refer to the same items.
  /// Appending items can keep this key unchanged to continue the gesture.
  final Object? itemOrderKey;

  @override
  State<DragSelectionRegion> createState() => _DragSelectionRegionState();
}

class _DragSelectionRegionState extends State<DragSelectionRegion>
    with SingleTickerProviderStateMixin {
  static const double _scrollZone = 48;
  static const double _maximumScrollSpeed = 760;

  final GlobalKey _viewportKey = GlobalKey();
  final _targets = <int, _DragSelectionTargetState>{};
  late final Ticker _autoScroll;
  int? _anchor;
  int? _lastIndex;
  Offset? _pointer;
  bool _dragValue = false;
  Duration _lastFrame = Duration.zero;

  @override
  void initState() {
    super.initState();
    _autoScroll = createTicker(_scrollOnFrame);
  }

  @override
  void didUpdateWidget(covariant DragSelectionRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Appending a page keeps indexes stable. A new controller or a shorter
    // list invalidates the former indexes. A caller can also invalidate
    // indexes without rebuilding the scrollable when it filters or reorders.
    if (!widget.enabled ||
        widget.itemCount < oldWidget.itemCount ||
        widget.controller != oldWidget.controller ||
        widget.itemOrderKey != oldWidget.itemOrderKey) {
      _clearDrag();
    } else if (_lastIndex != null && widget.itemCount > oldWidget.itemCount) {
      // A slow next page can arrive after the edge ticker has stopped at the
      // old maximum. Resume the same drag once the new rows have laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _lastIndex == null) return;
        _applyAtPointer();
        _syncTicker();
      });
    }
  }

  @override
  void dispose() {
    _autoScroll.dispose();
    super.dispose();
  }

  static Rect? _bounds(BuildContext? context) {
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? get _viewport => _bounds(_viewportKey.currentContext);

  bool _valid(int index) => index >= 0 && index < widget.itemCount;

  int? _checkboxAt(Offset point) {
    if (_viewport?.contains(point) != true) return null;
    for (final entry in _targets.entries) {
      if (_valid(entry.key) &&
          _bounds(entry.value._handleKey.currentContext)?.contains(point) ==
              true) {
        return entry.key;
      }
    }
    return null;
  }

  void _start(Offset point) {
    if (!widget.enabled || _lastIndex != null) return;
    final index = _checkboxAt(point);
    if (index == null) return;
    setState(() {
      _anchor = _lastIndex = index;
      _dragValue = !widget.checkedAt(index);
    });
    widget.onDragUpdate((
      anchor: index,
      previous: index,
      current: index,
      checked: _dragValue,
    ));
    // A stationary long press changes only its first checkbox. Edge scrolling
    // starts only after the pointer actually moves.
  }

  void _clearDrag() {
    if (_lastIndex == null) return;
    _autoScroll.stop();
    _anchor = _lastIndex = null;
    _pointer = null;
  }

  void _end() {
    if (_lastIndex != null) setState(_clearDrag);
  }

  void _move(Offset point) {
    if (_lastIndex == null || !widget.enabled) return;
    _pointer = point;
    _applyAtPointer();
    _syncTicker();
  }

  void _applyAtPointer() {
    final previous = _lastIndex;
    final anchor = _anchor;
    final point = _pointer;
    final viewport = _viewport;
    if (previous == null ||
        anchor == null ||
        point == null ||
        viewport == null ||
        viewport.height <= 0 ||
        !widget.enabled ||
        point.dx < viewport.left ||
        point.dx >= viewport.right) {
      return;
    }
    // Crossing the top/bottom edge tracks a visible option without letting
    // the list gesture activate controls outside the viewport.
    final probe = Offset(
      point.dx,
      point.dy.clamp(viewport.top, viewport.bottom - 0.01),
    );
    for (final entry in _targets.entries) {
      if (!_valid(entry.key) ||
          _bounds(entry.value.context)?.contains(probe) != true) {
        continue;
      }
      final index = entry.key;
      if (index == previous) return;
      _lastIndex = index;
      widget.onDragUpdate((
        anchor: anchor,
        previous: previous,
        current: index,
        checked: _dragValue,
      ));
      return;
    }
  }

  double _scrollSpeed() {
    final point = _pointer;
    final viewport = _viewport;
    if (!widget.enabled ||
        _lastIndex == null ||
        point == null ||
        viewport == null ||
        point.dx < viewport.left ||
        point.dx >= viewport.right ||
        !widget.controller.hasClients) {
      return 0;
    }
    final position = widget.controller.position;
    if (!position.hasContentDimensions) return 0;
    final zone = (viewport.height / 3).clamp(0.0, _scrollZone);
    if (zone <= 0) return 0;
    final fromTop = point.dy - viewport.top;
    final fromBottom = viewport.bottom - point.dy;
    if (fromTop < zone && position.pixels > position.minScrollExtent) {
      return -_maximumScrollSpeed * (1 - fromTop / zone).clamp(0.0, 1.0);
    }
    if (fromBottom < zone && position.pixels < position.maxScrollExtent) {
      return _maximumScrollSpeed * (1 - fromBottom / zone).clamp(0.0, 1.0);
    }
    return 0;
  }

  void _syncTicker() {
    if (_scrollSpeed() == 0) {
      _autoScroll.stop();
    } else if (!_autoScroll.isActive) {
      _lastFrame = Duration.zero;
      _autoScroll.start();
    }
  }

  void _scrollOnFrame(Duration elapsed) {
    final seconds =
        (elapsed - _lastFrame).inMicroseconds.clamp(0, 32000) /
        Duration.microsecondsPerSecond;
    _lastFrame = elapsed;
    final speed = _scrollSpeed();
    if (speed == 0) {
      _autoScroll.stop();
      return;
    }
    final position = widget.controller.position;
    final next = (position.pixels + speed * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    position.jumpTo(next);
    // Lazy lists need a layout pass before newly visible rows can be hit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyAtPointer();
    });
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      // Own recognition at list level so recycling the first row does not
      // end the gesture. Ordinary tap and scroll still use Flutter's arena.
      excludeFromSemantics: true,
      gestures: {
        _CheckboxLongPress:
            GestureRecognizerFactoryWithHandlers<_CheckboxLongPress>(
              _CheckboxLongPress.new,
              (recognizer) {
                recognizer.canStart = (point) =>
                    widget.enabled &&
                    _lastIndex == null &&
                    _checkboxAt(point) != null;
                recognizer.onLongPressStart = (details) =>
                    _start(details.globalPosition);
                recognizer.onLongPressMoveUpdate = (details) =>
                    _move(details.globalPosition);
                recognizer.onLongPressEnd = (_) => _end();
                recognizer.onPointerCanceled = _end;
              },
            ),
      },
      child: _DragSelectionScope(
        region: this,
        child: KeyedSubtree(
          key: _viewportKey,
          child: widget.builder(context, _lastIndex != null),
        ),
      ),
    );
  }
}

class _CheckboxLongPress extends LongPressGestureRecognizer {
  bool Function(Offset point)? canStart;
  VoidCallback? onPointerCanceled;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      super.isPointerAllowed(event) && canStart?.call(event.position) == true;

  @override
  void handlePrimaryPointer(PointerEvent event) {
    super.handlePrimaryPointer(event);
    // OS cancellation after acceptance does not invoke onLongPressEnd.
    if (event is PointerCancelEvent) onPointerCanceled?.call();
  }
}

class _DragSelectionScope extends InheritedWidget {
  const _DragSelectionScope({required this.region, required super.child});

  final _DragSelectionRegionState region;

  @override
  bool updateShouldNotify(_DragSelectionScope oldWidget) =>
      oldWidget.region != region;
}

/// Marks a row or card in a [DragSelectionRegion]. Place [handleKey] on
/// the checkbox widget (or an exact-size wrapper), not the whole row.
class DragSelectionTarget extends StatefulWidget {
  const DragSelectionTarget({
    super.key,
    required this.index,
    required this.builder,
  });

  final int index;
  final Widget Function(BuildContext context, Key handleKey) builder;

  @override
  State<DragSelectionTarget> createState() => _DragSelectionTargetState();
}

class _DragSelectionTargetState extends State<DragSelectionTarget> {
  final GlobalKey _handleKey = GlobalKey();
  _DragSelectionRegionState? _region;

  void _unregister(int index) {
    final targets = _region?._targets;
    if (identical(targets?[index], this)) targets?.remove(index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final region = context
        .dependOnInheritedWidgetOfExactType<_DragSelectionScope>()
        ?.region;
    if (_region == region) return;
    _unregister(widget.index);
    _region = region;
    _region?._targets[widget.index] = this;
  }

  @override
  void didUpdateWidget(covariant DragSelectionTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _unregister(oldWidget.index);
      _region?._targets[widget.index] = this;
    }
  }

  @override
  void dispose() {
    _unregister(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _handleKey);
}
