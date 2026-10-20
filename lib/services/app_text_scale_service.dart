import 'package:shared_preferences/shared_preferences.dart';

/// A separate UI preference; playback subtitle size remains independent.
class AppTextScaleService {
  const AppTextScaleService({
    this.preferencesLoader = SharedPreferences.getInstance,
  });
  final Future<SharedPreferences> Function() preferencesLoader;
  static const preferenceKey = 'appearance.text_scale';
  static const minimum = .8;
  static const maximum = 2.0;

  static double normalize(double value) =>
      value.isFinite ? (value.clamp(minimum, maximum) * 10).round() / 10 : 1;

  Future<double> load() async {
    final value = (await preferencesLoader()).get(preferenceKey);
    return value is num ? normalize(value.toDouble()) : 1;
  }

  Future<void> save(double value) async {
    if (!await (await preferencesLoader()).setDouble(
      preferenceKey,
      normalize(value),
    )) {
      throw StateError('无法保存界面文字大小');
    }
  }
}
