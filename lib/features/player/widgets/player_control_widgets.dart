import 'package:flutter/material.dart';

import '../../../models/playback_preferences.dart';
import 'player_timeline.dart';

/// 播放器与设置预览共用的实际尺寸，文字、图标和命中区域按同一比例增长。
class PlayerControlSize {
  /// 读取校验后的播放栏比例。
  PlayerControlSize(double value)
    : scale = PlaybackPreferences.normalizeControlScale(value);

  final double scale;

  /// 返回普通按钮的实际点击宽高。
  double get button => 34 * scale;

  /// 返回更多菜单按钮的实际宽高。
  double get moreButton => 38 * scale;

  /// 返回按钮中的图标大小。
  double get icon => 20 * scale;

  /// 返回控制栏共用的文字字号。
  double get labelFont => 11 * scale;

  /// 返回进度条完整可拖动高度。
  double get progressHeight => 24 * scale;

  /// 返回真实轨道的绘制厚度。
  double get trackHeight => 1.2 * scale;

  /// 返回可见进度滑块的半径。
  double get thumbRadius => 3.5 * scale;

  /// 放大后将侧边入口移向中央空白区，避开底栏换行后的进度条。
  double get sideControlAlignmentY => -0.4 * (scale - 1).clamp(0, 1);

  /// 按锁定按钮的实际高度计算与侧边笔记相同的纵向对齐位置。
  double sideControlCenter(double viewportHeight) {
    final height = 48 * scale;
    return height / 2 +
        (viewportHeight - height) / 2 * (1 + sideControlAlignmentY);
  }
}

/// 统一播放器文字控制项的高度、内边距、字号和文本基线。
class PlayerControlLabel extends StatelessWidget {
  /// 创建一个与清晰度、倍速和选集共用的紧凑文字标签。
  const PlayerControlLabel({super.key, required this.text, this.scale = 1});

  final String text;
  final double scale;

  /// 构建随偏好放大的标签，保持选集、清晰度、倍速文字基线一致。
  @override
  Widget build(BuildContext context) {
    final size = PlayerControlSize(scale);
    return SizedBox(
      height: size.button,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 5 * size.scale),
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: size.labelFont,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 提供播放器上下栏共用的固定尺寸图标按钮。
class PlayerCompactIconButton extends IconButton {
  /// 创建 34×34 的按钮并接收图标、提示和点击回调。
  PlayerCompactIconButton({
    super.key,
    required VoidCallback onPressed,
    required IconData icon,
    required String tooltip,
    double scale = 1,
  }) : super(
         onPressed: onPressed,
         icon: Icon(icon, color: Colors.white),
         tooltip: tooltip,
         iconSize: PlayerControlSize(scale).icon,
         padding: EdgeInsets.zero,
         constraints: BoxConstraints.tightFor(
           width: PlayerControlSize(scale).button,
           height: PlayerControlSize(scale).button,
         ),
         style: IconButton.styleFrom(
           fixedSize: Size.square(PlayerControlSize(scale).button),
           minimumSize: Size.square(PlayerControlSize(scale).button),
           tapTargetSize: MaterialTapTargetSize.shrinkWrap,
         ),
       );
}

/// 使用与菜单标签完全相同的布局创建全屏选集按钮。
class PlayerPartSelectorButton extends InkWell {
  /// 创建点击后打开选集面板的紧凑按钮。
  PlayerPartSelectorButton({
    super.key,
    required VoidCallback onPressed,
    double scale = 1,
  }) : super(
         onTap: onPressed,
         child: Tooltip(
           message: '选集',
           child: PlayerControlLabel(text: '选集', scale: scale),
         ),
       );
}

/// 为真实播放与设置预览提供同样的轨道尺寸和拖动命中高度。
class PlayerProgressSlider extends StatelessWidget {
  /// 接收比例、当前进度和原有拖动回调。
  const PlayerProgressSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.scale = 1,
    this.sliderKey,
  });
  final double value;
  final double scale;
  final Key? sliderKey;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// 放大滑块与可拖动高度，同时维持与章节和微型进度条相同的轨道端点。
  @override
  Widget build(BuildContext context) {
    final size = PlayerControlSize(scale);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: size.trackHeight,
        trackShape: const PlayerTimelineTrackShape(),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: size.thumbRadius),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 8 * size.scale),
      ),
      child: SizedBox(
        height: size.progressHeight,
        child: Slider(
          key: sliderKey,
          padding: EdgeInsets.zero,
          value: value,
          onChanged: onChanged,
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
        ),
      ),
    );
  }
}
