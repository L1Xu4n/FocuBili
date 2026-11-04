/// 保存线路选择方式；名称同时用于本机存储和 Android 通道。
enum PlaybackLinePreference {
  smart('智能优选'),
  primary('主线路优先'),
  backup('备用线路优先');

  /// 为选择器提供简短的中文名称。
  const PlaybackLinePreference(this.label);

  final String label;

  /// 旧配置或未知值恢复智能优选，避免版本升级造成无法播放。
  static PlaybackLinePreference fromName(Object? value) =>
      PlaybackLinePreference.values.firstWhere(
        (item) => item.name == value,
        orElse: () => PlaybackLinePreference.smart,
      );
}
