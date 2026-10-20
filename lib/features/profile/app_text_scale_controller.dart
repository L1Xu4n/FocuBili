import 'package:flutter/foundation.dart';
import '../../services/app_text_scale_service.dart';

/// Owns one live application preference and serializes its local writes.
class AppTextScaleController extends ChangeNotifier {
  AppTextScaleController({AppTextScaleService? service})
    : _service = service ?? const AppTextScaleService();

  final AppTextScaleService _service;
  double _scale = 1;
  double _saved = 1;
  int _revision = 0;
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  double get scale => _scale;

  Future<void> initialize() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded) return;
    try {
      _saved = await _service.load();
      if (_revision == 0) _scale = _saved;
    } catch (_) {
      // Unreadable storage never prevents startup or overrides a manual change.
    }
    _loaded = true;
    _notify();
  }

  void preview(double value) {
    _scale = AppTextScaleService.normalize(value);
    _revision++;
    _notify();
  }

  Future<bool> setScale(double value) {
    preview(value);
    final selected = _scale;
    final revision = _revision;
    final result = _writes.then((_) async {
      await initialize();
      if (_disposed) return false;
      try {
        await _service.save(selected);
        _saved = selected;
        return true;
      } catch (_) {
        if (revision == _revision) {
          _scale = _saved;
          _notify();
        }
        return false;
      }
    });
    _writes = result.then((_) {});
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
