/// 当前播放会话的结束行为；不包含相关推荐。
enum PlaybackMode {
  pause('播完暂停'),
  order('顺序播放'),
  single('单项循环'),
  cycle('列表循环');

  /// 保存稳定标识对应的界面名称。
  const PlaybackMode(this.label);
  final String label;

  /// 未保存或损坏的旧配置默认顺序播放。
  static PlaybackMode fromName(Object? value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => order);
}
