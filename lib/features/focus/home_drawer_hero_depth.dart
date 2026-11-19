import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Applies the v1.8.1 welcome-screen depth effect without driving the scroll
/// position or rebuilding the search controls and dashboard cards on each tick.
class HomeDrawerHeroDepth extends StatelessWidget {
  const HomeDrawerHeroDepth({
    super.key,
    required this.height,
    required this.enabled,
    required this.child,
  });

  final double height;
  final bool enabled;
  final Widget child;

  static final _identityFilter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);

  @override
  Widget build(BuildContext context) {
    final position = Scrollable.maybeOf(context)?.position;
    final animate =
        enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);

    final contents = RepaintBoundary(child: child);
    Widget frame(double offset, {required bool filter}) {
      final progress = (offset / 280).clamp(0.0, 1.0);
      final sigma = progress * 7;
      return ClipRect(
        child: ImageFiltered(
          enabled: filter,
          imageFilter: filter
              ? ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)
              : _identityFilter,
          child: Opacity(
            opacity: 1 - progress * .88,
            // The sliver moves up with the cards; only its own contents fall.
            child: Transform.translate(
              offset: Offset(0, offset * 1.32),
              child: contents,
            ),
          ),
        ),
      );
    }

    final resting = frame(0, filter: false);
    final visualScroll = animate ? position : null;
    // Keep the same element and keyboard focus when assistive settings change.
    // The constant animation does not listen to scrolls in the clear mode.

    // Hold the same widget tree while it is completely off screen. A long
    // card-list scroll allocates no filters and rebuilds no hero contents.
    final departed = frame(height, filter: false);
    return SizedBox(
      height: height,
      child: AnimatedBuilder(
        animation: visualScroll ?? const AlwaysStoppedAnimation<double>(0),
        builder: (context, _) {
          if (visualScroll == null ||
              !visualScroll.hasPixels ||
              visualScroll.pixels <= 0) {
            return resting;
          }
          if (visualScroll.pixels >= height) return departed;
          return frame(visualScroll.pixels, filter: true);
        },
      ),
    );
  }
}
