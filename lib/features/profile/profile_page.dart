import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../services/bilibili_auth_service.dart';

/// “我的”页面展示登录状态，并提供本地数据与后续账号功能入口。
class ProfilePage extends StatefulWidget {
  /// 创建会在进入时检查 B 站会话的“我的”页面。
  const ProfilePage({super.key});

  /// 创建保存账号、加载和错误状态的页面状态。
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

/// 管理账号状态读取、登录结果、退出登录和未完成入口提示。
class _ProfilePageState extends State<ProfilePage> {
  final BilibiliAuthService _authService = BilibiliAuthService();
  BilibiliAccount? _account;
  bool _loadingAccount = true;
  String? _accountError;

  /// 页面创建后读取 WebView 中已有的登录会话。
  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  /// 验证当前 Cookie 并更新账号卡片，失败时不暴露任何会话内容。
  Future<void> _loadAccount() async {
    try {
      final BilibiliAccount? account = await _authService.loadCurrentAccount();
      if (mounted) {
        setState(() {
          _account = account;
          _loadingAccount = false;
          _accountError = null;
        });
      }
    } on BilibiliAuthException catch (error) {
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _accountError = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _accountError = '暂时无法读取登录状态。';
        });
      }
    }
  }

  /// 打开登录页，并把成功返回的账号资料立即显示在“我的”页面。
  Future<void> _openLogin() async {
    final Object? result = await Navigator.of(context).pushNamed(
      AppRoutes.login,
    );
    if (!mounted || result is! BilibiliAccount) {
      return;
    }
    setState(() {
      _account = result;
      _accountError = null;
    });
  }

  /// 清除本应用保存的 B 站 WebView 会话，并恢复未登录卡片。
  Future<void> _logout() async {
    setState(() => _loadingAccount = true);
    try {
      await _authService.logout();
      if (mounted) {
        setState(() {
          _account = null;
          _loadingAccount = false;
          _accountError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _accountError = '退出登录失败，请稍后重试。';
        });
      }
    }
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

  /// 根据当前账号状态创建头像，远程图片失败时回退为本地图标。
  Widget _buildAvatar() {
    final String avatarUrl = _account?.avatarUrl ?? '';
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
    final BilibiliAccount? account = _account;
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
                          account?.name ?? '尚未登录',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (_loadingAccount)
                          const Text('正在读取登录状态…')
                        else if (account != null)
                          Text('UID：${account.mid}')
                        else
                          Text(_accountError ?? '登录后可使用账号相关功能'),
                      ],
                    ),
                  ),
                  if (account == null)
                    FilledButton(
                      // 登录按钮函数打开手机号、密码、Cookie 和网页登录入口。
                      onPressed: _loadingAccount ? null : _openLogin,
                      child: const Text('登录'),
                    )
                  else
                    OutlinedButton(
                      // 退出按钮函数清除当前应用的 B 站会话。
                      onPressed: _loadingAccount ? null : _logout,
                      child: const Text('退出'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _ProfileTile(
            icon: Icons.history_rounded,
            title: '观看记录',
            onTap: () => _showComingSoon(context, '观看记录'),
          ),
          _ProfileTile(
            icon: Icons.favorite_outline_rounded,
            title: '我的收藏',
            onTap: () => _showComingSoon(context, '我的收藏'),
          ),
          _ProfileTile(
            icon: Icons.edit_note_rounded,
            title: '时间点笔记',
            onTap: () => _showComingSoon(context, '时间点笔记'),
          ),
          _ProfileTile(
            icon: Icons.settings_outlined,
            title: '设置',
            onTap: () => _showComingSoon(context, '设置'),
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
