import 'dart:async';

/// Scoped cancellation reaches the real HTTP transport; injected test requests
/// may finish late, but callers still fence their results before committing.
class SubscriptionRequestScope {
  static final _zoneKey = Object();
  static Future<void> _gate = Future.value();
  static DateTime _nextStart = DateTime.fromMillisecondsSinceEpoch(0);
  static SubscriptionRequestScope? get current =>
      Zone.current[_zoneKey] as SubscriptionRequestScope?;
  final _aborters = <void Function()>{};
  bool cancelled = false;

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});

  void attach(void Function() abort) {
    if (cancelled) {
      abort();
      throw StateError('Request cancelled');
    }
    _aborters.add(abort);
  }

  void detach(void Function() abort) => _aborters.remove(abort);
  void cancel() {
    cancelled = true;
    for (final abort in _aborters.toList()) {
      abort();
    }
    _aborters.clear();
  }

  Future<void> beforeRequest() async {
    final turn = _gate.then((_) async {
      if (cancelled) throw StateError('Request cancelled');
      final delay = _nextStart.difference(DateTime.now());
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (cancelled) throw StateError('Request cancelled');
      _nextStart = DateTime.now().add(const Duration(seconds: 1));
    });
    _gate = turn.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await turn;
  }
}
