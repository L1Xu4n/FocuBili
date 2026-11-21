part of 'player_page.dart';

enum _DesktopControlsEdge { top, bottom }

typedef _DesktopTimelinePoint = ({
  double progress,
  double x,
  double width,
  int source,
});

// Keep touch/pen gestures on a separate recognizer so a mouse click cannot
// complete a finger's double tap (and vice versa).
final _nonMousePointerKinds = PointerDeviceKind.values
    .where((kind) => kind != PointerDeviceKind.mouse)
    .toSet();

extension _PlayerDesktopPointer on _PlayerPageState {
  GestureRecognizerFactoryWithHandlers<PlayerMouseTapGestureRecognizer>
  _mouseTapGestures(Size playerSize) {
    final source = _sourceGeneration;
    final navigation = _partSwitchGeneration;
    final fullscreen = _fullscreen;
    bool current() =>
        mounted &&
        ModalRoute.isCurrentOf(context) != false &&
        !_controlsLocked &&
        !_partSelectorExpanded &&
        !_externalNavigationSuspended &&
        !_changingPlaybackSource &&
        !_playbackSnapshot.isInPictureInPicture &&
        !_playbackSnapshot.isRestoringPosition &&
        _playbackSnapshot.phase != PlaybackPhase.error &&
        source == _sourceGeneration &&
        navigation == _partSwitchGeneration &&
        fullscreen == _fullscreen;

    return GestureRecognizerFactoryWithHandlers<
      PlayerMouseTapGestureRecognizer
    >(() => PlayerMouseTapGestureRecognizer(debugOwner: this), (recognizer) {
      _desktopTapRecognizer = recognizer;
      recognizer
        ..onSingleTap = () {
          if (current()) _toggleDesktopPlayback();
        }
        ..onDoubleTapDown = (details) {
          if (!current() || playerSize.isEmpty) return;
          final position = details.localPosition;
          // The touch switch only changes touch behavior. Both input types
          // use the same saved geometry, including the centered height band.
          _handleDoubleTapAction(
            _playbackPreferences.doubleTapRegions.actionAt(
              position.dx / playerSize.width,
              position.dy / playerSize.height,
            ),
            onCenter: () => unawaited(_toggleFullscreen()),
          );
        };
    });
  }

  bool get _desktopControlsAvailable =>
      !_controlsLocked && !_playbackSnapshot.isInPictureInPicture;

  bool get _timelineHoverAvailable =>
      _desktopControlsAvailable &&
      _showControls &&
      !_partSelectorExpanded &&
      !_changingPlaybackSource &&
      !_externalNavigationSuspended &&
      !_playbackSnapshot.isRestoringPosition &&
      !_abRepeatEditorVisible &&
      !_completionPromptVisible &&
      !_interactivePromptVisible &&
      !_horizontalScrubbing &&
      !_isDraggingProgress &&
      _playbackSnapshot.phase != PlaybackPhase.error &&
      _playbackSnapshot.duration > Duration.zero;

  _DesktopTimelinePoint? get _timelineHover =>
      _timelineHoverAvailable &&
          _desktopTimelineHover?.source == _sourceGeneration
      ? _desktopTimelineHover
      : null;

  Widget _withDesktopPointerRegion(Widget child) {
    if (!_appPlatform.isDesktop) return child;
    return MouseRegion(
      onExit: (_) {
        _recordDesktopPointerEdge(null);
        _setDesktopControlsHover(false);
        _setDesktopTimelineHover(null);
      },
      child: Listener(
        onPointerHover: (event) {
          // MouseTracker can synthesize updates when the player is relaid
          // out (including fullscreen transitions) under a stationary cursor.
          // Only real movement should reveal controls or extend the timer.
          if (event.kind != PointerDeviceKind.mouse ||
              event.buttons != 0 ||
              event.synthesized ||
              event.delta == Offset.zero ||
              !_desktopControlsAvailable ||
              _externalNavigationSuspended ||
              ModalRoute.isCurrentOf(context) == false) {
            return;
          }
          final edge = _desktopControlsEdgeAt(event.position);
          _recordDesktopPointerEdge(edge);
          _holdDesktopControlsOnEdge(mayReveal: true);
          if (edge == null) {
            // Motion over the picture reveals the bar but does not pin it.
            _showPlayerControls();
          }
        },
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse) {
            _recordDesktopPointerEdge(_desktopControlsEdgeAt(event.position));
          }
          _setDesktopControlsHover(false);
          _setDesktopTimelineHover(null);
        },
        onPointerUp: (event) {
          if (event.kind != PointerDeviceKind.mouse || event.buttons != 0) {
            return;
          }
          // A stationary mouse produces no hover event after a click or drag.
          // Reclaim an already visible toolbar without revealing hidden
          // controls or restoring the timeline image preview on pointer-up.
          _recordDesktopPointerEdge(_desktopControlsEdgeAt(event.position));
          _holdDesktopControlsOnEdge(mayReveal: false);
        },
        child: child,
      ),
    );
  }

  RenderBox? _desktopBarBox(_DesktopControlsEdge edge) {
    final context = switch (edge) {
      _DesktopControlsEdge.top => _desktopTopBarContext,
      _DesktopControlsEdge.bottom => _desktopBottomBarContext,
    };
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  _DesktopControlsEdge? _desktopControlsEdgeAt(Offset position) {
    if (!_desktopControlsAvailable) return null;
    bool contains(_DesktopControlsEdge edge) {
      final bar = _desktopBarBox(edge);
      return bar != null &&
          (Offset.zero & bar.size).contains(bar.globalToLocal(position));
    }

    // Use the actual toolbar bounds, including text/control scaling and
    // safe-area insets, even when the toolbars are faded out.
    if (contains(_DesktopControlsEdge.bottom)) {
      return _DesktopControlsEdge.bottom;
    }
    if (contains(_DesktopControlsEdge.top)) return _DesktopControlsEdge.top;
    return null;
  }

  void _recordDesktopPointerEdge(_DesktopControlsEdge? edge) {
    if (_desktopPointerEdge == edge) return;
    _desktopPointerEdge = edge;
    _desktopSuppressedEdge = null;
  }

  void _holdDesktopControlsOnEdge({required bool mayReveal}) {
    _setDesktopControlsHover(
      _desktopPointerEdge != null &&
          _desktopPointerEdge != _desktopSuppressedEdge &&
          (mayReveal || _showControls),
    );
  }

  void _setDesktopControlsHover(bool hovering) {
    if (!mounted || _desktopControlsHover == hovering) return;
    _desktopControlsHover = hovering;
    if (hovering) {
      _showPlayerControls();
    } else {
      _restartControlsAutoHideTimer();
    }
  }

  Widget _withTimelinePointerRegion(Widget slider) {
    slider = Listener(
      onPointerDown: _recordProgressPointer,
      onPointerUp: (event) =>
          _endProgressPointer(event.pointer, canceled: false),
      onPointerCancel: (event) =>
          _endProgressPointer(event.pointer, canceled: true),
      child: slider,
    );
    if (!_appPlatform.isDesktop) return slider;
    return MouseRegion(
      onExit: (_) => _setDesktopTimelineHover(null),
      child: Builder(
        builder: (context) => Listener(
          onPointerHover: (event) {
            if (event.kind != PointerDeviceKind.mouse ||
                event.buttons != 0 ||
                !_timelineHoverAvailable) {
              return;
            }
            final size = context.size;
            final bar = _desktopBarBox(_DesktopControlsEdge.bottom);
            if (size == null || bar == null) return;
            final track = PlayerTimelineGeometry.trackRect(size);
            if (track.width <= 0) return;
            final fraction =
                ((event.localPosition.dx - track.left) / track.width).clamp(
                  0.0,
                  1.0,
                );
            final next = (
              progress: Directionality.of(context) == TextDirection.rtl
                  ? 1 - fraction
                  : fraction,
              x: bar.globalToLocal(event.position).dx,
              width: bar.size.width,
              source: _sourceGeneration,
            );
            final entering = _timelineHover == null;
            _setDesktopTimelineHover(next);
            // Reuse the exact same atlas/metadata pipeline as picture swipes.
            // A failed lookup is retried on the next hover, not every pixel.
            if (entering) unawaited(_loadVideoShotPreview());
          },
          child: slider,
        ),
      ),
    );
  }
}
