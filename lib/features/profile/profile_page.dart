import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../services/bilibili_auth_service.dart';
import 'favorite_folders_page.dart';
import 'followed_creators_page.dart';
import 'login_page.dart';
import 'subscribed_collections_page.dart';

/// 标识已登录账号菜单中可执行的安全会话操作。
enum _AccountMenuAction { switchAccount, logout }

/// “我的”页面展示登录状态，并提供本地数据与后续账号功能入口。
class ProfilePage extends StatefulWidget {
  /// 创建会在进入时检查 B 站会话的“我的”页面。
  const ProfilePage({super.key});

  /// 创建保存账号、加载和错误状态的页面状态。
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

/// 管理账号状态读取、网页登录结果、切换账号和退出登录。
class _ProfilePageState extends State<ProfilePage> {
  final BilibiliAuthService _authService = BilibiliAuthService();
  BilibiliSessionState _session = const BilibiliSessionState.signedOut();
  bool _loadingAccount = true;

  /// 页面创建后读取 WebView 中已有的登录会话。
  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  /// 验证当前 Cookie 并保留“未登录、过期、网络错误”三种不同页面状态。
  Future<void> _loadAccount() async {
    if (mounted) {
      setState(() => _loadingAccount = true);
    }
    try {
      final BilibiliSessionState session =
          await _authService.loadCurrentSession();
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
          builder: (BuildContext context) => const LoginPage(
            openOfficialLoginOnStart: true,
          ),
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
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// 对尚未迁移的账号功能显示轻量提示，避免用户误以为操作已提交。
  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$feature 将在后续版本接入'),
          duration: const Duration(seconds: 3),
        ),
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
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

  /// 根据当前账号状态创建头像，远程图片失败时回退为本地图标。
  Widget _buildAvatar() {
    final String avatarUrl = _session.account?.avatarUrl ?? '';
    if (avatarUrl.isEmpty) {
      return const CircleAvatar(
        radius: 30,
        child: Icon(Icons.person_rounded, size: 34),
      );
    }
    return CircleAvatar(
      radius: 30,
      child: ClipOval(
        child: Image.network(
          avatarUrl,
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          // 头像错误函数回退为本地图标，避免图片地址失效破坏账号卡片。
          errorBuilder: _buildAvatarError,
        ),
      ),
    );
  }

  /// 创建远程头像加载失败时使用的固定尺寸本地占位图标。
  Widget _buildAvatarError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const SizedBox.square(
      dimension: 60,
      child: Icon(Icons.person_rounded, size: 34),
    );
  }

  /// 创建登录状态卡片以及历史、收藏、笔记和设置入口。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: <Widget>[
                  _buildAvatar(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _accountTitle(),
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
                  const SizedBox(width: 8),
                  _buildAccountAction(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _ProfileTile(
            icon: Icons.history_rounded,
            title: '观看记录',
            // 观看记录入口函数打开只保存在本机的视频观看历史页面。
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.watchHistory),
          ),
          _ProfileTile(
            icon: Icons.star_outline_rounded,
            title: '我的收藏',
            // 收藏入口函数打开真实收藏夹列表，具体会话错误由目标页面明确显示。
            onTap: () => _openFavoriteFolders(),
          ),
          _ProfileTile(
            icon: Icons.subscriptions_outlined,
            title: '我的订阅',
            // 订阅入口函数只展示由多支独立视频组成的 UGC 合集。
            onTap: () => _openSubscribedCollections(),
          ),
          _ProfileTile(
            icon: Icons.people_outline_rounded,
            title: '我的关注',
            // 关注入口函数只展示当前账号已关注的 UP 主。
            onTap: () => _openFollowedCreators(),
          ),
          _ProfileTile(
            icon: Icons.edit_note_rounded,
            title: '时间点笔记',
            onTap: () => _showComingSoon(context, '时间点笔记'),
          ),
          _ProfileTile(
            icon: Icons.settings_outlined,
            title: '设置',
            // 设置入口函数进入目前已实现的视频缓存管理页。
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.cacheManagement),
          ),
        ],
      ),
    );
  }
}

/// 统一“我的”页面中的功能入口样式。
class _ProfileTile extends StatelessWidget {
  /// 创建带图标、标题和点击回调的账号功能入口。
  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  /// 创建带圆角卡片、图标和箭头的单个入口。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
