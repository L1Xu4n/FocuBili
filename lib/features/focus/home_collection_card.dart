import 'dart:convert';
import 'dart:async';
import 'home_favorite_cover.dart';
import '../common/app_network_image.dart';
import '../../services/image_resource_cache.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/account_collection.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/following_group_service.dart';
import '../profile/app_favorite_detail_page.dart';
import '../profile/app_favorite_folders_page.dart';
import '../profile/favorite_folders_page.dart';
import '../profile/favorite_videos_page.dart';
import '../profile/followed_creators_page.dart';
import '../profile/following_groups_page.dart';
import '../profile/user_profile_page.dart';
import 'home_favorite_source_dialog.dart';

/// 首页选择项保存稳定身份、名称及可选公开头像，不保存会话或收藏封面地址。
class _HomeChoice {
  /// 创建可打开的收藏夹、分组或 UP 主入口。
  const _HomeChoice(this.kind, this.id, this.label, {this.imageUrl = ''});
  final String imageUrl;
  final String kind;
  final String id;
  final String label;

  /// 合成跨来源不会碰撞的选择身份。
  String get key => '$kind:$id';

  /// 序列化用户顺序与入口身份。
  Map<String, String> toJson() => {
    'kind': kind,
    'id': id,
    'label': label,
    if (kind == 'creator' && _safeAvatar(imageUrl).isNotEmpty)
      'avatar': _safeAvatar(imageUrl),
  };

  /// 读取本机配置，损坏项使本次读取失败而不覆盖原文件。
  factory _HomeChoice.fromJson(Map<String, dynamic> json) => _HomeChoice(
    json['kind'] as String,
    json['id'] as String,
    json['label'] as String,
    imageUrl: _safeAvatar(json['avatar'] as String? ?? ''),
  );
}

/// 头像快照不接受本地文件、鉴权查询、带凭据地址或内联数据。
String _safeAvatar(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment
      ? value.trim()
      : '';
}

/// 可由用户主动添加的收藏/关注卡片，支持总览入口与自选内容。
class HomeCollectionCard extends StatefulWidget {
  /// 指定收藏或关注卡片，两类配置独立且按账号隔离。
  const HomeCollectionCard({
    super.key,
    required this.favorites,
    this.accountDataService,
    this.localFavorites,
    this.localGroups,
    this.showCustomization = false,
    this.allowNavigation = true,
    this.imageCache,
  });
  final BilibiliAccountDataService? accountDataService;
  final AppFavoritesService? localFavorites;
  final FollowingGroupService? localGroups;
  final bool favorites;
  final bool showCustomization;
  final bool allowNavigation;
  final ImageResourceCache? imageCache;

  /// 创建监听账号切换的卡片状态。
  @override
  State<HomeCollectionCard> createState() => _HomeCollectionCardState();
}

class _HomeCollectionCardState extends State<HomeCollectionCard> {
  late final _api = widget.accountDataService ?? BilibiliAccountDataService();
  late final _favorites = widget.localFavorites ?? AppFavoritesService();
  late final _groups = widget.localGroups ?? FollowingGroupService.instance;
  List<_HomeChoice> _selected = [];
  Map<String, String> _localFolderNames = {};
  Map<String, String> _localFolderCovers = {};
  Map<String, String> _remoteFolderCovers = {};
  Future<AccountDataPage<FavoriteFolder>>? _remoteFoldersPending;
  AccountDataPage<FavoriteFolder>? _remoteFoldersSnapshot;
  DateTime? _remoteFoldersLoadedAt;
  Map<int, Future<String>> _fallbackCoverRequests = {};
  int _folderNamesGeneration = 0;
  Map<String, String> _localGroupNames = {};
  Map<String, String> _groupAvatars = {};
  Map<String, String> _verifiedFollowingAvatars = {};
  int? _followingMid;
  DateTime? _followingReadAt;
  AccountDataPage<FollowedCreator>? _followingSnapshot;
  Future<AccountDataPage<FollowedCreator>>? _followingPending;
  int _groupNamesGeneration = 0;
  int _groupNamesMid = 0;
  bool _choosingFavoriteSource = false;
  bool _custom = false;
  bool _loading = true;
  bool _identityUnavailable = false;
  int _mid = 0;
  int _generation = 0;

  /// 返回当前账号和卡片类型的独立键。
  String _key(int mid) =>
      'home_collection.v1.${widget.favorites ? "favorites" : "followings"}.$mid';

  /// 初始读取配置，并订阅账号失效通知以立即隐藏旧账号内容。
  @override
  void initState() {
    super.initState();
    CacheLifecycle.account.addListener(_accountChanged);
    AppFavoritesService.contentsRevision.addListener(_loadLocalFolderNames);
    if (!widget.favorites) _groups.changes.addListener(_onGroupsChanged);
    _load();
  }

  /// 退出卡片时解除账号监听，取消尚未完成的读取。
  @override
  void dispose() {
    _generation++;
    _folderNamesGeneration++;
    _groupNamesGeneration++;
    if (!widget.favorites) _groups.changes.removeListener(_onGroupsChanged);
    AppFavoritesService.contentsRevision.removeListener(_loadLocalFolderNames);
    CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }

  /// 切号先清理视图，再读取新账号专属配置。
  void _accountChanged() {
    if (!mounted) return;
    _groupNamesGeneration++;
    _folderNamesGeneration++;
    _remoteFoldersPending = null;
    _remoteFoldersSnapshot = null;
    _remoteFoldersLoadedAt = null;
    _fallbackCoverRequests = {};
    setState(() {
      _localFolderCovers = {};
      _remoteFolderCovers = {};
      _groupNamesMid = 0;
      _localGroupNames = {};
      _groupAvatars = {};
      _verifiedFollowingAvatars = {};
      _followingMid = null;
      _followingReadAt = null;
      _followingSnapshot = null;
      _followingPending = null;
      _selected = [];
      _custom = false;
      _identityUnavailable = false;
      _loading = true;
    });
    _load();
  }

  /// 只接受最后一次账号读取的结果，避免旧请求覆盖新账号。
  Future<void> _load() async {
    final generation = ++_generation;
    _remoteFoldersSnapshot = null;
    _remoteFoldersLoadedAt = null;
    _fallbackCoverRequests = {};
    try {
      final mid = await _api.currentHomeCollectionMid();
      if (!mounted || generation != _generation) return;
      if (mid != _mid) {
        _groupNamesGeneration++;
        _groupNamesMid = 0;
        _localGroupNames = {};
        _groupAvatars = {};
        _verifiedFollowingAvatars = {};
        _followingMid = null;
        _followingReadAt = null;
        _followingSnapshot = null;
        _followingPending = null;
        _folderNamesGeneration++;
        _remoteFoldersPending = null;
        _remoteFoldersSnapshot = null;
        _remoteFoldersLoadedAt = null;
        _fallbackCoverRequests = {};
        setState(() {
          _localFolderCovers = {};
          _remoteFolderCovers = {};
          _selected = [];
          _loading = true;
        });
      }
      if (mid == null) {
        _groupNamesGeneration++;
        setState(() {
          _selected = [];
          _localGroupNames = {};
          _groupAvatars = {};
          _verifiedFollowingAvatars = {};
          _followingMid = null;
          _followingReadAt = null;
          _followingSnapshot = null;
          _followingPending = null;
          _groupNamesMid = 0;
          _custom = false;
          _identityUnavailable = true;
          _loading = false;
        });
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(mid));
      final config = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final selected = (config['items'] as List? ?? [])
          .map((e) => _HomeChoice.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted || generation != _generation) return;
      final custom = config['custom'] == true;
      if (!widget.favorites && custom && selected.isNotEmpty && mid > 0) {
        await _loadLocalGroupNames(mid);
      }
      if (mounted && generation == _generation) {
        setState(() {
          _mid = mid;
          _identityUnavailable = false;
          _custom = custom;
          _selected = selected;
          _loading = false;
        });
        if (!widget.favorites &&
            _custom &&
            mid > 0 &&
            selected.any(
              (choice) =>
                  choice.kind == 'creator' && _choiceImage(choice).isEmpty,
            )) {
          unawaited(_hydrateCreatorAvatars(mid, generation));
        }
        if (widget.favorites &&
            selected.any((choice) => choice.kind == 'local')) {
          unawaited(_loadLocalFolderNames());
        }
        if (widget.favorites &&
            _custom &&
            mid > 0 &&
            selected.any((choice) => choice.kind == 'remote')) {
          unawaited(_loadRemoteCovers(mid, generation));
        }
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  /// 本机名称独立刷新，不取消正在编辑的配置，也不回写保存的入口快照。
  Future<void> _loadLocalFolderNames({List<_HomeChoice>? choices}) async {
    if (!widget.favorites ||
        !_custom ||
        !(choices ?? _selected).any((choice) => choice.kind == 'local')) {
      return;
    }
    final generation = ++_folderNamesGeneration;
    try {
      final folders = await _favorites.loadFolders();
      final selectedIds = (choices ?? _selected)
          .where((choice) => choice.kind == 'local')
          .map((choice) => choice.id)
          .toSet();
      final covers = <String, String>{};
      for (final folder in folders.where(
        (folder) => selectedIds.contains(folder.id),
      )) {
        try {
          final items = await _favorites.loadItems(folder.id);
          final available = items.where(
            (item) => item.coverUrl.trim().isNotEmpty,
          );
          if (available.isNotEmpty) {
            covers[folder.id] = available.first.coverUrl;
          }
        } catch (_) {
          // 无法确认当前内容时使用占位，不把过期画面当成当前封面。
        }
      }
      if (mounted && generation == _folderNamesGeneration) {
        setState(() {
          _localFolderCovers = covers;
          _localFolderNames = {
            for (final folder in folders) folder.id: folder.name,
          };
        });
      }
    } catch (_) {
      // 名称仍保留快照，但无法确认内容时不展示旧封面。
      if (mounted && generation == _folderNamesGeneration) {
        setState(() => _localFolderCovers = {});
      }
    }
  }

  /// 合并在途列表并短暂复用成功快照；页面返回会失效，重建不发请求。
  Future<AccountDataPage<FavoriteFolder>> _favoriteFolders() {
    final pending = _remoteFoldersPending;
    if (pending != null) return pending;
    if (_remoteFoldersSnapshot != null &&
        _remoteFoldersLoadedAt != null &&
        DateTime.now().difference(_remoteFoldersLoadedAt!) <
            const Duration(minutes: 2)) {
      return Future.value(_remoteFoldersSnapshot);
    }
    _fallbackCoverRequests = {};
    final request = _api.loadFavoriteFolders();
    _remoteFoldersPending = request;
    unawaited(
      request.then<void>(
        (page) {
          if (identical(_remoteFoldersPending, request)) {
            _remoteFoldersPending = null;
            if (page.isSuccess) {
              _remoteFoldersSnapshot = page;
              _remoteFoldersLoadedAt = DateTime.now();
            }
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_remoteFoldersPending, request)) {
            _remoteFoldersPending = null;
          }
        },
      ),
    );
    return request;
  }

  /// 账号和页面读取代次都匹配时才采用封面；失败清空而不覆盖选择配置。
  Future<void> _loadRemoteCovers(int mid, int generation) async {
    try {
      final page = await _favoriteFolders();
      final currentMid = await _api.currentHomeCollectionMid();
      if (!mounted || generation != _generation || mid != _mid) return;
      if (currentMid != mid) {
        _accountChanged();
        return;
      }
      setState(() {
        _remoteFolderCovers = page.isSuccess
            ? {
                for (final folder in page.items)
                  if (folder.isAvailable) '${folder.mediaId}': folder.coverUrl,
              }
            : {};
      });
      if (page.isSuccess) {
        await _backfillSelectedCovers(page.items, mid, generation);
      }
    } catch (_) {
      if (mounted && generation == _generation && mid == _mid) {
        setState(() => _remoteFolderCovers = {});
      }
    }
  }

  /// 只为已选且有视频的缺图收藏夹补查第一页，每批最多三项。
  Future<void> _backfillSelectedCovers(
    List<FavoriteFolder> folders,
    int mid,
    int generation,
  ) async {
    final ids = _selected
        .where((choice) => choice.kind == 'remote')
        .map((choice) => choice.id)
        .toSet();
    final missing = folders
        .where(
          (folder) =>
              ids.contains('${folder.mediaId}') &&
              folder.isAvailable &&
              folder.mediaCount > 0 &&
              folder.coverUrl.trim().isEmpty,
        )
        .toList();
    for (var offset = 0; offset < missing.length; offset += 3) {
      if (!mounted || generation != _generation || mid != _mid) return;
      final batch = missing.skip(offset).take(3);
      final covers = await Future.wait(
        batch.map((folder) async {
          final request = _fallbackCoverRequests.putIfAbsent(
            folder.mediaId,
            () async {
              try {
                final videos = await _api.loadFavoriteVideos(folder.mediaId);
                if (videos.isSuccess) {
                  for (final video in videos.items) {
                    if (video.isAvailable && video.coverUrl.trim().isNotEmpty) {
                      return video.coverUrl;
                    }
                  }
                }
              } catch (_) {
                /* 单夹失败不影响其余来源。 */
              }
              return '';
            },
          );
          final cover = await request;
          if (cover.isEmpty &&
              identical(_fallbackCoverRequests[folder.mediaId], request)) {
            _fallbackCoverRequests.remove(folder.mediaId);
          }
          return MapEntry('${folder.mediaId}', cover);
        }),
      );
      if (!mounted || generation != _generation || mid != _mid) return;
      if (await _api.currentHomeCollectionMid() != mid) {
        if (mounted && generation == _generation) _accountChanged();
        return;
      }
      if (!mounted || generation != _generation || mid != _mid) return;
      setState(() => _remoteFolderCovers.addEntries(covers));
    }
  }

  void _onGroupsChanged() {
    final mid = _groups.changes.value?.mid;
    if (_custom &&
        _selected.isNotEmpty &&
        mid != null &&
        mid == _groupNamesMid) {
      _loadLocalGroupNames(mid);
    }
  }

  /// 只读取当前账号的本机分组名称，忽略切号前的迟到结果。
  Future<void> _loadLocalGroupNames(int mid) async {
    if (widget.favorites) return;
    if (_groupNamesMid != mid) {
      _groupNamesMid = mid;
      _localGroupNames = {};
      _groupAvatars = {};
      _verifiedFollowingAvatars = {};
      _followingMid = null;
      _followingReadAt = null;
      _followingSnapshot = null;
      _followingPending = null;
    }
    final generation = ++_groupNamesGeneration;
    try {
      final groups = await _groups.load(mid);
      if (mounted && generation == _groupNamesGeneration) {
        setState(() {
          _localGroupNames = {for (final group in groups) group.id: group.name};
          _groupAvatars = {
            for (final group in groups)
              for (final creator in group.members)
                if (creator.avatarUrl.isNotEmpty)
                  '${creator.mid}': creator.avatarUrl,
          };
        });
      }
    } catch (_) {
      // 无法读取的分组仍显示同一账号的最后成功名称或保存快照。
    }
  }

  /// 本机条目按稳定 ID 取名称，远端及已删除的入口保留快照。
  String _label(_HomeChoice choice) => switch (choice.kind) {
    'local' => _localFolderNames[choice.id] ?? choice.label,
    'group' when _groupNamesMid == _mid =>
      _localGroupNames[choice.id] ?? choice.label,
    _ => choice.label,
  };

  String _choiceImage(_HomeChoice choice) => switch (choice.kind) {
    'creator' =>
      _groupAvatars[choice.id] ??
          (choice.imageUrl.isNotEmpty
              ? choice.imageUrl
              : _verifiedFollowingAvatars[choice.id] ?? ''),
    'local' => _localFolderCovers[choice.id] ?? choice.imageUrl,
    'remote' => _remoteFolderCovers[choice.id] ?? choice.imageUrl,
    _ => '',
  };

  Future<void> _openEditorChoice(_HomeChoice choice, bool Function() valid) =>
      _open(choice, preserveDraft: true, callerValid: valid);

  /// 显示短反馈，保留当前成功配置。
  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 统一打开页面，返回后刷新名称与账号配置。
  Future<void> _push(Widget page) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => page));
    if (mounted) await _load();
  }

  /// 收藏总览提供本机与 B 站两条直接路径，关注直接打开现有总览。
  Future<void> _overview() async {
    if (!widget.favorites) {
      await _push(const FollowedCreatorsPage());
      return;
    }
    if (_choosingFavoriteSource) return;
    _choosingFavoriteSource = true;
    try {
      final local = await showDialog<bool>(
        context: context,
        builder: (context) => const HomeFavoriteSourceDialog(),
      );
      if (local != null && mounted) {
        await _push(
          local ? const AppFavoriteFoldersPage() : const FavoriteFoldersPage(),
        );
      }
    } finally {
      _choosingFavoriteSource = false;
    }
  }

  /// 按稳定编号解析入口，已删除或失效内容只反馈，不跳到其他项目。
  bool _openingChoice = false;
  Future<void> _open(
    _HomeChoice choice, {
    bool preserveDraft = false,
    bool Function()? callerValid,
  }) async {
    if (_openingChoice) return;
    _openingChoice = true;
    final openingMid = _mid;
    final openingGeneration = _generation;
    final openingRevision = CacheLifecycle.account.value;
    bool current() =>
        mounted &&
        openingMid == _mid &&
        openingGeneration == _generation &&
        openingRevision == CacheLifecycle.account.value &&
        (callerValid?.call() ?? true);
    Future<void> push(Widget page) async {
      if (!current()) return;
      if (preserveDraft) {
        await Navigator.of(
          context,
        ).push<void>(MaterialPageRoute(builder: (_) => page));
      } else {
        await _push(page);
      }
    }

    try {
      if (choice.kind != 'local' &&
          await _api.currentAccountMid() != openingMid) {
        CacheLifecycle.accountChanged();
        throw StateError('账号已变化，请重试');
      }
      if (!current()) return;
      switch (choice.kind) {
        case 'local':
          final matches = (await _favorites.loadFolders()).where(
            (f) => f.id == choice.id,
          );
          if (matches.isEmpty) throw StateError('收藏夹已删除，请重新自定义');
          if (mounted) {
            await push(AppFavoriteDetailPage(folder: matches.first));
          }
        case 'remote':
          await push(
            FavoriteVideosPage(
              folder: FavoriteFolder(
                mediaId: int.parse(choice.id),
                title: choice.label,
                coverUrl: '',
                mediaCount: 0,
                isAvailable: true,
              ),
            ),
          );
        case 'group':
          final matches = (await _groups.load(
            _mid,
          )).where((g) => g.id == choice.id);
          if (matches.isEmpty) throw StateError('分组已删除，请重新自定义');
          if (mounted) await push(FollowingGroupsPage(groupId: choice.id));
        case 'creator':
          await push(
            UserProfilePage(
              mid: int.parse(choice.id),
              initialName: choice.label,
              initialAvatarUrl: _choiceImage(choice),
            ),
          );
      }
    } catch (e) {
      if (current()) _message('$e');
    } finally {
      _openingChoice = false;
    }
  }

  /// 旧首页仅补查关注第一页；同账号五分钟内复用含失败的结果，不逐 UP 探测。
  Future<AccountDataPage<FollowedCreator>> _followingFirstPage(
    int mid, {
    bool retryFailure = false,
  }) {
    if (_followingMid != mid) {
      _followingMid = mid;
      _followingReadAt = null;
      _followingSnapshot = null;
      _followingPending = null;
    }
    if (_followingPending != null) return _followingPending!;
    final snapshot = _followingSnapshot;
    if (snapshot != null &&
        _followingReadAt != null &&
        DateTime.now().difference(_followingReadAt!) <
            const Duration(minutes: 5) &&
        (!retryFailure || snapshot.isSuccess)) {
      return Future.value(snapshot);
    }
    late final Future<AccountDataPage<FollowedCreator>> request;
    request = _api
        .loadFollowedCreators(page: 1)
        .then((page) {
          if (_followingMid == mid && identical(_followingPending, request)) {
            _followingSnapshot = page;
            _followingReadAt = DateTime.now();
          }
          return page;
        })
        .whenComplete(() {
          if (identical(_followingPending, request)) _followingPending = null;
        });
    _followingPending = request;
    return request;
  }

  Future<void> _hydrateCreatorAvatars(int mid, int generation) async {
    try {
      final page = await _followingFirstPage(mid);
      if (!mounted || generation != _generation || !page.isSuccess) return;
      if (!await _sameAccount(mid) || !mounted || generation != _generation) {
        return;
      }
      final selectedIds = _selected
          .where((item) => item.kind == 'creator')
          .map((item) => item.id)
          .toSet();
      setState(() {
        for (final creator in page.items) {
          if (selectedIds.contains('${creator.mid}') &&
              creator.avatarUrl.isNotEmpty) {
            _verifiedFollowingAvatars['${creator.mid}'] = creator.avatarUrl;
          }
        }
      });
    } catch (_) {
      /* 离线保留占位，不修改已选配置。 */
    }
  }

  Future<bool> _sameAccount(int expectedMid) async {
    final current = await _api.currentHomeCollectionMid();
    if (current != null && current != expectedMid && mounted) {
      CacheLifecycle.accountChanged();
    }
    return current == expectedMid;
  }

  /// 远端候选完整才展示；失败或切换账号不影响已选快照。
  Future<List<_HomeChoice>?> _loadRemoteChoices(
    bool Function() stillEditing,
  ) async {
    final choices = <_HomeChoice>[];
    final requestMid = _mid;
    try {
      if (!stillEditing() ||
          !await _sameAccount(requestMid) ||
          !stillEditing()) {
        return null;
      }
      if (widget.favorites) {
        final page = await _favoriteFolders();
        if (!page.isSuccess || !stillEditing()) return null;
        if (!await _sameAccount(requestMid) || !stillEditing()) {
          return null;
        }

        for (final folder in page.items) {
          choices.add(
            _HomeChoice(
              'remote',
              '${folder.mediaId}',
              folder.title,
              imageUrl: folder.coverUrl,
            ),
          );
        }
      } else {
        final seen = <int>{};
        for (var page = 1; ; page++) {
          if (page > 1000) return null;
          final result = page == 1
              ? await _followingFirstPage(requestMid, retryFailure: true)
              : await _api.loadFollowedCreators(page: page);
          if (!result.isSuccess ||
              !stillEditing() ||
              !await _sameAccount(requestMid) ||
              !stillEditing()) {
            return null;
          }
          final previous = seen.length;
          for (final creator in result.items) {
            if (seen.add(creator.mid)) {
              choices.add(
                _HomeChoice(
                  'creator',
                  '${creator.mid}',
                  creator.name,
                  imageUrl: creator.avatarUrl,
                ),
              );
            }
          }
          if (!result.hasMore) break;
          if (seen.length == previous) return null;
        }
      }
      if (!stillEditing() ||
          !await _sameAccount(requestMid) ||
          !stillEditing()) {
        return null;
      }
      return choices;
    } catch (_) {
      return null;
    }
  }

  Future<List<_HomeChoice>> _loadLocalChoices(
    int mid,
    bool Function() valid,
  ) async {
    final choices = <_HomeChoice>[];
    if (!valid() || !await _sameAccount(mid) || !valid()) return choices;
    if (widget.favorites) {
      for (final folder in await _favorites.loadFolders()) {
        if (!valid()) return [];
        var cover = '';
        try {
          final items = await _favorites.loadItems(folder.id);
          final images = items.where((item) => item.coverUrl.trim().isNotEmpty);
          if (images.isNotEmpty) cover = images.first.coverUrl;
        } catch (_) {
          /* 单夹缺图不阻止预览或添加。 */
        }
        choices.add(
          _HomeChoice('local', folder.id, folder.name, imageUrl: cover),
        );
      }
    } else if (mid > 0) {
      for (final group in await _groups.load(mid)) {
        choices.add(_HomeChoice('group', group.id, group.name));
      }
    }
    return valid() ? choices : [];
  }

  /// 先开放本机编辑；远端候选独立加载，保存前仍核验账号。
  Future<void> _configure() async {
    if (_loading || _identityUnavailable) return;
    setState(() => _loading = true);
    final generation = _generation;
    final accountRevision = CacheLifecycle.account.value;
    bool isCurrent() => mounted && generation == _generation;
    var editing = true;
    try {
      final mid = await _api.currentHomeCollectionMid();
      if (!isCurrent()) return;
      // 读不到刚才显示的账号时，不把其编辑误保存到访客空间。
      if (mid == null || mid != _mid) {
        throw StateError('无法确认当前账号，请稍后重试');
      }

      if (!mounted || !isCurrent()) return;
      final config = await Navigator.of(context)
          .push<(bool, List<_HomeChoice>)>(
            MaterialPageRoute(
              builder: (_) => _HomeChoiceEditor(
                title: widget.favorites ? '我的收藏' : '我的关注',
                favorites: widget.favorites,
                loadLocal: (valid) => _loadLocalChoices(
                  mid,
                  () => editing && isCurrent() && valid(),
                ),
                loadRemote: mid > 0
                    ? (valid) => _loadRemoteChoices(
                        () => editing && isCurrent() && valid(),
                      )
                    : null,
                accountRevision: accountRevision,
                selected: _selected
                    .map(
                      (item) => _HomeChoice(
                        item.kind,
                        item.id,
                        _label(item),
                        imageUrl: _choiceImage(item),
                      ),
                    )
                    .toList(),
                custom: _custom,
                imageCache: widget.imageCache,
                onOpen: _openEditorChoice,
              ),
            ),
          );
      editing = false;
      if (config == null || !isCurrent()) return;
      if ((await _api.currentHomeCollectionMid()) != mid) {
        if (isCurrent()) throw StateError('无法确认当前账号，配置未保存');
        return;
      }
      if (!isCurrent()) return;
      final prefs = await SharedPreferences.getInstance();
      if (!isCurrent()) return;
      if (!await prefs.setString(
        _key(mid),
        jsonEncode({
          'custom': config.$1,
          'items': config.$2.map((item) => item.toJson()).toList(),
        }),
      )) {
        throw StateError('保存失败');
      }
      if (isCurrent()) {
        setState(() {
          _mid = mid;
          _custom = config.$1;
          _selected = config.$2;
        });
        await _loadLocalFolderNames();
        if (!widget.favorites && _custom && _selected.isNotEmpty && mid > 0) {
          await _loadLocalGroupNames(mid);
        }
        if (widget.favorites &&
            _custom &&
            mid > 0 &&
            _selected.any((choice) => choice.kind == 'remote')) {
          unawaited(_loadRemoteCovers(mid, generation));
        }
      }
    } catch (e) {
      if (isCurrent()) _message('$e');
    } finally {
      if (isCurrent()) setState(() => _loading = false);
    }
  }

  /// 卡片只呈现标题与入口，不增加常驻操作说明。
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              widget.favorites
                  ? Icons.bookmarks_outlined
                  : Icons.people_outline,
            ),
            title: Text(widget.favorites ? '我的收藏' : '我的关注'),
            onTap: widget.allowNavigation ? _overview : null,
            trailing: widget.showCustomization
                ? IconButton(
                    key: ValueKey(
                      'customize-home-${widget.favorites ? "favorites" : "followings"}',
                    ),
                    tooltip: '自定义内容',
                    onPressed: _loading || _identityUnavailable
                        ? null
                        : _configure,
                    icon: Icon(
                      Icons.tune_rounded,
                      semanticLabel: widget.favorites ? '自定义我的收藏' : '自定义我的关注',
                    ),
                  )
                : null,
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_identityUnavailable && !_loading)
            ListTile(
              title: const Text('暂时无法确认 B 站账号，请检查网络或登录后重试。'),
              trailing: TextButton(
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
                child: const Text('重试'),
              ),
            ),
          if (_custom && !_loading) ...[
            if (_selected.isEmpty && widget.showCustomization)
              TextButton(onPressed: _configure, child: const Text('选择内容')),
            for (final choice in _selected)
              ListTile(
                dense: true,
                title: Text(
                  _label(choice),
                  semanticsLabel: widget.favorites
                      ? '${_label(choice)}，${choice.kind == 'local' ? '本机' : 'B 站'}收藏夹'
                      : _label(choice),
                ),
                leading:
                    widget.favorites &&
                        (choice.kind == 'local' || choice.kind == 'remote')
                    ? HomeFavoriteCover(
                        key: ValueKey('home-cover-${choice.key}'),
                        remote: choice.kind == 'remote',
                        cache: widget.imageCache,
                        coverUrl: choice.kind == 'local'
                            ? (_localFolderCovers[choice.id] ?? '')
                            : (_remoteFolderCovers[choice.id] ?? ''),
                      )
                    : _ChoiceAvatar(
                        choice: choice,
                        imageUrl: _choiceImage(choice),
                        cache: widget.imageCache,
                      ),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.allowNavigation ? () => _open(choice) : null,
              ),
          ],
        ],
      ),
    ),
  );
}

/// 独立编辑草稿，选择顺序由列表排序手柄决定。
class _HomeChoiceEditor extends StatefulWidget {
  /// 接收当前可用内容与已保存顺序，不在编辑过程中落盘。
  const _HomeChoiceEditor({
    required this.title,
    required this.favorites,
    required this.loadLocal,
    required this.loadRemote,
    required this.accountRevision,
    required this.selected,
    required this.custom,
    required this.onOpen,
    this.imageCache,
  });
  final String title;
  final bool favorites;
  final Future<List<_HomeChoice>> Function(bool Function()) loadLocal;
  final Future<List<_HomeChoice>?> Function(bool Function())? loadRemote;
  final int accountRevision;
  final List<_HomeChoice> selected;
  final bool custom;
  final Future<void> Function(_HomeChoice, bool Function()) onOpen;
  final ImageResourceCache? imageCache;

  /// 创建模式、选择与排序草稿。
  @override
  State<_HomeChoiceEditor> createState() => _HomeChoiceEditorState();
}

class _HomeChoiceEditorState extends State<_HomeChoiceEditor> {
  late bool _custom = widget.custom;
  late final List<_HomeChoice> _selected = [...widget.selected];
  String _query = '';
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _request++;
    _queryController.dispose();
    super.dispose();
  }

  List<_HomeChoice> _remote = [];
  List<_HomeChoice> _local = [];
  Future<List<_HomeChoice>?>? _remoteFuture;
  bool _managing = false;
  bool _localLoading = false;
  bool _localFailed = false;
  int _request = 0;

  void _chooseCustom() {
    final enriched = _selected.map(_enrich).toList();
    final request = ++_request;
    bool valid() =>
        mounted &&
        _managing &&
        request == _request &&
        CacheLifecycle.account.value == widget.accountRevision;
    setState(() {
      _selected
        ..clear()
        ..addAll(enriched);
      _custom = true;
      _managing = true;
      _local = [];
      _remote = [];
      _localLoading = true;
      _localFailed = false;
      _remoteFuture = widget.loadRemote?.call(valid);
    });
    widget
        .loadLocal(valid)
        .then(
          (items) {
            if (valid()) {
              setState(() {
                _local = items;
                _localLoading = false;
              });
            }
          },
          onError: (Object _) {
            if (valid()) {
              setState(() {
                _localLoading = false;
                _localFailed = true;
              });
            }
          },
        );
  }

  void _showModes() {
    // Keep enriched drafts, but never display a late result from the previous step.
    final enriched = _selected.map(_enrich).toList();
    setState(() {
      _selected
        ..clear()
        ..addAll(enriched);
      _request++;
      _managing = false;
      _remoteFuture = null;
      _remote = [];
      _local = [];
    });
  }

  Widget _modes() => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _mode(
            false,
            widget.favorites ? '仅显示收藏夹快捷入口' : '仅显示关注快捷入口',
            widget.favorites ? Icons.bookmarks_outlined : Icons.people_outline,
          ),
          const SizedBox(height: 16),
          _mode(
            true,
            widget.favorites ? '添加自选收藏夹快捷入口' : '添加自选关注快捷入口',
            Icons.add_circle_outline,
          ),
        ],
      ),
    ),
  );

  Widget _mode(bool custom, String label, IconData icon) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = _custom == custom;
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    final compact =
        MediaQuery.sizeOf(context).width < 400 &&
        MediaQuery.textScalerOf(context).scale(17) >= 27;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 112),
      child: FilledButton(
        key: ValueKey(custom ? 'home-mode-custom' : 'home-mode-overview'),
        style: FilledButton.styleFrom(
          padding: EdgeInsets.symmetric(
            vertical: 20,
            horizontal: compact ? 12 : 20,
          ),
          alignment: Alignment.centerLeft,
          side: BorderSide.none,
          backgroundColor: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHigh,
          foregroundColor: foreground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: custom
            ? _chooseCustom
            : () => setState(() {
                _custom = false;
              }),
        child: Semantics(
          selected: selected,
          child: Row(
            children: [
              Container(
                width: compact ? 32 : 44,
                height: compact ? 32 : 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? colors.primary
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: compact ? 20 : 24,
                  color: selected ? colors.onPrimary : colors.onSurfaceVariant,
                ),
              ),
              SizedBox(width: compact ? 12 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        custom ? '挑选要放在首页的内容' : '首页只保留总入口',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: selected
                              ? foreground
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected || (!compact && custom)) ...[
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check_rounded : Icons.chevron_right_rounded,
                  size: compact ? 18 : 22,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  _HomeChoice _enrich(_HomeChoice saved) {
    final matches = [
      ..._local,
      ..._remote,
    ].where((item) => item.key == saved.key && item.imageUrl.isNotEmpty);
    return matches.isEmpty ? saved : matches.first;
  }

  /// 修改草稿中的选择，取消后不影响已保存配置。
  void _toggle(_HomeChoice choice, bool value) => setState(() {
    _selected.removeWhere((item) => item.key == choice.key);
    if (value) _selected.add(choice);
  });

  /// 保存选择顺序，移动操作只影响本次草稿。
  void _reorder(int oldIndex, int newIndex) => setState(() {
    _selected.insert(newIndex, _selected.removeAt(oldIndex));
  });

  /// 用单一滚动区域展示模式、可排序选择与搜索结果。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: CacheLifecycle.account,
    builder: (context, revision, _) {
      final validAccount = revision == widget.accountRevision;
      return PopScope(
        canPop: !_managing || !validAccount,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _managing) _showModes();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            actions: [
              if (validAccount)
                TextButton(
                  onPressed: () {
                    if (CacheLifecycle.account.value ==
                        widget.accountRevision) {
                      Navigator.pop(context, (
                        _custom,
                        _selected.map(_enrich).toList(),
                      ));
                    }
                  },
                  child: const Text('保存'),
                ),
            ],
          ),
          body: validAccount
              ? !_managing
                    ? _modes()
                    : FutureBuilder<List<_HomeChoice>?>(
                        key: ValueKey(_request),
                        future: _remoteFuture,
                        builder: (context, snapshot) {
                          _remote = snapshot.data ?? [];
                          return Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 680),
                              child: _buildEditor(snapshot),
                            ),
                          );
                        },
                      )
              : const Center(child: Text('账号已变化，请返回后重新打开')),
        ),
      );
    },
  );

  String _description(_HomeChoice choice) => switch (choice.kind) {
    'local' => '${choice.label}（本机收藏夹）',
    'remote' => '${choice.label}（B 站收藏夹）',
    _ => choice.label,
  };

  bool _opening = false;
  Widget _preview(_HomeChoice choice) => InkWell(
    key: ValueKey('preview-${choice.key}'),
    onTap: choice.kind == 'group'
        ? null
        : () async {
            if (_opening ||
                CacheLifecycle.account.value != widget.accountRevision) {
              return;
            }
            _opening = true;
            final request = _request;
            try {
              await widget.onOpen(
                choice,
                () =>
                    mounted &&
                    _managing &&
                    request == _request &&
                    CacheLifecycle.account.value == widget.accountRevision &&
                    ModalRoute.of(context)?.isCurrent == true,
              );
            } finally {
              _opening = false;
            }
          },
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _ChoiceAvatar(
            choice: choice,
            imageUrl: choice.imageUrl,
            cache: widget.imageCache,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              choice.label,
              semanticsLabel: choice.kind == 'local' || choice.kind == 'remote'
                  ? '${choice.label}，${choice.kind == "local" ? "本机" : "B 站"}收藏夹'
                  : choice.label,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildEditor(AsyncSnapshot<List<_HomeChoice>?> remote) => ListView(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('home-mode-back'),
          onPressed: _showModes,
          icon: const Icon(Icons.arrow_back),
          label: const Text('返回显示方式'),
        ),
      ),
      if (_localLoading)
        const Padding(padding: EdgeInsets.all(16), child: Text('正在读取本机内容…')),
      if (_localFailed)
        TextButton(
          key: const ValueKey('home-choice-retry'),
          onPressed: _chooseCustom,
          child: const Text('读取失败，重试'),
        ),
      if (_custom) ...[
        ReorderableListView.builder(
          buildDefaultDragHandles: false,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: _reorder,
          itemCount: _selected.length,
          itemBuilder: (context, index) {
            final choice = _enrich(_selected[index]);
            return ListTile(
              key: ValueKey(choice.key),
              title: _preview(choice),
              trailing: ReorderableDragStartListener(
                key: ValueKey('reorder-${choice.key}'),
                index: index,
                child: Tooltip(
                  message: '拖动调整${_description(choice)}的顺序',
                  triggerMode: TooltipTriggerMode.manual,
                  child: const ColoredBox(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ),
              leading: IconButton(
                tooltip: '移除',
                icon: Icon(
                  Icons.remove_circle_outline,
                  semanticLabel: '移除${_description(choice)}',
                ),
                onPressed: () => _toggle(choice, false),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _queryController,
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: '搜索可选内容',
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        if (widget.loadRemote != null && !remote.hasData)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              remote.connectionState == ConnectionState.done
                  ? '暂时无法读取 B 站内容，已选项目会保留。你仍可编辑本机内容。'
                  : '正在读取 B 站内容，可先编辑本机内容。',
            ),
          ),
        if (widget.loadRemote != null &&
            remote.connectionState == ConnectionState.done &&
            !remote.hasData)
          TextButton(
            key: const ValueKey('home-remote-retry'),
            onPressed: _chooseCustom,
            child: const Text('重试 B 站内容'),
          ),
        for (final choice in [..._local, ...?remote.data].where(
          (item) =>
              !_selected.any((s) => s.key == item.key) &&
              item.label.toLowerCase().contains(_query.toLowerCase()),
        ))
          ListTile(
            key: ValueKey('candidate-${choice.key}'),
            title: _preview(choice),
            trailing: IconButton(
              key: ValueKey('add-${choice.key}'),
              tooltip: '添加${_description(choice)}',
              icon: const Icon(Icons.add),
              onPressed: () => _toggle(choice, true),
            ),
          ),
      ],
    ],
  );
}

/// 图片是名称的视觉补充，避免读屏重复朗读。
class _ChoiceAvatar extends StatelessWidget {
  const _ChoiceAvatar({
    required this.choice,
    required this.imageUrl,
    this.cache,
  });
  final _HomeChoice choice;
  final String imageUrl;
  final ImageResourceCache? cache;
  @override
  Widget build(BuildContext context) {
    if (choice.kind == 'local' || choice.kind == 'remote') {
      return HomeFavoriteCover(
        coverUrl: imageUrl,
        remote: choice.kind == 'remote',
        cache: cache,
      );
    }
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        choice.kind == 'creator' ? Icons.person_outline : Icons.folder_outlined,
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: 40,
        height: 40,
        child: ClipOval(
          child: imageUrl.isEmpty
              ? fallback
              : AppNetworkImage(
                  imageUrl: imageUrl,
                  cache: cache,
                  fit: BoxFit.cover,
                  memCacheWidth: 128,
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
