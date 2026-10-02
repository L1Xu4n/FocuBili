import 'dart:async';

/// Signals a user-requested interruption instead of a network failure.
class DownloadInterrupted implements Exception {
  /// Creates the control-flow signal used by paused or removed tasks.
  const DownloadInterrupted();
}

/// Owns cancellation for one transfer, including a blocked HTTP request.
class DownloadControl {
  bool _interrupted = false;
  void Function()? _abort;
  final Completer<void> _interruption = Completer<void>();

  /// Indicates whether a task must stop before publishing downloaded files.
  bool get isInterrupted => _interrupted;

  /// Registers the active network abort operation and handles prior cancellation.
  set abort(void Function()? action) {
    _abort = action;
    if (_interrupted) action?.call();
  }

  /// Stops the network immediately; partial bytes remain available for resuming.
  void interrupt() {
    if (_interrupted) return;
    _interrupted = true;
    _interruption.complete();
    _abort?.call();
  }

  /// Releases callers waiting for metadata even when an injected request never responds.
  Future<T> guard<T>(Future<T> request) {
    return Future.any([
      request.then((value) {
        check();
        return value;
      }),
      _interruption.future.then<T>((_) => throw const DownloadInterrupted()),
    ]);
  }

  /// Prevents retries and metadata publication after pause or deletion.
  void check() {
    if (_interrupted) throw const DownloadInterrupted();
  }
}
