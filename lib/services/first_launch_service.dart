import 'package:shared_preferences/shared_preferences.dart';

typedef FirstLaunchPreferencesLoader = Future<SharedPreferences> Function();

/// 保存首次启动协议和登录引导是否已经处理的本机状态。
class FirstLaunchState {
  /// 创建一份不包含账号、Cookie 或其他隐私数据的首次启动状态。
  const FirstLaunchState({
    required this.agreementAccepted,
    required this.loginGuideShown,
  });

  final bool agreementAccepted;
  final bool loginGuideShown;
}

/// 使用 SharedPreferences 在本机保存协议同意和登录引导状态。
class FirstLaunchService {
  /// 创建首次启动服务；测试可以注入内存 SharedPreferences 读取器。
  FirstLaunchService({FirstLaunchPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String agreementAcceptedKey =
      'first_launch_user_agreement_2026_07_18_accepted';
  static const String loginGuideShownKey =
      'first_launch_login_guide_2026_07_18_shown';

  final FirstLaunchPreferencesLoader _preferencesLoader;

  /// 读取本机首次启动状态；读取失败时安全回到“尚未同意”的状态。
  Future<FirstLaunchState> loadState() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return FirstLaunchState(
        agreementAccepted: preferences.getBool(agreementAcceptedKey) ?? false,
        loginGuideShown: preferences.getBool(loginGuideShownKey) ?? false,
      );
    } catch (_) {
      return const FirstLaunchState(
        agreementAccepted: false,
        loginGuideShown: false,
      );
    }
  }

  /// 保存用户已经同意当前版本协议，写入成功才允许进入应用。
  Future<bool> acceptAgreement() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.setBool(agreementAcceptedKey, true);
    } catch (_) {
      return false;
    }
  }

  /// 记录登录引导已经展示，确保后续启动不再重复弹出。
  Future<bool> markLoginGuideShown() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.setBool(loginGuideShownKey, true);
    } catch (_) {
      return false;
    }
  }
}
