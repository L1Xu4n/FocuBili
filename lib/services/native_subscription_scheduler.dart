import 'dart:async';
import 'package:flutter/services.dart';
import '../platform/app_platform.dart';

/// Desktop timers belong to the existing process; iOS is opportunity based.
/// No OS login item, scheduled executable, or machine wake-up is installed.
class NativeSubscriptionScheduler {
  NativeSubscriptionScheduler({
    required this.platform,
    MethodChannel? channel,
    this.interval = const Duration(hours: 1),
  }) : channel =
           channel ??
           const MethodChannel('com.focubili.app/subscription_scheduler');
  final AppPlatform platform;
  final MethodChannel channel;
  final Duration interval;
  bool available = false;
  String status = 'uninitialized';
  String mode = 'foreground';
  String? lastRunStatus;
  bool _disposed = false;
  bool _enabled = false;
  int _generation = 0;
  int _operation = 0;
  Future<void> _operations = Future.value();
  Future<void> Function(int generation)? _onCheck;

  Future<void> initialize(Future<void> Function(int) onCheck) async {
    _onCheck = onCheck;
    channel.setMethodCallHandler((call) async {
      if (_disposed || !_enabled || call.method != 'check') return false;
      final args = call.arguments;
      final generation = args is Map ? args['generation'] : null;
      if (generation is! int || generation != _generation) return false;
      try {
        await _onCheck?.call(generation);
        return true;
      } catch (_) {
        return false;
      }
    });
    await refreshStatus();
  }

  void _restore(Map<Object?, Object?>? result) {
    available = result?['available'] == true;
    status = result?['status'] as String? ?? 'unavailable';
    mode = result?['mode'] as String? ?? 'foreground';
    lastRunStatus = result?['lastRunStatus'] as String?;
  }

  Future<void> refreshStatus() async {
    if (_disposed) return;
    try {
      _restore(await channel.invokeMapMethod<Object?, Object?>('getStatus'));
    } on MissingPluginException {
      available = false;
      status = 'unavailable';
    } on PlatformException {
      available = false;
      status = 'unavailable';
    }
  }

  Future<void> configure(bool enabled, int generation) {
    if (_disposed) return Future.value();
    if (generation < 0) return Future.error(ArgumentError.value(generation));
    _enabled = enabled;
    _generation = generation;
    final operation = ++_operation;
    final pending = _operations.then((_) async {
      try {
        await _configure(enabled, generation);
      } catch (_) {
        if (_operation == operation) _enabled = false;
        rethrow;
      }
    });
    _operations = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<void> _configure(bool enabled, int generation) async {
    try {
      final result = await channel
          .invokeMapMethod<Object?, Object?>('configure', {
            'enabled': enabled,
            'generation': generation,
            'intervalSeconds': interval.inSeconds.clamp(1, 86400),
          });
      _restore(result);
      if (enabled && result?['accepted'] != true) {
        throw StateError('native_schedule_unavailable');
      }
    } on MissingPluginException {
      available = false;
      status = 'unavailable';
      if (enabled) rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    try {
      // iOS requests must survive the UI engine ending. User opt-out is
      // explicitly reconciled by SubscriptionService before disposal.
      if (platform.isDesktop) await configure(false, 0);
    } catch (_) {
      /* Existing process is ending. */
    }
    _disposed = true;
    _onCheck = null;
    channel.setMethodCallHandler(null);
  }
}
