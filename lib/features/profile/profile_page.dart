import '../subscriptions/subscription_updates_page.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/editable_card_board.dart';
import '../../services/dashboard_layout_service.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/app_update_service.dart';
import 'favorite_folders_page.dart';
import 'app_favorite_folders_page.dart';
import 'followed_creators_page.dart';
import 'login_page.dart';
import 'offline_videos_page.dart';
import 'subscribed_collections_page.dart';

/// 标识已登录账号菜单中可执行的安全会话操作。
enum _AccountMenuAction { switchAccount, logout }

/// “我的”页面展示登录状态，并提供本地数据与后续账号功能入口。
class ProfilePage extends StatefulWidget {
  /// 创建会在进入时检查 B 站会话的“我的”页面，并支持从主框架返回首页。
  const ProfilePage({
    super.key,
    this.onBackRequested,
    this.layoutService,
    this.authService,
  });

  /// 可选的首页返回回调；独立打开页面时仍沿用系统路由返回行为。
  final VoidCallback? onBackRequested;

  /// 可注入本机布局服务，便于独立验证个人中心配置。
  final DashboardLayoutService? layoutService;

  /// 可注入账号服务，测试不会访问真实账号或清除真实会话。
  final BilibiliAuthService? authService;

  /// 创建保存账号、加载和错误状态的页面状态。
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

/// 管理账号状态读取、网页登录结果、切换账号和退出登录。
class _ProfilePageState extends State<ProfilePage> {
  late final BilibiliAuthService _authService;
  final ScrollController _scrollController = ScrollController();
  BilibiliSessionState _session = const BilibiliSessionState.signedOut();
  bool _loadingAccount = true;

  /// 页面创建后读取 WebView 中已有的登录会话。
  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? BilibiliAuthService();
    _loadAccount();
  }

  /// 验证当前 Cookie 并保留“未登录、过期、网络错误”三种不同页面状态。
  Future<void> _loadAccount() async {
    if (mounted) {
      setState(() => _loadingAccount = true);
    }
    try {
      final BilibiliSessionState session = await _authService
          .loadCurrentSession();
      if (mounted) {
        setState(() {
          _session = session;
          _loadingAccount = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _session = const BilibiliSessionState.networkError(
            message: '暂时无法读取登录状态，请稍后重试。',
          );
          _loadingAccount = false;
        });
      }
    }
  }

  /// 打开登录页，并把成功返回的账号资料立即显示在“我的”页面。
  ///
  /// 切换账号或会话过期时会直接打开官方网页登录，普通未登录入口仍保留
  /// 手机号、密码说明和 Cookie 导入三种用户主动选择的方式。
  Future<void> _openLogin({bool openOfficialLoginOnStart = false}) async {
    final Object? result;
    if (openOfficialLoginOnStart) {
      result = await Navigator.of(context).push<BilibiliAccount>(
        MaterialPageRoute<BilibiliAccount>(
          // 账号切换构建函数让用户先进入官方网页登录，密码与验证码不会经过 App。
          builder: (BuildContext context) =>
              const LoginPage(openOfficialLoginOnStart: true),
        ),
      );
    } else {
      result = await Navigator.of(context).pushNamed(AppRoutes.login);
    }
    if (!mounted) {
      return;
    }
    if (result is BilibiliAccount) {
      final BilibiliAccount account = result;
      setState(() {
        _session = BilibiliSessionState.active(account);
        _loadingAccount = false;
      });
      return;
    }
    await _loadAccount();
  }

  /// 询问用户是否确认切换账号，避免一次误触就删除当前 B 站会话。
  Future<bool> _confirmAccountSwitch() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('切换账号'),
        content: const Text('将清除当前 B 站登录状态并打开官方网页登录。'),
        actions: <Widget>[
          TextButton(
            // 取消按钮函数关闭确认框且不改动现有登录状态。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认按钮函数只返回确认结果，实际清理由外层函数统一处理。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 清理 B 站域 Cookie 后立即打开官方网页登录，不保存任何旧账号资料。
  Future<void> _switchAccount() async {
    if (!await _confirmAccountSwitch() || !mounted) {
      return;
    }
    setState(() => _loadingAccount = true);
    try {
      await _authService.clearBilibiliSession();
      if (!mounted) {
        return;
      }
      setState(() {
        _session = const BilibiliSessionState.signedOut();
        _loadingAccount = false;
      });
      await _openLogin(openOfficialLoginOnStart: true);
    } catch (_) {
      if (mounted) {
        setState(() => _loadingAccount = false);
        _showAccountActionError('无法清除当前 B 站登录状态，请稍后重试。');
      }
    }
  }

  /// 清除本应用保存的 B 站域 Cookie，并恢复未登录卡片。
  Future<void> _logout() async {
    setState(() => _loadingAccount = true);
    try {
      await _authService.logout();
      if (mounted) {
        setState(() {
          _session = const BilibiliSessionState.signedOut();
          _loadingAccount = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingAccount = false);
        _showAccountActionError('退出登录失败，请稍后重试。');
      }
    }
  }

  /// 分发已登录账号菜单操作，确保每种操作都有明确的会话处理路径。
  Future<void> _handleAccountMenuAction(_AccountMenuAction action) async {
    switch (action) {
      case _AccountMenuAction.switchAccount:
        await _switchAccount();
      case _AccountMenuAction.logout:
        await _logout();
    }
  }

  /// 在不改变会话判断结果的前提下显示一次账号操作失败说明。
  void _showAccountActionError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 打开当前账号的只读收藏夹列表，页面会自行验证网页登录会话。
  Future<void> _openFavoriteFolders() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 收藏夹页面构建函数只读取当前账号公开可见的收藏数据，不执行写操作。
        builder: (BuildContext context) => const FavoriteFoldersPage(),
      ),
    );
  }

  /// 打开本机离线缓存列表，可播放已下载视频并管理占用空间。
  Future<void> _openOfflineVideos() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 离线缓存页面构建函数只读写本机下载文件，不访问账号数据。
        builder: (BuildContext context) => const OfflineVideosPage(),
      ),
    );
  }

  /// 打开软件内独立收藏夹列表，可新建与在看视频时收藏。
  Future<void> _openAppFavoriteFolders() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 软件收藏夹页面构建函数只读写本机数据，不修改 B 站账号收藏。
        builder: (BuildContext context) => const AppFavoriteFoldersPage(),
      ),
    );
  }

  /// 打开当前账号已关注的 UP 主列表，与订阅合集保持独立入口。
  Future<void> _openFollowedCreators() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 关注页面构建函数只读取已关注 UP 主，不提供关注或取关按钮。
        builder: (BuildContext context) => const FollowedCreatorsPage(),
      ),
    );
  }

  /// 打开当前账号订阅的 UGC 合集列表，不混入已关注 UP 主。
  Future<void> _openSubscribedCollections() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 订阅页面构建函数只读取 UGC 合集，不执行取消订阅等写操作。
        builder: (BuildContext context) => const SubscribedCollectionsPage(),
      ),
    );
  }

  /// 根据当前会话状态生成账号卡片标题，网络错误不会伪装成已退出登录。
  String _accountTitle() {
    switch (_session.status) {
      case BilibiliSessionStatus.active:
        return _session.account?.name ?? '已登录用户';
      case BilibiliSessionStatus.expired:
        return '登录已过期';
      case BilibiliSessionStatus.networkError:
        return '暂时无法确认登录状态';
      case BilibiliSessionStatus.signedOut:
        return '尚未登录';
    }
  }

  /// 根据当前会话状态生成账号卡片说明，明确告知用户何时需要重新登录。
  String _accountDescription() {
    switch (_session.status) {
      case BilibiliSessionStatus.active:
        return 'UID：${_session.account?.mid ?? 0}';
      case BilibiliSessionStatus.expired:
      case BilibiliSessionStatus.networkError:
        return _session.message ?? '暂时无法读取登录状态，请稍后重试。';
      case BilibiliSessionStatus.signedOut:
        return '登录后可使用账号相关功能';
    }
  }

  /// 创建与会话状态匹配的账号操作：网络错误只允许重试，不会自动清除 Cookie。
  Widget _buildAccountAction() {
    if (_loadingAccount) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: Icon(
            Icons.hourglass_top_rounded,
            size: 20,
            semanticLabel: '正在读取登录状态',
          ),
        ),
      );
    }
    switch (_session.status) {
      case BilibiliSessionStatus.active:
        return PopupMenuButton<_AccountMenuAction>(
          // 账号菜单回调函数执行切换或退出，并保留其他网站 Cookie。
          onSelected: _handleAccountMenuAction,
          itemBuilder: (BuildContext context) =>
              const <PopupMenuEntry<_AccountMenuAction>>[
                PopupMenuItem<_AccountMenuAction>(
                  value: _AccountMenuAction.switchAccount,
                  child: Text('切换账号'),
                ),
                PopupMenuItem<_AccountMenuAction>(
                  value: _AccountMenuAction.logout,
                  child: Text('退出登录'),
                ),
              ],
          tooltip: '账号操作',
        );
      case BilibiliSessionStatus.expired:
        return FilledButton(
          // 过期登录按钮函数直接开启官方网页流程，避免 App 接触密码或验证码。
          onPressed: () => _openLogin(openOfficialLoginOnStart: true),
          child: const Text('重新登录'),
        );
      case BilibiliSessionStatus.networkError:
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          children: <Widget>[
            OutlinedButton(
              // 重试按钮函数只重新验证会话，不会自动清除可能仍有效的 Cookie。
              onPressed: _loadAccount,
              child: const Text('重试'),
            ),
            TextButton(
              // 手动登录按钮函数允许用户在网络恢复后自行进入官方登录页面。
              onPressed: _openLogin,
              child: const Text('登录'),
            ),
          ],
        );
      case BilibiliSessionStatus.signedOut:
        return FilledButton(
          // 登录按钮函数打开手机号、密码说明、Cookie 和网页登录入口。
          onPressed: _openLogin,
          child: const Text('登录'),
        );
    }
  }

  /// 根据当前账号状态和目标尺寸创建头像，远程图片失败时回退为本地图标。
  Widget _buildAvatar({double radius = 30, Key? key}) {
    final String avatarUrl = _session.account?.avatarUrl ?? '';
    if (avatarUrl.isEmpty) {
      return CircleAvatar(
        key: key,
        radius: radius,
        child: Icon(Icons.person_rounded, size: radius * 1.1),
      );
    }
    return CircleAvatar(
      key: key,
      radius: radius,
      child: ClipOval(
        child: Image.network(
          avatarUrl,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          // 头像错误函数回退为本地图标，避免图片地址失效破坏账号卡片。
          errorBuilder: _buildAvatarError,
        ),
      ),
    );
  }

  /// 创建远程头像加载失败时使用的自适应本地占位图标。
  Widget _buildAvatarError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Icon(Icons.person_rounded, size: 34),
      ),
    );
  }

  /// 根据卡片实际宽度和文字比例排列账号摘要，宽屏把操作并入同一行。
  Widget _buildAccountCard() {
    return Card(
      key: const Key('profile-account-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          // 账号布局函数以父约束判断空间，给大字账号摘要预留足够宽度。
          builder: (BuildContext context, BoxConstraints constraints) {
            final double textScale =
                MediaQuery.textScalerOf(context).scale(18) / 18;
            final bool inline =
                constraints.maxWidth >= 520 * (textScale > 1 ? textScale : 1);
            final Widget summary = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildAvatar(radius: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _accountTitle(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(_accountDescription()),
                    ],
                  ),
                ),
              ],
            );
            if (inline) {
              return Row(
                children: <Widget>[
                  Expanded(child: summary),
                  const SizedBox(width: 12),
                  _buildAccountAction(),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                summary,
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildAccountAction(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 以明确稳定编号登记全部功能入口，默认顺序先本机内容再账号与设置。
  List<_ProfileTile> _buildFeatureTiles({required bool hasUpdate}) {
    return <_ProfileTile>[
      _ProfileTile(
        icon: Icons.history_rounded,
        title: '观看记录',
        id: 'watch-history',
        // 观看记录入口函数打开只保存在本机的视频观看历史页面。
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.watchHistory),
      ),
      _ProfileTile(
        icon: Icons.offline_pin_rounded,
        title: '离线缓存',
        id: 'offline-videos',
        // 离线缓存入口函数打开已下载到本机的视频列表。
        onTap: () => _openOfflineVideos(),
      ),
      _ProfileTile(
        icon: Icons.bookmark_added_rounded,
        title: '软件收藏夹',
        id: 'app-favorites',
        // 软件收藏夹入口函数打开本机独立收藏夹，不依赖 B 站登录状态。
        onTap: () => _openAppFavoriteFolders(),
      ),
      _ProfileTile(
        icon: Icons.edit_note_rounded,
        title: '时间点笔记',
        id: 'video-notes',
        // 时间点笔记入口函数打开本机笔记的统一查看与管理页面。
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.videoNotes),
      ),
      _ProfileTile(
        icon: Icons.insights_rounded,
        title: '专注数据',
        id: 'focus-statistics',
        // 专注数据入口函数打开本机看板、筛选和统一记录管理页面。
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.focusStatistics),
      ),
      _ProfileTile(
        icon: Icons.star_outline_rounded,
        title: '我的收藏',
        id: 'favorites',
        // 收藏入口函数打开真实收藏夹列表，具体会话错误由目标页面明确显示。
        onTap: () => _openFavoriteFolders(),
      ),
      _ProfileTile(
        icon: Icons.subscriptions_outlined,
        title: '我的订阅',
        id: 'subscriptions',
        // 订阅入口函数只展示由多支独立视频组成的 UGC 合集。
        onTap: () => _openSubscribedCollections(),
      ),
      _ProfileTile(
        icon: Icons.people_outline_rounded,
        title: '我的关注',
        id: 'following',
        // 关注入口函数只展示当前账号已关注的 UP 主。
        onTap: () => _openFollowedCreators(),
      ),
      _ProfileTile(
        icon: Icons.settings_outlined,
        title: '设置',
        id: 'settings',
        showBadge: hasUpdate,
        // 设置入口函数进入个性化设置页，其中仍保留独立缓存管理入口。
        onTap: () =>
            Navigator.of(context).pushNamed(AppRoutes.personalizationSettings),
      ),
      _ProfileTile(
        icon: Icons.rss_feed,
        title: '焦点订阅',
        id: 'subscription-updates',
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const SubscriptionUpdatesPage()),
        ),
      ),
    ];
  }

  /// 把账号和功能卡交给统一编辑区域，隐藏账号只改变布局而不退出登录。
  List<DashboardCardDefinition> _buildCards(bool hasUpdate) {
    return [
      DashboardCardDefinition(
        id: 'account',
        title: '账号摘要',
        icon: Icons.account_circle_outlined,
        fullWidth: true,
        // 账号摘要构建函数复用现有会话状态和登录操作。
        builder: (_) => _buildAccountCard(),
      ),
      for (final tile in _buildFeatureTiles(hasUpdate: hasUpdate))
        DashboardCardDefinition(
          id: tile.id,
          title: tile.title,
          icon: tile.icon,
          required: tile.id == 'settings',
          // 功能卡构建函数保留入口原有导航及更新提示。
          builder: (_) => tile,
        ),
    ];
  }

  /// 页面退出时释放统一滚动区域的控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 创建登录状态卡片以及历史、收藏、笔记和设置入口。
  @override
  Widget build(BuildContext context) {
    final bool hasUpdate = AppUpdateScope.maybeOf(context)?.hasUpdate ?? false;
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBackRequested == null
            ? null
            : IconButton(
                key: const Key('profile-back-button'),
                // 返回按钮函数把“我的”页切回首页。
                onPressed: widget.onBackRequested,
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: '返回首页',
              ),
        title: const Text('我的'),
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool workspace = AdaptiveLayout.usesWorkspace(
            MediaQuery.sizeOf(context),
          );
          final double horizontalPadding = workspace
              ? 20
              : AdaptiveLayout.centeredHorizontalPadding(
                  width: constraints.maxWidth,
                  maxContentWidth: AdaptiveLayout.profileContentMaxWidth,
                  compact: 16,
                );
          return SingleChildScrollView(
            key: Key(
              workspace
                  ? 'profile-workspace-layout'
                  : 'profile-adaptive-content',
            ),
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              workspace ? 8 : 16,
              horizontalPadding,
              20,
            ),
            child: EditableCardBoard(
              key: const Key('profile-card-board'),
              storageId: 'profile',
              items: _buildCards(hasUpdate),
              service: widget.layoutService,
              scrollController: _scrollController,
              columnCount: workspace ? null : 1,
            ),
          );
        },
      ),
    );
  }
}

/// 统一“我的”页面中的功能入口样式。
class _ProfileTile extends StatelessWidget {
  /// 创建带图标、标题和点击回调的账号功能入口。
  const _ProfileTile({
    required this.id,
    required this.icon,
    required this.title,
    required this.onTap,
    this.showBadge = false,
  });

  final String id;
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool showBadge;

  /// 创建带圆角卡片、图标和箭头的单个入口。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showBadge) ...<Widget>[
              Container(
                key: const Key('profile-settings-update-dot'),
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
