import 'package:shared_preferences/shared_preferences.dart';

import '../models/dashboard_layout.dart';
import 'dashboard_layout_service.dart';
import 'subscription_service.dart';

/// The pending choice is durable before side effects. Restart completes the same
/// opt-in idempotently instead of duplicating cards or asking a second time.
class SubscriptionOnboardingService {
  SubscriptionOnboardingService({
    required this.subscriptions,
    DashboardLayoutService? layoutService,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : layouts = layoutService ?? DashboardLayoutService(),
       _preferences = preferencesLoader ?? SharedPreferences.getInstance;

  static const choiceKey = 'focus_subscription_introduction_v180';
  static const homeCardId = 'home.focus_subscriptions';
  final SubscriptionService subscriptions;
  final DashboardLayoutService layouts;
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _enabling;
  bool homeLayoutChanged = false;

  Future<void> _saveChoice(String value) async {
    final prefs = await _preferences();
    try {
      if (!await prefs.setString(choiceKey, value)) throw StateError('引导选择未保存');
      await prefs.reload();
      if (prefs.getString(choiceKey) != value) throw StateError('引导选择未保存');
    } catch (_) {
      await prefs.reload();
      rethrow;
    }
  }

  Future<bool> shouldPrompt() async {
    await subscriptions.initialize();
    if (subscriptions.storageError != null) return false;
    final prefs = await _preferences();
    final choice = prefs.getString(choiceKey);
    if (choice == 'enabling') {
      await accept();
      return false;
    }
    if (choice != null) return false;
    if (subscriptions.enabled) {
      // Existing beta users retain their opt-in, sources, card order and hiding.
      await _saveChoice('existing');
      return false;
    }
    return true;
  }

  Future<void> accept() =>
      _enabling ??= _accept().whenComplete(() => _enabling = null);

  Future<void> _accept() async {
    final prefs = await _preferences();
    if (prefs.getString(choiceKey) == 'enabled') return;
    await _saveChoice('enabling');
    if (!subscriptions.enabled) await subscriptions.setEnabled(true);
    final current = await layouts.load('home', const []);
    await layouts.save(
      'home',
      DashboardLayout(
        order: [homeCardId, ...current.order.where((id) => id != homeCardId)],
        hidden: current.hidden.where((id) => id != homeCardId),
      ),
    );
    homeLayoutChanged = true;
    await _saveChoice('enabled');
  }

  Future<void> decline() async {
    // No navigation, source writes, notifications, or layout mutation.
    await _saveChoice('declined');
  }
}
