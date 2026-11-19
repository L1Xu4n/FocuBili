import 'package:flutter/material.dart';

import '../../models/learning_subject_folder.dart';

/// Stable stored IDs are kept separate from their localized labels and glyphs.
class LearningFolderIcon {
  const LearningFolderIcon(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

class LearningFolderColor {
  const LearningFolderColor(this.id, this.label, this.color);
  final String id;
  final String label;
  final Color color;
}

const learningFolderIcons = <LearningFolderIcon>[
  LearningFolderIcon('folder', '文件夹', Icons.folder_outlined),
  LearningFolderIcon('book', '书本', Icons.menu_book_outlined),
  LearningFolderIcon('sigma', '数学', Icons.functions),
  LearningFolderIcon('atom', '原子', Icons.bubble_chart_outlined),
  LearningFolderIcon('code', '代码', Icons.code),
  LearningFolderIcon('globe', '地球', Icons.public_outlined),
  LearningFolderIcon('flask', '实验', Icons.science_outlined),
  LearningFolderIcon('leaf', '树叶', Icons.eco_outlined),
  LearningFolderIcon('music', '音乐', Icons.music_note_outlined),
  LearningFolderIcon('palette', '画板', Icons.palette_outlined),
  LearningFolderIcon('star', '星星', Icons.star_border),
  LearningFolderIcon('target', '目标', Icons.gps_fixed),
  LearningFolderIcon('pencil', '铅笔', Icons.edit_outlined),
  LearningFolderIcon('graduation', '毕业帽', Icons.school_outlined),
  LearningFolderIcon('chart', '图表', Icons.bar_chart),
  LearningFolderIcon('chip', '芯片', Icons.memory_outlined),
  LearningFolderIcon('language', '语言', Icons.translate),
  LearningFolderIcon('headphones', '耳机', Icons.headphones_outlined),
];

const learningFolderColors = <LearningFolderColor>[
  LearningFolderColor('blue', '蓝色', Color(0xff638eff)),
  LearningFolderColor('teal', '青色', Color(0xff36d7ca)),
  LearningFolderColor('green', '绿色', Color(0xff69d677)),
  LearningFolderColor('yellow', '黄色', Color(0xffffc346)),
  LearningFolderColor('pink', '粉色', Color(0xffff729f)),
  LearningFolderColor('purple', '紫色', Color(0xffb99bff)),
  LearningFolderColor('orange', '橙色', Color(0xffff9366)),
];

LearningFolderIcon learningFolderIcon(String id) => learningFolderIcons.firstWhere(
  (item) => item.id == id,
  orElse: () => learningFolderIcons.first,
);

LearningFolderColor learningFolderColor(String id) => learningFolderColors.firstWhere(
  (item) => item.id == id,
  orElse: () => learningFolderColors.first,
);

/// Only the small glyph backing changes with the effective app theme.
class LearningFolderBadge extends StatelessWidget {
  const LearningFolderBadge({
    super.key,
    this.iconId = LearningSubjectFolder.defaultIconId,
    this.colorId = LearningSubjectFolder.defaultColorId,
    this.size = 24,
  });

  final String iconId;
  final String colorId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = learningFolderColor(colorId).color;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = Color.lerp(dark ? Colors.black : Colors.white, color, 0.18)!;
    final foreground = dark ? color : Color.lerp(Colors.black, color, 0.52)!;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.27),
      ),
      child: LearningFolderGlyph(iconId: iconId, size: size * 0.56, color: foreground),
    );
  }
}

class LearningFolderGlyph extends StatelessWidget {
  const LearningFolderGlyph({super.key, required this.iconId, required this.size, this.color});
  final String iconId;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (iconId == 'sigma' || iconId == 'atom') {
      return CustomPaint(
        size: Size.square(size),
        painter: _LearningGlyphPainter(iconId, color ?? IconTheme.of(context).color ?? Colors.black),
      );
    }
    return Icon(learningFolderIcon(iconId).icon, size: size, color: color);
  }
}

class _LearningGlyphPainter extends CustomPainter {
  const _LearningGlyphPainter(this.id, this.color);
  final String id;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    if (id == 'sigma') {
      final path = Path()
        ..moveTo(w * .8, w * .16)
        ..lineTo(w * .2, w * .16)
        ..lineTo(w * .52, w * .5)
        ..lineTo(w * .2, w * .84)
        ..lineTo(w * .8, w * .84);
      canvas.drawPath(path, paint);
    } else {
      canvas.save();
      canvas.translate(w / 2, w / 2);
      for (var i = 0; i < 3; i++) {
        canvas.save();
        canvas.rotate(i * 1.0471975512);
        canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: w * .85, height: w * .3), paint);
        canvas.restore();
      }
      canvas.drawCircle(Offset.zero, w * .07, paint..style = PaintingStyle.fill);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LearningGlyphPainter oldDelegate) => id != oldDelegate.id || color != oldDelegate.color;
}
