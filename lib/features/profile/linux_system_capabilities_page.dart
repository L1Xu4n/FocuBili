import 'package:flutter/material.dart';

/// Describes Linux desktop services without presenting Android permission toggles.
class LinuxSystemCapabilitiesPage extends StatelessWidget {
  const LinuxSystemCapabilitiesPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Linux 系统能力')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        ListTile(
          leading: Icon(Icons.play_circle_outline),
          title: Text('媒体与桌面操作'),
          subtitle: Text(
            '本地与在线播放、字幕弹幕、倍速、离线缓存和全屏使用桌面播放后端。最小化窗口后可继续播放，关闭应用会停止。',
          ),
        ),
        ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('登录与密钥环'),
          subtitle: Text(
            '官方网页登录使用隔离的 WebKitGTK 窗口，扫码与 Cookie 登录也可用。会话通过 Secret Service 密钥环保存；密钥环不可用时不会退回明文存储。',
          ),
        ),
        ListTile(
          leading: Icon(Icons.notifications_outlined),
          title: Text('专注提醒'),
          subtitle: Text(
            '需要桌面通知服务与会话 D-Bus。提醒在应用运行或最小化时触发；关闭后不能自动唤醒，重新打开时恢复保存的期限。',
          ),
        ),
        ListTile(
          leading: Icon(Icons.folder_open),
          title: Text('文件与图片'),
          subtitle: Text(
            '文件选择与保存需要 xdg-desktop-portal 及桌面后端。分享图片可复制到剪贴板；导出文件可保存到所选位置。',
          ),
        ),
        ListTile(
          leading: Icon(Icons.do_not_disturb_on_outlined),
          title: Text('系统勿扰'),
          subtitle: Text('不同 Linux 桌面的勿扰设置不统一，请在桌面通知设置中手动开启。应用不会修改系统安全或电源设置。'),
        ),
      ],
    ),
  );
}
