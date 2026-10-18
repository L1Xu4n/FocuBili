import 'dart:async';

/// Carries a service-owned guard through one asynchronous notification callback.
/// Existing callbacks keep their API, and concurrent services cannot share state.
class SubscriptionNotificationDelivery {
  static final _key = Object();

  static bool Function()? get current => Zone.current[_key] as bool Function()?;

  static Future<T> run<T>(bool Function() guard, Future<T> Function() send) =>
      runZoned<Future<T>>(send, zoneValues: {_key: guard});

  static bool allows(bool Function()? guard) {
    try {
      return guard?.call() ?? true;
    } catch (_) {
      return false;
    }
  }
}
