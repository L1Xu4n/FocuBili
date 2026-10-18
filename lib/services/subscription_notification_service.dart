import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import '../models/subscription.dart';
import 'windows_focus_notification_service.dart';
import 'linux_focus_notification_service.dart';
import 'subscription_notification_delivery.dart';

class SubscriptionNotificationService {
  SubscriptionNotificationService({
    MethodChannel? channel,
    AppPlatform? platform,
    WindowsFocusNotificationBackend? desktopBackend,
  }) : _channel =
           channel ??
           const MethodChannel('com.focubili.app/subscription_notifications'),
       _platform = platform,
       _desktopBackend = desktopBackend,
       _injectedChannel = channel != null;
  final MethodChannel _channel;
  final AppPlatform? _platform;
  final WindowsFocusNotificationBackend? _desktopBackend;
  final bool _injectedChannel;
  bool _disposed = false;
  _AppleSubscriptionNotificationChannel? _appleChannel;
  final _pendingRequests = <String>{};
  int _pendingBackgroundRequests = 0;
  AppPlatform get platform => _platform ?? AppPlatformDetector.current;
  bool get _available =>
      (platform == AppPlatform.android || platform.isApple) &&
      (_injectedChannel || !AppPlatformDetector.isFlutterTest);
  Future<void> initialize(void Function() onTap) async {
    if (!_available || _disposed) return;
    if (platform.isApple) {
      _attachAppleChannel().setTapHandler(this, onTap);
    } else {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'subscriptionTapped') onTap();
      });
    }
    try {
      if (await _channel.invokeMethod<bool>('consumeTap') == true) {
        if (platform.isApple) {
          _appleChannel?.handleTap();
        } else if (!_disposed) {
          onTap();
        }
      }
    } on MissingPluginException {
      /* independent UI previews have no platform backend */
    }
  }

  Future<bool> showSummary(
    int count, {
    int? generation,
    bool background = false,
    String? title,
    String? source,
  }) async {
    if (!_available || _disposed) return false;
    final isHeadless = platform == AppPlatform.ios && background;
    if (isHeadless) _pendingBackgroundRequests++;
    String? requestId;
    try {
      final guard = SubscriptionNotificationDelivery.current;
      if (!SubscriptionNotificationDelivery.allows(guard)) {
        return false;
      }
      // The iOS worker retains its native generation/run-token protocol. All
      // foreground Apple requests recheck their own guard after UN settings.
      if (platform.isApple && !isHeadless) {
        requestId = _attachAppleChannel().addRequest(
          this,
          () => !_disposed && SubscriptionNotificationDelivery.allows(guard),
        );
        _pendingRequests.add(requestId);
      }
      return await _channel.invokeMethod<bool>('showSummary', {
            'count': count,
            'generation': ?generation,
            'background': background,
            'title': ?title,
            'source': ?source,
            'requestId': ?requestId,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      if (isHeadless) _pendingBackgroundRequests--;
      if (requestId != null) {
        _pendingRequests.remove(requestId);
        _appleChannel?.removeRequest(requestId);
      }
    }
  }

  Future<bool> showItems(
    List<SubscriptionFeedItem> items, {
    int? generation,
    bool background = false,
  }) async {
    if (items.isEmpty) return false;
    final item = items.first;
    final title = item.title;
    final source = '来自${item.sources.values.join(' · ')}';
    final allowDelivery = SubscriptionNotificationDelivery.current;
    if (platform == AppPlatform.windows || platform == AppPlatform.linux) {
      final backend =
          _desktopBackend ??
          (platform == AppPlatform.windows
              ? WindowsFocusNotificationBackend.instance
              : LinuxFocusNotificationBackend.instance);
      return backend.showSubscriptionUpdate(
        title: title,
        source: source,
        count: items.length,
        allowDelivery: allowDelivery,
      );
    }
    return showSummary(
      items.length,
      generation: generation,
      background: background,
      title: title,
      source: source,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelPending();
    if (_appleChannel case final channel?) {
      channel.release(this);
    } else if (_available && !platform.isApple) {
      _channel.setMethodCallHandler(null);
    }
  }

  /// Permanently cancels preparations already in flight. Foreground requests
  /// remain independent; headless cancellation revokes only its owning engine.
  void cancelPending() {
    for (final requestId in _pendingRequests) {
      _appleChannel?.removeRequest(requestId);
      unawaited(_cancelRequest(requestId));
    }
    _pendingRequests.clear();
    if (_pendingBackgroundRequests > 0) {
      unawaited(_cancelWorkerRequest());
    }
  }

  Future<void> _cancelWorkerRequest() async {
    try {
      await _channel.invokeMethod<void>('cancelWorkerSummary');
    } on PlatformException {
      // Native expiration still owns the run if its engine is already closing.
    } on MissingPluginException {
      // An absent engine cannot deliver its pending notification.
    }
  }

  /// Publish the UI controller's current state to every Apple engine in this
  /// process. A headless engine must not overwrite it from cached preferences.
  void updateFocusState(bool active) {
    if (_disposed) return;
    if (_available && platform.isApple) {
      unawaited(_updateFocusState(active));
    }
    if (active) cancelPending();
  }

  Future<void> _updateFocusState(bool active) async {
    try {
      await _channel.invokeMethod<void>('setFocusActive', {'active': active});
    } on PlatformException {
      // The next controller notification retries the current state.
    } on MissingPluginException {
      // UI previews have no native engine; request-owned guards still apply.
    }
  }

  _AppleSubscriptionNotificationChannel _attachAppleChannel() {
    return _appleChannel ??= _AppleSubscriptionNotificationChannel.attach(
      _channel,
      this,
    );
  }

  Future<void> _cancelRequest(String requestId) async {
    try {
      await _channel.invokeMethod<void>('cancelSummary', {
        'requestId': requestId,
      });
    } on PlatformException {
      // Guard lookup also fails closed if native cancellation is unavailable.
    } on MissingPluginException {
      // A detached engine cannot deliver this request.
    }
  }
}

/// One handler per messenger/name, including when distinct service instances
/// share a channel. Reinitializing taps or disposing an older owner must not
/// replace another request's guard or remove the current owner's handler.
class _AppleSubscriptionNotificationChannel {
  _AppleSubscriptionNotificationChannel(this.channel);
  static final _channels =
      Expando<Map<String, _AppleSubscriptionNotificationChannel>>();
  static final _requestPrefix = DateTime.now().microsecondsSinceEpoch;
  static int _nextRequest = 0;
  final MethodChannel channel;
  final _owners = <Object>{};
  final _requests = <String, ({Object owner, bool Function() guard})>{};
  Object? _tapOwner;
  void Function()? _onTap;

  static _AppleSubscriptionNotificationChannel attach(
    MethodChannel channel,
    Object owner,
  ) {
    final channels = _channels[channel.binaryMessenger] ??= {};
    final bridge = channels.putIfAbsent(
      channel.name,
      () => _AppleSubscriptionNotificationChannel(channel),
    );
    bridge._owners.add(owner);
    channel.setMethodCallHandler(bridge._handle);
    return bridge;
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'subscriptionTapped') {
      handleTap();
      return null;
    }
    if (call.method == 'canDeliver') {
      final args = call.arguments;
      final requestId = args is Map ? args['requestId'] : null;
      // Consume once. Unknown, completed, cancelled and replayed requests deny.
      final request = _requests.remove(requestId);
      return request != null &&
          SubscriptionNotificationDelivery.allows(request.guard);
    }
    throw MissingPluginException();
  }

  void setTapHandler(Object owner, void Function() onTap) {
    _tapOwner = owner;
    _onTap = onTap;
  }

  void handleTap() => _onTap?.call();

  String addRequest(Object owner, bool Function() guard) {
    final requestId = '$_requestPrefix:${_nextRequest++}';
    _requests[requestId] = (owner: owner, guard: guard);
    return requestId;
  }

  void removeRequest(String requestId) => _requests.remove(requestId);

  void release(Object owner) {
    _requests.removeWhere((_, request) => identical(request.owner, owner));
    _owners.remove(owner);
    if (identical(_tapOwner, owner)) {
      _tapOwner = null;
      _onTap = null;
    }
    if (_owners.isEmpty) {
      channel.setMethodCallHandler(null);
      _channels[channel.binaryMessenger]?.remove(channel.name);
    }
  }
}
