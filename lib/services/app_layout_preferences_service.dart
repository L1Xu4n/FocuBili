import 'package:shared_preferences/shared_preferences.dart';

/// 控制移动设备启动时使用的布局；未选择时保持大屏横屏、手机竖屏。
enum AppLayoutMode { adaptive, landscape, portrait }

/// 保存下次启动采用的布局，运行中的方向策略只使用启动时的快照。
class AppLayoutPreferencesService {
  /// 创建布局偏好服务。
  const AppLayoutPreferencesService();

  static const modeKey = 'appearance.layout_orientation';
  static const guideShownKey = 'appearance.tablet_layout_guide_v180_shown';
  static AppLayoutMode activeMode = AppLayoutMode.adaptive;

  /// 读取安全的布局枚举，未知旧值使用自动布局。
  Future<AppLayoutMode> load() async {
    final preferences = await SharedPreferences.getInstance();
    return AppLayoutMode.values.firstWhere(
      (mode) => mode.name == preferences.getString(modeKey),
      orElse: () => AppLayoutMode.adaptive,
    );
  }

  /// 在首帧前加载一次方向快照，设置页的变更在重启后生效。
  Future<void> initialize() async {
    activeMode = await load();
  }

  /// 保存布局选择，失败时不宣称已应用或记录引导完成。
  Future<void> save(AppLayoutMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(modeKey, mode.name)) {
      await preferences.reload();
      throw StateError('布局设置保存失败');
    }
  }

  /// 判断大屏布局引导是否已完成，升级用户也只提示一次。
  Future<bool> guideShown() async =>
      (await SharedPreferences.getInstance()).getBool(guideShownKey) ?? false;

  /// 记录用户已明确处理引导，拒绝布局也会在后续启动保留选择。
  Future<void> markGuideShown() async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      guideShownKey,
      true,
    )) {
      throw StateError('布局引导状态保存失败');
    }
  }
}
