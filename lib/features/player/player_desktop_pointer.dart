part of 'player_page.dart';

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
  _mouseTapGestures() {
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
          if (current()) _togglePlayback(showControls: false);
        }
        ..onDoubleTap = () {
          if (current()) unawaited(_toggleFullscreen());
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

  Widget _withDesktopPointerRegion(Widget child, double height) {
    if (!_appPlatform.isDesktop) return child;
    return MouseRegion(
      onExit: (_) {
        _setDesktopBottomHover(false);
        _setDesktopTimelineHover(null);
      },
      child: Listener(
        onPointerHover: (event) {
          if (event.kind != PointerDeviceKind.mouse || event.buttons != 0) {
            return;
          }
          // Measure the toolbar that is actually laid out (wrapped buttons,
          // visible flags and safe-area padding), even when it is faded out.
          final bar = _desktopBottomBarKey.currentContext?.findRenderObject();
          final barHeight = bar is RenderBox && bar.hasSize
              ? bar.size.height
              : 0.0;
          _setDesktopBottomHover(
            _desktopControlsAvailable &&
                event.localPosition.dy >= height - barHeight,
          );
        },
        onPointerDown: (_) {
          _setDesktopBottomHover(false);
          _setDesktopTimelineHover(null);
        },
        child: child,
      ),
    );
  }

  void _setDesktopBottomHover(bool hovering) {
    if (!mounted || _desktopBottomHover == hovering) return;
    _desktopBottomHover = hovering;
    if (hovering) {
      _showPlayerControls();
    } else {
      _restartControlsAutoHideTimer();
    }
  }

  Widget _withTimelineMouseHover(Widget slider) {
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
            final bar = _desktopBottomBarKey.currentContext?.findRenderObject();
            if (size == null || bar is! RenderBox || !bar.hasSize) return;
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

  Widget _buildTimelineHoverCard({
    required double progress,
    required double x,
  }) {
    final target = Duration(
      milliseconds: (_playbackSnapshot.duration.inMilliseconds * progress)
          .round(),
    );
    final frame = _videoShotPreview?.frameFor(target);
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => CustomSingleChildLayout(
            delegate: _TimelineHoverPosition(x),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DecoratedBox(
                key: const Key('timeline-hover-preview'),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (constraints.maxHeight >= 92 &&
                          constraints.maxWidth >= 140)
                        if (frame != null)
                          _buildVideoShotFrame(frame)
                        else if (_videoShotLoading)
                          const _VideoShotLoading(),
                      Text(
                        _formatSeconds(target.inSeconds),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineHoverPosition extends SingleChildLayoutDelegate {
  const _TimelineHoverPosition(this.x);

  final double x;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (x - childSize.width / 2).clamp(0.0, size.width - childSize.width),
    size.height - childSize.height,
  );

  @override
  bool shouldRelayout(_TimelineHoverPosition oldDelegate) => x != oldDelegate.x;
}
