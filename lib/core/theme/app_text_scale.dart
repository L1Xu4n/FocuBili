import 'package:flutter/material.dart';
import '../../features/profile/app_text_scale_controller.dart';

/// Composes the application preference with the OS scaler, including nonlinear scaling.
class AppUiTextScaler extends TextScaler {
  const AppUiTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;
  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;
  @override
  double get textScaleFactor => scale(14) / 14;
  @override
  bool operator ==(Object other) =>
      other is AppUiTextScaler &&
      other.system == system &&
      other.factor == factor;
  @override
  int get hashCode => Object.hash(system, factor);
}

class AppTextScaleScope extends InheritedWidget {
  const AppTextScaleScope({
    super.key,
    required this.controller,
    required this.systemTextScaler,
    required this.scale,
    required super.child,
  });
  final AppTextScaleController controller;
  final TextScaler systemTextScaler;
  final double scale;
  static AppTextScaleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTextScaleScope>();

  /// Subtitles retain the pre-existing OS accessibility scale, without the UI multiplier.
  static TextScaler subtitleScalerOf(BuildContext context) =>
      maybeOf(context)?.systemTextScaler ?? MediaQuery.textScalerOf(context);
  @override
  bool updateShouldNotify(AppTextScaleScope oldWidget) =>
      scale != oldWidget.scale ||
      controller != oldWidget.controller ||
      systemTextScaler != oldWidget.systemTextScaler;
}

class AppTextScale extends StatelessWidget {
  const AppTextScale({
    super.key,
    required this.controller,
    required this.child,
  });
  final AppTextScaleController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final data = MediaQuery.of(context);
      final system = data.textScaler;
      final scaled = AppUiTextScaler(system, controller.scale);
      return AppTextScaleScope(
        controller: controller,
        systemTextScaler: system,
        scale: controller.scale,
        child: MediaQuery(
          data: data.copyWith(textScaler: scaled),
          child: child,
        ),
      );
    },
  );
}
