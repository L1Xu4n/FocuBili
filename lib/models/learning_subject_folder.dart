/// 学习清单中的一级学科分组；稳定编号与显示名称分离，重命名不影响任务。
class LearningSubjectFolder {
  const LearningSubjectFolder({
    required this.id,
    required this.name,
    this.iconId = defaultIconId,
    this.colorId = defaultColorId,
  });

  static const int maximumNameCharacters = 30;
  static const String defaultIconId = 'folder';
  static const String defaultColorId = 'blue';
  final String id;
  final String name;
  final String iconId;
  final String colorId;

  LearningSubjectFolder rename(String name, {String? iconId, String? colorId}) =>
      LearningSubjectFolder(
        id: id,
        name: name,
        iconId: iconId ?? this.iconId,
        colorId: colorId ?? this.colorId,
      );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'iconId': iconId,
    'colorId': colorId,
  };

  static LearningSubjectFolder? tryParse(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'];
    if (id is! String ||
        name is! String ||
        id.trim().isEmpty ||
        name.trim().isEmpty ||
        name.trim().runes.length > maximumNameCharacters) {
      return null;
    }
    final icon = json['iconId'];
    final color = json['colorId'];
    return LearningSubjectFolder(
      id: id.trim(),
      name: name.trim(),
      iconId: icon is String && icon.isNotEmpty ? icon : defaultIconId,
      colorId: color is String && color.isNotEmpty ? color : defaultColorId,
    );
  }
}
