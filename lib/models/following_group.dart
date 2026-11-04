import 'account_collection.dart';

/// 本机关注分组；远端编号只用于重复导入去重，不授予写入 B 站的能力。
class FollowingGroup {
  /// 保存稳定编号、名称、成员及用户主动移除的成员。
  FollowingGroup({
    required this.id,
    required this.name,
    this.remoteId,
    Iterable<FollowedCreator> members = const [],
    Iterable<int> excluded = const [],
  }) : members = List.unmodifiable(members),
       excluded = Set.unmodifiable(excluded);
  final String id;
  final String name;
  final int? remoteId;
  final List<FollowedCreator> members;
  final Set<int> excluded;

  /// 修改名称或成员，并保持来源身份。
  FollowingGroup copyWith({
    String? name,
    Iterable<FollowedCreator>? members,
    Iterable<int>? excluded,
  }) => FollowingGroup(
    id: id,
    name: name ?? this.name,
    remoteId: remoteId,
    members: members ?? this.members,
    excluded: excluded ?? this.excluded,
  );

  /// 将不含凭据的分组资料写入本地 JSON。
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'remoteId': remoteId,
    'excluded': excluded.toList(),
    'members': members.map(creatorToJson).toList(),
  };

  /// 严格读取分组，损坏数据交由页面报告，避免静默覆盖。
  factory FollowingGroup.fromJson(Map<String, dynamic> json) => FollowingGroup(
    id: json['id'] as String,
    name: json['name'] as String,
    remoteId: json['remoteId'] as int?,
    excluded: (json['excluded'] as List? ?? []).cast<int>(),
    members: (json['members'] as List).map(
      (e) => creatorFromJson(Map<String, dynamic>.from(e as Map)),
    ),
  );

  /// 仅保存公开的 UP 资料与稳定 UID，不包含账号凭据。
  static Map<String, Object?> creatorToJson(FollowedCreator creator) => {
    'mid': creator.mid,
    'name': creator.name,
    'avatar': creator.avatarUrl,
    'sign': creator.sign,
    'official': creator.officialDescription,
  };

  /// 从本机公开资料恢复成员，用于离线展示与打开主页。
  static FollowedCreator creatorFromJson(Map<String, dynamic> json) =>
      FollowedCreator(
        mid: json['mid'] as int,
        name: json['name'] as String,
        avatarUrl: json['avatar'] as String? ?? '',
        sign: json['sign'] as String? ?? '',
        officialDescription: json['official'] as String? ?? '',
        followedAt: null,
      );
}

/// 一次完整只读导入的账号身份与分组快照。
class FollowingGroupImport {
  /// 固定导入所属账号，确认时再次核对，防止切号后写入错误账户。
  const FollowingGroupImport(this.mid, this.groups);
  final int mid;
  final List<FollowingGroup> groups;
}
