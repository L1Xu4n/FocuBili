import 'package:flutter/material.dart';

/// 统一播放器文字控制项的高度、内边距、字号和文本基线。
class PlayerControlLabel extends StatelessWidget {
  /// 创建一个与清晰度、倍速和选集共用的紧凑文字标签。
  const PlayerControlLabel({super.key, required this.text});

  final String text;

  /// 构建固定 34 高度并严格垂直居中的白色标签。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
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
  }) : super(
         onPressed: onPressed,
         icon: Icon(icon, color: Colors.white),
         tooltip: tooltip,
         iconSize: 20,
         padding: EdgeInsets.zero,
         constraints: const BoxConstraints.tightFor(width: 34, height: 34),
       );
}

/// 使用与菜单标签完全相同的布局创建全屏选集按钮。
class PlayerPartSelectorButton extends InkWell {
  /// 创建点击后打开选集面板的紧凑按钮。
  const PlayerPartSelectorButton({super.key, required VoidCallback onPressed})
    : super(
        onTap: onPressed,
        child: const Tooltip(
          message: '选集',
          child: PlayerControlLabel(text: '选集'),
        ),
      );
}
