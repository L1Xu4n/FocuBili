import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Builds the surface while keeping its controls separate from the video transform.
typedef FullscreenVideoTransformBuilder =
    Widget Function(
      BuildContext context,
      Matrix4 transform,
      bool usingTwoFingers,
    );

/// Owns touch-only video zoom/pan and two-finger double-tap reset in fullscreen.
class FullscreenVideoTransform extends StatefulWidget {
  /// Receives availability, the surface builder and cancellation of old single-touch work.
  const FullscreenVideoTransform({
    super.key,
    required this.enabled,
    required this.builder,
    this.onMultiTouchStart,
  });
  final bool enabled;
  final FullscreenVideoTransformBuilder builder;
  final VoidCallback? onMultiTouchStart;

  /// Creates per-video transform state without persisting a temporary viewing adjustment.
  @override
  State<FullscreenVideoTransform> createState() =>
      _FullscreenVideoTransformState();
}

class _FullscreenVideoTransformState extends State<FullscreenVideoTransform> {
  final _positions = <int, Offset>{};
  final _origins = <int, Offset>{};
  double _scale = 1;
  Offset _translation = Offset.zero;
  Size _size = Size.zero;
  bool _usingTwoFingers = false;
  double _startScale = 1;
  double _startDistance = 1;
  Offset _anchor = Offset.zero;
  Duration? _firstDownAt;
  bool _tapCandidate = false;
  Offset _tapCenter = Offset.zero;
  Duration? _lastTapAt;
  Offset _lastTapCenter = Offset.zero;

  /// Resets viewing adjustments and unfinished touches when the setting becomes unavailable.
  @override
  void didUpdateWidget(covariant FullscreenVideoTransform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _positions.clear();
      _origins.clear();
      _usingTwoFingers = false;
      _lastTapAt = null;
      _resetPicture();
    }
  }

  /// Restores the normal picture without changing playback position or speed.
  void _resetPicture() {
    _scale = 1;
    _translation = Offset.zero;
  }

  /// Records touches and switches from single-finger controls when the second finger arrives.
  void _pointerDown(PointerDownEvent event) {
    if (!widget.enabled || event.kind != PointerDeviceKind.touch) return;
    if (_positions.isEmpty) _firstDownAt = event.timeStamp;
    _positions[event.pointer] = event.localPosition;
    _origins[event.pointer] = event.localPosition;
    if (_positions.length == 2) {
      if (!_usingTwoFingers) {
        _usingTwoFingers = true;
        widget.onMultiTouchStart?.call();
      }
      _tapCandidate =
          event.timeStamp - _firstDownAt! <=
              const Duration(milliseconds: 150) &&
          _positions.entries.every(
            (entry) =>
                (entry.value - _origins[entry.key]!).distance <= kTouchSlop,
          );
      _beginPair();
      setState(() {});
    } else if (_positions.length > 2) {
      _tapCandidate = false;
    }
  }

  /// Anchors scaling to the picture point beneath the pair's midpoint, avoiding jumps.
  void _beginPair() {
    final pair = _positions.values.toList();
    final midpoint = (pair[0] + pair[1]) / 2;
    _startScale = _scale;
    _startDistance = (pair[0] - pair[1]).distance
        .clamp(1, double.infinity)
        .toDouble();
    _anchor = (midpoint - _size.center(Offset.zero) - _translation) / _scale;
    _tapCenter = midpoint;
  }

  /// Applies free translation and bounded scaling while rejecting moved pairs as reset taps.
  void _pointerMove(PointerMoveEvent event) {
    if (!_positions.containsKey(event.pointer)) return;
    _positions[event.pointer] = event.localPosition;
    if ((event.localPosition - _origins[event.pointer]!).distance >
        kTouchSlop) {
      _tapCandidate = false;
    }
    if (_positions.length != 2) return;
    final pair = _positions.values.toList();
    final midpoint = (pair[0] + pair[1]) / 2;
    final scale = (_startScale * (pair[0] - pair[1]).distance / _startDistance)
        .clamp(0.5, 8.0)
        .toDouble();
    setState(() {
      _scale = scale;
      _translation = midpoint - _size.center(Offset.zero) - _anchor * scale;
    });
  }

  /// Finishes a paired tap only after both fingers lift, or rebases after a third finger leaves.
  void _pointerUp(PointerEvent event) {
    if (!_positions.containsKey(event.pointer)) return;
    if (event is PointerCancelEvent) {
      _tapCandidate = false;
      _lastTapAt = null;
    }
    _positions.remove(event.pointer);
    _origins.remove(event.pointer);
    if (_positions.length == 2) {
      _tapCandidate = false;
      _beginPair();
    } else if (_positions.isEmpty && _usingTwoFingers) {
      setState(() {
        if (_tapCandidate &&
            event.timeStamp - _firstDownAt! <=
                const Duration(milliseconds: 300)) {
          _finishPairTap(event.timeStamp);
        } else {
          _lastTapAt = null;
        }
        _usingTwoFingers = false;
      });
    }
  }

  /// Recognizes two nearby paired taps and restores the untransformed picture.
  void _finishPairTap(Duration timestamp) {
    final previous = _lastTapAt;
    if (previous != null &&
        timestamp - previous <= kDoubleTapTimeout &&
        (_tapCenter - _lastTapCenter).distance <= kDoubleTapSlop) {
      _resetPicture();
      _lastTapAt = null;
    } else {
      _lastTapAt = timestamp;
      _lastTapCenter = _tapCenter;
    }
  }

  /// Clips only the surface boundary and provides the current transform to the video layer.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      final transform = Matrix4.identity()
        ..translateByDouble(_translation.dx, _translation.dy, 0, 1)
        ..scaleByDouble(_scale, _scale, 1, 1);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerUp,
        child: RawGestureDetector(
          gestures: widget.enabled
              ? {
                  _TwoFingerClaimRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _TwoFingerClaimRecognizer
                      >(_TwoFingerClaimRecognizer.new, (_) {}),
                }
              : const {},
          child: ClipRect(
            child: widget.builder(context, transform, _usingTwoFingers),
          ),
        ),
      );
    },
  );
}

/// Claims paired touches before tap/drag controls can treat them as separate single-finger input.
class _TwoFingerClaimRecognizer extends OneSequenceGestureRecognizer {
  /// Accepts real touch input while leaving mouse and trackpad gestures alone.
  _TwoFingerClaimRecognizer()
    : super(supportedDevices: {PointerDeviceKind.touch});
  final _touches = <int>{};

  /// Keeps one finger pending and claims the gesture when a second finger joins.
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _touches.add(event.pointer);
    if (_touches.length >= 2) resolve(GestureDisposition.accepted);
  }

  /// Releases each routed pointer when it lifts or the system cancels it.
  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touches.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  /// Lets a one-finger sequence complete through the existing tap and drag controls.
  @override
  void didStopTrackingLastPointer(int pointer) =>
      resolve(GestureDisposition.rejected);

  /// Releases tracked routes and gesture-arena entries with the owning surface.
  @override
  void dispose() {
    _touches.clear();
    super.dispose();
  }

  /// Names this recognizer in Flutter gesture diagnostics.
  @override
  String get debugDescription => 'fullscreen two-finger picture';
}
