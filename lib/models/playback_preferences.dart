/// 保存播放器个性化手势配置，后续新增选项时可继续集中扩展。
class PlaybackPreferences {
  /// 创建播放器偏好；双击快进快退默认启用，保持现有用户习惯。
  const PlaybackPreferences({this.enableDoubleTapSeek = true});

  final bool enableDoubleTapSeek;

  /// 返回只替换指定字段的新配置，避免页面直接修改旧对象。
  PlaybackPreferences copyWith({bool? enableDoubleTapSeek}) {
    return PlaybackPreferences(
      enableDoubleTapSeek: enableDoubleTapSeek ?? this.enableDoubleTapSeek,
    );
  }
}
