/// 学习清单中的一级学科分组；稳定编号与显示名称分离，重命名不影响任务。
class LearningSubjectFolder {
  const LearningSubjectFolder({required this.id, required this.name});

  static const int maximumNameCharacters = 30;
  final String id;
  final String name;

  LearningSubjectFolder rename(String name) =>
      LearningSubjectFolder(id: id, name: name);

  Map<String, Object> toJson() => {'id': id, 'name': name};

  static LearningSubjectFolder? tryParse(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'];
    if (id is! String ||
        name is! String ||
        id.trim().isEmpty ||
        name.trim().isEmpty ||
        name.trim().runes.length > maximumNameCharacters) {
      return null;
    }
    return LearningSubjectFolder(id: id.trim(), name: name.trim());
  }
}
