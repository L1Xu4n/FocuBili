import 'package:flutter/material.dart';
import '../../services/focus_notification_service.dart';

/// Apple 系统权限只在用户主动请求时申请；不模拟 Android 的后台权限。
class AppleSystemCapabilitiesPage extends StatefulWidget {
  const AppleSystemCapabilitiesPage({super.key});
  @override
  State<AppleSystemCapabilitiesPage> createState() => _AppleCapabilitiesState();
}

class _AppleCapabilitiesState extends State<AppleSystemCapabilitiesPage> {
  final _notifications = const FocusNotificationService();
  bool? _allowed;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final allowed = await _notifications.hasPermission();
    if (mounted) setState(() => _allowed = allowed);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Apple 系统能力')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: const Text('专注完成和定时提醒'),
          subtitle: Text(
            _allowed == null
                ? '正在检测'
                : _allowed!
                ? '通知已允许'
                : '通知未允许',
          ),
          trailing: FilledButton(
            onPressed: () async {
              await _notifications.requestPermission();
              await _refresh();
            },
            child: const Text('申请通知'),
          ),
        ),
        ListTile(
          title: const Text('通知设置'),
          trailing: const Icon(Icons.open_in_new),
          onTap: _notifications.openSettings,
        ),
        const ListTile(
          title: Text('后台听视频'),
          subtitle: Text('播放音频时使用系统音频会话，可从锁屏或控制中心暂停、继续及跳转。系统中断和耳机拔出时暂停。'),
        ),
        const ListTile(
          title: Text('离线下载'),
          subtitle: Text(
            '支持应用内下载、暂停与续传。iOS 可能在应用进入后台后挂起下载，回到应用可继续；不会申请无关后台权限。',
          ),
        ),
        const ListTile(
          title: Text('系统专注 / 勿扰'),
          subtitle: Text('由系统控制，请在控制中心手动设置；第三方应用不能自动切换。'),
        ),
        const ListTile(
          title: Text('画中画'),
          subtitle: Text(
            'iOS 15 及以上可请求系统画中画；Mac 使用已验证完整画面的原生置顶小窗，提供播放、暂停和跳转。小窗不包含 Flutter 弹幕与字幕叠加。',
          ),
        ),
      ],
    ),
  );
}
