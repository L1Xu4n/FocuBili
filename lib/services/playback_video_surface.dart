import 'package:flutter/widgets.dart';

/// 标识能够直接提供 Flutter 视频画面的播放服务，例如 Windows 的 media_kit 后端。
abstract interface class PlaybackVideoSurface {
  /// 创建不含控制按钮的视频画面，播放页会继续在外层叠加现有手势、弹幕和控制栏。
  Widget buildVideoSurface();
}
