/// 播放后端的省流听视频能力；开启后只能读取音频媒体，不能暗中下载画面。
abstract interface class ListeningPlaybackService {
  /// 切换纯音频与视频，保留当前进度、倍速及播放/暂停状态。
  Future<void> setAudioOnly(bool enabled);

  /// 在后端安排定时暂停；null 取消，后台执行不依赖页面动画或刷新。
  Future<void> setSleepTimer(Duration? duration);
}
